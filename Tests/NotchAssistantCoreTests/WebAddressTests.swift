@testable import NotchAssistantCore
import Testing

struct WebAddressTests {
    @Test(arguments: [
        ("youtube.com", "https://youtube.com"),
        ("https://www.youtube.com", "https://www.youtube.com"),
        ("http://example.com/path?q=1", "http://example.com/path?q=1"),
        ("  github.com  ", "https://github.com"),
    ])
    func accepts(raw: String, expected: String) {
        #expect(WebAddress.normalize(raw)?.absoluteString == expected)
    }

    @Test(arguments: [
        "file:///etc/passwd", "javascript:alert(1)", "spotify:track:123", "ftp://example.com",
        "youtube", "you tube.com", "", "https://", "https://.com", "x-apple.systempreferences:com.apple",
    ])
    func rejects(raw: String) {
        #expect(WebAddress.normalize(raw) == nil)
    }
}
