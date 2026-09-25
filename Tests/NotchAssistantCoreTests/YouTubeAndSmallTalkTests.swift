import Foundation
import FoundationModels
@testable import NotchAssistantCore
import Testing

struct YouTubeRoutingTests {
    let tools = ToolRegistry(tools: ToolRegistry.standard.tools, isEnabled: { _ in true }).enabledTools()

    private func youtube(_ transcript: String) -> PlayYouTubeArguments? {
        guard let step = DirectMatcher.plan(for: transcript, tools: tools)?.steps.first, step.tool.name == "playYouTube" else { return nil }
        return try? PlayYouTubeArguments(step.arguments)
    }

    /// The four transcripts that failed, verbatim from the log.
    @Test func openLatestVideo() {
        let args = youtube("Open Matt Armstrong's latest video on YouTube")
        #expect(args?.query == "matt armstrong")
        #expect(args?.latest == true)
        #expect(args?.browser == nil)
    }

    @Test func playVideoOnYouTube() {
        #expect(youtube("Play Matt Armstrong's YouTube video on YouTube")?.query == "matt armstrong")
    }

    @Test func playInArcBrowser() {
        let args = youtube("Play Matt Armstrong video on YouTube in arc browser")
        #expect(args?.query == "matt armstrong")
        #expect(args?.browser == "arc")
    }

    @Test func playLatestInArc() {
        let args = youtube("play mat armstrong latest video on youtube in arc browser")
        #expect(args?.query == "mat armstrong")
        #expect(args?.latest == true)
        #expect(args?.browser == "arc")
    }

    @Test func othersUnaffected() {
        let plan = { (t: String) in DirectMatcher.plan(for: t, tools: tools)?.steps.first?.tool.name }
        #expect(plan("open youtube") == "openURL")
        #expect(plan("play bohemian rhapsody") == "controlSpotify")
        #expect(plan("open my invoice from last month") == "openFile")
    }

    @Test func searchURLs() {
        #expect(PlayYouTubeTool.searchURL(for: "matt armstrong", latest: false)?.absoluteString
            == "https://www.youtube.com/results?search_query=matt%20armstrong")
        #expect(PlayYouTubeTool.searchURL(for: "matt armstrong", latest: true)?.absoluteString
            == "https://www.youtube.com/results?search_query=matt%20armstrong&sp=CAI%3D")
        #expect(PlayYouTubeTool.searchURL(for: "  ", latest: false) == nil)
    }
}

struct SmallTalkTests {
    @Test(arguments: ["Hi how are you", "hello", "Good morning Alfred", "thanks", "What can you do?", "Alfred"])
    func answered(transcript: String) {
        #expect(SmallTalk.reply(to: transcript) != nil)
    }

    @Test(arguments: ["open spotify", "hi open spotify", "thanks open youtube", "good morning playlist"])
    func notSmallTalk(transcript: String) {
        #expect(SmallTalk.reply(to: transcript) == nil)
    }

    @Test func replyIsItsOwnState() {
        #expect(StateMachine.transition(from: .thinking(transcript: "hi"), on: .textOnly("Hello")) == .reply("Hello"))
        #expect(StateMachine.transition(from: .reply("Hello"), on: .dismiss) == .idle)
    }
}

struct SystemControlGroundingTests {
    @Test func chitChatCannotChangeVolume() async {
        let tool = SystemControlTool()
        await #expect(throws: ToolError.self) {
            try await CommandContext.$transcript.withValue("Hi how are you") {
                try await tool.execute(SystemControlArguments(action: "volumeDown", value: nil))
            }
        }
    }
}

struct BrowserGroundingTests {
    @Test func namedBrowserCarriesOver() throws {
        let safari = CommandContext.$transcript.withValue("open safari and play the mat armstrong youtube video") {
            Browser.grounded(nil)
        }
        #expect(safari == "Safari") // Always installed, so this runs anywhere.
    }

    @Test func unnamedBrowserStaysDefault() {
        #expect(CommandContext.$transcript.withValue("play the mat armstrong video on youtube") { Browser.grounded(nil) } == nil)
    }

    @Test func inventedBrowserIsDropped() {
        #expect(CommandContext.$transcript.withValue("open youtube") { Browser.grounded("Safari") } == nil)
    }
}

struct YouTubeAutoplayRuleTests {
    @Test(arguments: [
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://www.youtube.com/watch?v=abc123&t=42s",
        "https://m.youtube.com/watch?v=abc123",
    ])
    func videos(url: String) {
        #expect(YouTubeAutoplay.isVideo(URL(string: url)!))
    }

    @Test(arguments: [
        "https://www.youtube.com/shorts/abc123",
        "https://www.youtube.com/@MatArmstrong",
        "https://www.youtube.com/playlist?list=PL123",
        "https://www.youtube.com/watch?list=PL123",
        "https://www.youtube.com/watch?v=abc&adurl=https://example.com",
        "https://www.googleadservices.com/pagead/aclk?sa=L",
        "https://evil.example/watch?v=abc",
        "https://notyoutube.com/watch?v=abc",
    ])
    func notVideos(url: String) {
        #expect(!YouTubeAutoplay.isVideo(URL(string: url)!))
    }

    @Test func videoID() {
        #expect(YouTubeAutoplay.videoID(URL(string: "https://www.youtube.com/watch?v=abc123&t=4")!) == "abc123")
    }
}

struct YouTubeCanonicalURLTests {
    @Test func rebuildsFromIDOnly() {
        let url = URL(string: "https://www.youtube.com/watch?v=abc_D-12&pp=ygUF&t=30s")!
        #expect(YouTubeAutoplay.canonical(url)?.absoluteString == "https://www.youtube.com/watch?v=abc_D-12")
    }

    /// Nothing that could break out of the AppleScript string.
    @Test func rejectsOddIDs() {
        #expect(YouTubeAutoplay.canonical(URL(string: "https://www.youtube.com/watch?v=a%22b")!) == nil)
    }
}
