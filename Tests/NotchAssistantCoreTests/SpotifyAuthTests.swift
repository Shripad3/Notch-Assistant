import CryptoKit
import Foundation
@testable import NotchAssistantCore
import Testing

struct SpotifyAuthTests {
    /// Expected value computed independently with Python's hashlib/base64.
    @Test func pkceChallengeMatchesReference() {
        let verifier = "notch-assistant-pkce-check~._-0123456789abcdefABCDEF"
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        #expect(challenge == "275qpbS05D8IrK00ea_kxBaq-4_KkVGztyYLWpSOQRo")
    }

    /// A real HTTP request to the loopback receiver, as the browser makes it.
    @Test func loopbackReceivesCallback() async throws {
        let loopback = try LoopbackRedirect()
        let port = try await loopback.start()
        #expect(port > 0)
        async let received = loopback.callback(timeout: .seconds(5))
        let url = URL(string: "http://127.0.0.1:\(port)/callback?code=abc123&state=xyz")!
        let (body, response) = try await URLSession.shared.data(from: url)
        let query = try await received.queryItems ?? []
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: body, as: UTF8.self).contains("Spotify is connected"))
        #expect(query.first { $0.name == "code" }?.value == "abc123")
        #expect(query.first { $0.name == "state" }?.value == "xyz")
    }

    @Test func loopbackTimesOut() async throws {
        let loopback = try LoopbackRedirect()
        _ = try await loopback.start()
        await #expect(throws: ToolError.self) {
            _ = try await loopback.callback(timeout: .milliseconds(200))
        }
    }
}

struct SpotifyRedirectTests {
    /// Must match the dashboard entry exactly, in the form Spotify documents.
    @Test func redirectURIHasExplicitLoopbackAndPort() {
        #expect(SpotifyWebAPI.registeredRedirectURI == "http://127.0.0.1:43821/callback")
    }

    @Test func listensOnTheFixedPort() async throws {
        let loopback = try LoopbackRedirect(port: SpotifyWebAPI.redirectPort)
        #expect(try await loopback.start() == SpotifyWebAPI.redirectPort)
        async let received = loopback.callback(timeout: .seconds(5))
        _ = try await URLSession.shared.data(from: URL(string: SpotifyWebAPI.registeredRedirectURI + "?code=a&state=b")!)
        #expect(try await received.queryItems?.first { $0.name == "code" }?.value == "a")
    }
}
