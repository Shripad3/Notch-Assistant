import AppKit
import CryptoKit
import Foundation

/// OAuth 2 sign-in for a desktop app: Authorization Code with PKCE, the
/// browser redirecting to a loopback address on this Mac. Used for Google
/// Calendar and Outlook. Tokens live in the Keychain; the app asks only for
/// read access to calendars.
public actor OAuthSession {
    public struct Configuration: Sendable {
        let service: String
        let authorizeURL: URL
        let tokenURL: URL
        let scopes: String
        /// The Keychain account holding the tokens.
        let tokenAccount: String
        /// Registered redirect host: Google takes 127.0.0.1, Microsoft localhost.
        let redirectHost: String
        let extraParameters: [String: String]
        /// Microsoft wants the scopes again when refreshing; Google doesn't.
        let refreshSendsScope: Bool
    }

    private struct Token: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
    }

    private let configuration: Configuration
    private let credentials: @Sendable () -> (id: String, secret: String?)?

    init(_ configuration: Configuration, credentials: @escaping @Sendable () -> (id: String, secret: String?)?) {
        self.configuration = configuration
        self.credentials = credentials
    }

    public nonisolated var isSignedIn: Bool {
        credentials() != nil && Keychain.data(for: configuration.tokenAccount) != nil
    }

    public func signIn() async throws {
        let name = configuration.service
        guard let (clientID, secret) = credentials() else { throw ToolError("Enter the \(name) client ID first") }
        let verifier = Self.randomURLSafe(bytes: 64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = Self.randomURLSafe(bytes: 16)

        let loopback = try LoopbackRedirect(service: name, path: "/")
        let port = try await loopback.start()
        let redirectURI = "http://\(configuration.redirectHost):\(port)"

        var authorize = URLComponents(url: configuration.authorizeURL, resolvingAgainstBaseURL: false)!
        authorize.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "state", value: state),
            .init(name: "scope", value: configuration.scopes),
        ] + configuration.extraParameters.map { URLQueryItem(name: $0.key, value: $0.value) }

        async let redirected = loopback.callback(timeout: .seconds(300))
        await MainActor.run { _ = NSWorkspace.shared.open(authorize.url!) }
        let query = try await redirected.queryItems ?? []
        let value = { (key: String) in query.first { $0.name == key }?.value }

        guard value("state") == state else { throw ToolError("\(name) sign-in was interrupted; try again") }
        if let error = value("error") {
            throw ToolError(error == "access_denied" ? "\(name) sign-in was cancelled" : "\(name) refused sign-in (\(error))")
        }
        guard let code = value("code") else { throw ToolError("\(name) didn't return a sign-in code") }

        var form = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ]
        if let secret { form["client_secret"] = secret }
        try await requestToken(form)
        Log.tools.notice("\(name, privacy: .public): signed in")
    }

    public func signOut() {
        Keychain.delete(configuration.tokenAccount)
    }

    /// A GET with a fresh access token, retried once after a refresh.
    func get(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        for attempt in 0..<2 {
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.setValue("Bearer \(try await accessToken(forceRefresh: attempt > 0))", forHTTPHeaderField: "Authorization")
            headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            let (data, response) = try await send(request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { continue }
            guard status == 200 else { throw ToolError("\(configuration.service) answered with an error (\(status))") }
            return data
        }
        throw ToolError("\(configuration.service) sign-in has expired; sign in again in Settings")
    }

    private func accessToken(forceRefresh: Bool) async throws -> String {
        guard let (clientID, secret) = credentials(),
              let data = Keychain.data(for: configuration.tokenAccount),
              let token = try? JSONDecoder().decode(Token.self, from: data)
        else { throw ToolError("\(configuration.service) isn't connected; sign in under Settings › Calendar") }
        if !forceRefresh, token.expiresAt.timeIntervalSinceNow > 60 {
            return token.accessToken
        }
        var form = ["grant_type": "refresh_token", "refresh_token": token.refreshToken, "client_id": clientID]
        if let secret { form["client_secret"] = secret }
        if configuration.refreshSendsScope { form["scope"] = configuration.scopes }
        return try await requestToken(form, previousRefreshToken: token.refreshToken)
    }

    @discardableResult
    private func requestToken(_ form: [String: String], previousRefreshToken: String? = nil) async throws -> String {
        var request = URLRequest(url: configuration.tokenURL, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        // "+" in a secret must survive form decoding.
        request.httpBody = Data((body.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)

        let (data, response) = try await send(request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let reply = try? JSONDecoder().decode(TokenResponse.self, from: data)
        else {
            if previousRefreshToken != nil { signOut() }
            let reason = (try? JSONDecoder().decode(ErrorResponse.self, from: data)).map { " (\($0.error))" } ?? ""
            throw ToolError("\(configuration.service) sign-in failed\(reason); check the client ID and sign in again in Settings")
        }
        let token = Token(
            accessToken: reply.access_token,
            refreshToken: reply.refresh_token ?? previousRefreshToken ?? "",
            expiresAt: Date().addingTimeInterval(TimeInterval(reply.expires_in))
        )
        Keychain.set(try JSONEncoder().encode(token), for: configuration.tokenAccount)
        return token.accessToken
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            throw ToolError("\(configuration.service) needs the internet, and this Mac is offline")
        } catch let error as URLError where error.code == .timedOut {
            throw ToolError("\(configuration.service) didn't respond in time")
        }
    }

    private static func randomURLSafe(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64URLEncoded
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
    }

    private struct ErrorResponse: Decodable {
        let error: String
    }
}
