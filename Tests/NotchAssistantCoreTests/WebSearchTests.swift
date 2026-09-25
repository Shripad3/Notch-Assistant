@testable import NotchAssistantCore
import Testing

struct WebSearchTests {
    @Test func buildsEncodedQueryURLs() {
        #expect(SearchEngine.google.url(for: "Mat Armstrong 911")?.absoluteString == "https://www.google.com/search?q=Mat%20Armstrong%20911")
        #expect(SearchEngine.duckDuckGo.url(for: "a&b=c")?.absoluteString == "https://duckduckgo.com/?q=a%26b%3Dc")
        #expect(SearchEngine.bing.url(for: " rust ")?.absoluteString == "https://www.bing.com/search?q=rust")
    }

    @Test func emptyQueryHasNoURL() {
        #expect(SearchEngine.google.url(for: "   ") == nil)
    }

}
