import FoundationModels
@testable import NotchAssistantCore
import Testing

struct DirectCommandTests {
    @Test(arguments: [
        ("Open YouTube", "open", "youtube"),
        ("please open spotify", "open", "spotify"),
        ("Go to github.com", "go to", "github com"),
        ("search for porsche 911 prices", "search for", "porsche 911 prices"),
        ("Search porsche", "search", "porsche"),
        ("Look up the weather please", "look up", "the weather"),
    ])
    func splits(transcript: String, verb: String, rest: String) {
        let command = DirectCommand(transcript)
        #expect(command?.verb == verb)
        #expect(command?.rest == rest)
    }

    @Test func noKnownVerbKeepsWholeText() {
        let command = DirectCommand("Mute.")
        #expect(command?.verb == "")
        #expect(command?.rest == "mute")
        #expect(command?.text == "mute")
    }

    @Test func emptyIsNil() {
        #expect(DirectCommand("  . ") == nil)
    }

    @Test func browserSuffix() {
        let target = DirectCommand("open youtube in arc")?.target
        #expect(target?.thing == "youtube")
        #expect(target?.browser == "arc")
        #expect(DirectCommand("open youtube")?.target.browser == nil)
    }
}

struct DirectMatchTests {
    let tools = ToolRegistry(tools: ToolRegistry.standard.tools, isEnabled: { _ in true }).enabledTools()

    private func plan(_ transcript: String) -> (tool: String, json: String)? {
        DirectMatcher.plan(for: transcript, tools: tools).map { ($0.steps[0].tool.name, $0.steps[0].arguments.jsonString) }
    }

    @Test func knownSite() {
        #expect(plan("Open YouTube")?.tool == "openURL")
        #expect(plan("go to gmail")?.json.contains("mail.google.com") == true)
    }

    @Test func spokenDomain() {
        #expect(plan("Go to github.com")?.json.contains("https://github.com") == true)
        #expect(plan("open github dot com")?.json.contains("https://github.com") == true)
    }

    @Test func searches() {
        #expect(plan("search for banana bread")?.tool == "webSearch")
        #expect(plan("google porsche 911")?.tool == "webSearch")
    }

    @Test func genericBrowserIsAnApp() {
        #expect(plan("open my browser")?.tool == "openApp")
    }

    /// Anything not clearly simple must reach the model.
    @Test(arguments: [
        "open again", "open best comics", "Open Arc and play the Mat Armstrong YouTube video",
        "open youtube in some browser i don't have",
    ])
    func leftToModel(transcript: String) {
        #expect(plan(transcript) == nil)
    }

    @Test func spokenDomains() {
        #expect(WebAddress.spoken("github com")?.absoluteString == "https://github.com")
        #expect(WebAddress.spoken("best comics") == nil)
        #expect(WebAddress.spoken("github com apple") == nil)
    }
}
