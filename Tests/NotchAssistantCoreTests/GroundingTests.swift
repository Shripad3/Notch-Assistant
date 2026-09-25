import Foundation
@testable import NotchAssistantCore
import Testing

struct GroundingTests {
    @Test(arguments: [
        ("Arc", "open youtube in arc", true),
        ("arc", "search for porsche prices", false), // not inside another word
        ("Safari", "open youtube", false),           // borrowed from an example
        ("Visual Studio Code", "open visual studio code please", true),
        ("Google Chrome", "open github in chrome", false),
        ("", "anything", false),
    ])
    func mentions(phrase: String, transcript: String, expected: Bool) {
        #expect(Grounding.mentions(phrase, in: transcript) == expected)
    }

    @Test(arguments: [
        ("https://www.youtube.com", "open youtube", true),
        ("https://www.youtube.com/", "open youtube", true),
        ("https://www.youtube.com/watch?v=_Q-V-Q-V-0g", "open arc and play the mat armstrong youtube video", false),
        ("https://github.com/apple", "go to github.com/apple", true),
        ("https://github.com/apple", "go to github", false),
    ])
    func spokenURLs(url: String, transcript: String, expected: Bool) {
        #expect(Grounding.isSpoken(URL(string: url)!, in: transcript) == expected)
    }

    @Test func homePageDropsPathAndQuery() {
        let url = URL(string: "https://www.youtube.com/watch?v=abc")!
        #expect(WebAddress.homePage(of: url)?.absoluteString == "https://www.youtube.com")
    }
}

struct TranscriptCleaningTests {
    @Test(arguments: [
        ("Open YouTube.", "Open YouTube"),
        ("  open spotify!  ", "open spotify"),
        ("Go to github.com.", "Go to github.com"),
        ("Search for \"banana bread\"?", "Search for \"banana bread"),
    ])
    func stripsSurroundingPunctuation(raw: String, expected: String) {
        #expect(FoundationModelsEngine.clean(raw) == expected)
    }
}

struct AliasGroundingTests {
    @Test func expandedAliasIsGrounded() {
        #expect(Grounding.spokenAlias(for: "Visual Studio Code", in: "open vs code") == "vscode")
        #expect(Grounding.spokenAlias(for: "Visual Studio Code", in: "open code") == "code")
        #expect(Grounding.spokenAlias(for: "Visual Studio Code", in: "open xcode") == nil)
        #expect(Grounding.spokenAlias(for: "Finder", in: "open again") == nil)
    }

    @Test func genericBrowser() {
        #expect(Grounding.mentionsGenericBrowser(in: "Open my browser"))
        #expect(!Grounding.mentionsGenericBrowser(in: "open arc"))
    }
}
