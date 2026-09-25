import AppKit
import CryptoKit
import Foundation

/// Spotify Web API, used only to resolve "play <song>" and "play my <name>
/// playlist" to a Spotify URI. Playback itself stays in AppleScript.
///
/// Sign-in is Authorization Code with PKCE, so there is no client secret.
/// Tokens live in the Keychain. The redirect is a loopback address, the only
/// non-HTTPS form Spotify accepts. Its port is fixed: Spotify's docs allow
/// registering a loopback URI without a port, but the dashboard rejects that
/// form as "not secure", so it must match exactly.
public actor SpotifyWebAPI {
    public static let shared = SpotifyWebAPI()

    public static let clientIDKey = "spotify.clientID"
    /// Fixed so that it matches what is registered in the Spotify dashboard.
    static let redirectPort: UInt16 = 43821
    /// What to register in the Spotify dashboard, character for character.
    public static let registeredRedirectURI = "http://127.0.0.1:\(redirectPort)/callback"

    private static let tokenAccount = "spotify.token"
    private static let scopes = "playlist-read-private playlist-read-collaborative"

    private struct Token: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
    }

    public struct Match: Sendable, Equatable {
        public let uri: String
        public let title: String
    }

    /// Nil unless the user has entered a client ID in Settings.
    public nonisolated static var clientID: String? {
        let id = UserDefaults.standard.string(forKey: clientIDKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return id.isEmpty ? nil : id
    }

    public nonisolated static var isSignedIn: Bool {
        clientID != nil && Keychain.data(for: tokenAccount) != nil
    }

    // MARK: Sign-in

    public func signIn() async throws {
        guard let clientID = Self.clientID else { throw ToolError("Enter your Spotify client ID first") }
        let verifier = Self.randomURLSafe(bytes: 64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = Self.randomURLSafe(bytes: 16)

        let loopback = try LoopbackRedirect(port: Self.redirectPort)
        _ = try await loopback.start()
        let redirectURI = Self.registeredRedirectURI

        var authorize = URLComponents(string: "https://accounts.spotify.com/authorize")!
        authorize.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "state", value: state),
            .init(name: "scope", value: Self.scopes),
        ]

        async let redirected = loopback.callback(timeout: .seconds(180))
        await MainActor.run { _ = NSWorkspace.shared.open(authorize.url!) }
        let query = try await redirected.queryItems ?? []
        let value = { (name: String) in query.first { $0.name == name }?.value }

        guard value("state") == state else { throw ToolError("Spotify sign-in was interrupted; try again") }
        if let error = value("error") {
            throw ToolError(error == "access_denied" ? "Spotify sign-in was cancelled" : "Spotify refused sign-in (\(error))")
        }
        guard let code = value("code") else { throw ToolError("Spotify didn't return a sign-in code") }

        try await requestToken([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ])
        Log.tools.notice("spotify: signed in")
    }

    public func signOut() {
        Keychain.delete(Self.tokenAccount)
    }

    // MARK: Lookup

    /// The best track for a spoken request ("bohemian rhapsody by queen").
    public func findTrack(_ query: String) async throws -> Match? {
        let response: SearchResponse = try await get("/v1/search", ["q": query, "type": "track", "limit": "5"])
        return response.tracks?.items.compactMap { $0 }.first.map { track in
            Match(uri: track.uri, title: ([track.name] + (track.artists.first.map { ["by \($0.name)"] } ?? [])).joined(separator: " "))
        }
    }

    /// "Liked Songs" is the user's saved-tracks collection, not a playlist:
    /// searching for it found a public playlist with that name instead.
    public nonisolated static func isLikedSongs(_ query: String) -> Bool {
        ["likedsongs", "mylikedsongs", "likes", "mylikes", "likedmusic", "mylikedmusic", "favorites", "myfavorites"]
            .contains(AppNameMatcher.key(query))
    }

    public func likedSongs() async throws -> Match? {
        let me: Profile = try await get("/v1/me", [:])
        return Match(uri: "spotify:user:\(me.id):collection", title: "your Liked Songs")
    }

    /// The user's own playlist when one matches, otherwise the top public one.
    public func findPlaylist(_ query: String) async throws -> Match? {
        let mine = try await userPlaylists()
        if let name = AppNameMatcher.match(query, candidates: mine.map(\.name), aliases: [:]),
           let playlist = mine.first(where: { $0.name == name }) {
            return Match(uri: playlist.uri, title: playlist.name)
        }
        let response: SearchResponse = try await get("/v1/search", ["q": query, "type": "playlist", "limit": "5"])
        return response.playlists?.items.compactMap { $0 }.first.map { Match(uri: $0.uri, title: $0.name) }
    }

    private func userPlaylists() async throws -> [PlaylistItem] {
        var all: [PlaylistItem] = []
        var offset = 0
        while offset < 200 {
            let page: PlaylistPage = try await get("/v1/me/playlists", ["limit": "50", "offset": "\(offset)"])
            all += page.items.compactMap { $0 }
            guard page.next != nil else { break }
            offset += 50
        }
        return all
    }

    // MARK: HTTP

    private func get<Response: Decodable>(_ path: String, _ query: [String: String]) async throws -> Response {
        var components = URLComponents(string: "https://api.spotify.com" + path)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        for attempt in 0..<2 {
            var request = URLRequest(url: components.url!, timeoutInterval: 8)
            request.setValue("Bearer \(try await accessToken(forceRefresh: attempt > 0))", forHTTPHeaderField: "Authorization")
            let (data, response) = try await Self.send(request)
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200:
                return try JSONDecoder().decode(Response.self, from: data)
            case 401 where attempt == 0:
                continue // Token revoked or expired early: refresh once.
            case 403:
                throw ToolError("Spotify refused the request. Is your account on the app's user list?")
            case 429:
                throw ToolError("Spotify is rate-limiting requests; try again shortly")
            case let status:
                throw ToolError("Spotify returned an error (\(status))")
            }
        }
        throw ToolError("Spotify sign-in has expired; sign in again in Settings")
    }

    private func accessToken(forceRefresh: Bool) async throws -> String {
        guard let clientID = Self.clientID,
              let data = Keychain.data(for: Self.tokenAccount),
              let token = try? JSONDecoder().decode(Token.self, from: data)
        else { throw ToolError("Spotify isn't connected; sign in under Settings › Spotify") }
        if !forceRefresh, token.expiresAt.timeIntervalSinceNow > 60 {
            return token.accessToken
        }
        return try await requestToken([
            "grant_type": "refresh_token",
            "refresh_token": token.refreshToken,
            "client_id": clientID,
        ], previousRefreshToken: token.refreshToken)
    }

    @discardableResult
    private func requestToken(_ form: [String: String], previousRefreshToken: String? = nil) async throws -> String {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((body.percentEncodedQuery ?? "").utf8)

        let (data, response) = try await Self.send(request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let reply = try? JSONDecoder().decode(TokenResponse.self, from: data)
        else {
            if previousRefreshToken != nil { signOut() }
            throw ToolError("Spotify sign-in failed; sign in again in Settings")
        }
        let token = Token(
            accessToken: reply.access_token,
            // A refresh response may omit the refresh token: keep the old one.
            refreshToken: reply.refresh_token ?? previousRefreshToken ?? "",
            expiresAt: Date().addingTimeInterval(TimeInterval(reply.expires_in))
        )
        Keychain.set(try JSONEncoder().encode(token), for: Self.tokenAccount)
        return token.accessToken
    }

    private static func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            throw ToolError("Spotify search needs the internet, and this Mac is offline")
        } catch let error as URLError where error.code == .timedOut {
            throw ToolError("Spotify didn't respond in time")
        }
    }

    private static func randomURLSafe(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64URLEncoded
    }

    // MARK: Wire types

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
    }

    private struct SearchResponse: Decodable {
        struct Page<Item: Decodable>: Decodable { let items: [Item?] }
        struct Track: Decodable {
            struct Artist: Decodable { let name: String }
            let uri: String
            let name: String
            let artists: [Artist]
        }
        let tracks: Page<Track>?
        let playlists: Page<PlaylistItem>?
    }

    private struct PlaylistPage: Decodable {
        let items: [PlaylistItem?]
        let next: String?
    }

    private struct Profile: Decodable {
        let id: String
    }

    private struct PlaylistItem: Decodable {
        let uri: String
        let name: String
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
