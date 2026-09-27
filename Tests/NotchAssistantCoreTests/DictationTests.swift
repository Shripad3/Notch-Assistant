import Foundation
@testable import NotchAssistantCore
import Testing

struct DictationTests {
    func type(_ segments: [String]) -> (String, Bool) {
        var formatter = DictationFormatter()
        var text = ""
        for segment in segments {
            for edit in formatter.process(segment) {
                switch edit {
                case .insert(let piece): text += piece
                case .delete(let count): text.removeLast(min(count, text.count))
                case .stop: return (text, true)
                }
            }
        }
        return (text, false)
    }

    @Test func punctuationAndCapitals() {
        #expect(type(["hello there comma how are you question mark", "i am fine full stop"]).0 == "Hello there, how are you? I am fine.")
    }

    @Test func newLinesBothWays() {
        #expect(type(["first line new line second line go to a new line third"]).0 == "First line\nSecond line\nThird")
        #expect(type(["title new paragraph body text"]).0 == "Title\n\nBody text")
    }

    @Test func scratchThatRemovesTheLastThingSaid() {
        #expect(type(["keep this full stop", "delete me please", "scratch that", "and this"]).0 == "Keep this. And this")
        #expect(type(["keep this full stop wrong words scratch that"]).0 == "Keep this.")
    }

    @Test func stopEndsDictation() {
        let (text, stopped) = type(["last words full stop stop dictation", "never typed"])
        #expect(text == "Last words.")
        #expect(stopped)
    }

    @Test func transcriptsStopOnRequest() {
        #expect(DictationFormatter.transcriptStop(in: "That's all for today. Alfred, stop recording.") == ("That's all for today", true))
        #expect(DictationFormatter.transcriptStop(in: "We should stop the project").stop == false)
    }
}

struct CaptureRoutingTests {
    @Test(arguments: [
        ("start transcribing", "transcribe"),
        ("record this meeting", "transcribe"),
        ("stop recording", "transcribe"),
        ("summarise the meeting", "transcribe"),
        ("dictate", "dictate"),
        ("take dictation", "dictate"),
        ("type what I say", "dictate"),
        ("stop dictation", "dictate"),
    ])
    func routes(said: String, tool: String) {
        #expect(DirectMatcher.plan(for: said, tools: ToolRegistry.standard.tools)?.steps.first?.tool.name == tool)
    }

    @Test func noteBodiesKeepLines() {
        #expect(NoteTool.body(title: "T", text: "a\n\nb") == "<div><b>T</b></div><div>a</div><div><br></div><div>b</div>")
    }
}

struct DictationFixTests {
    @Test func recogniserLineBreaksSurvive() {
        var formatter = DictationFormatter()
        var text = ""
        for edit in formatter.process("first line\nsecond line\n\nthird") {
            if case .insert(let piece) = edit { text += piece }
        }
        #expect(text == "First line\nSecond line\n\nThird")
    }

    @Test(arguments: [
        ("start typing", "here", nil as String?),
        ("type", "here", nil),
        ("Type in hey Amay, this is a test message", "here", "hey Amay, this is a test message"),
        ("type hello there", "here", "hello there"),
        ("start typing in notes", "notes", nil),
        ("stop typing", "stop", nil),
    ])
    func phrasings(said: String, target: String, text: String?) throws {
        let args = try #require(DirectCommand(said).flatMap { DictationTool().directArguments(for: $0) })
        #expect(args.target == target)
        #expect(args.text == text)
    }

    @Test func aLoneYesHasNothingToAnswer() {
        #expect(SmallTalk.reply(to: "Yes") == "There's nothing waiting for an answer.")
    }

    @Test func silenceShowsTheQuestionAgain() {
        #expect(StateMachine.transition(from: .listening(partial: ""), on: .needsConfirmation("Send?", [])) == .confirm("Send?", []))
    }

    @Test(arguments: [("no facts", false), ("long day", false), ("None.", false), ("Has a presentation on Friday", true)])
    func junkMemories(text: String, kept: Bool) {
        #expect(Conversation.worthKeeping(text) == kept)
    }
}

struct ScreenCaptureTests {
    @Test(arguments: [
        ("take a screenshot", "screen", nil as String?),
        ("screenshot", "screen", nil),
        ("take a screen shot of this window", "window", nil),
        ("screenshot Safari", "window", "safari"),
        ("take a screenshot of part of the screen", "selection", nil),
        ("copy a screenshot", "clipboard", nil),
        ("capture the screen", "screen", nil),
    ])
    func screenshots(said: String, target: String, app: String?) throws {
        let args = try #require(DirectCommand(said).flatMap { ScreenshotTool().directArguments(for: $0) })
        #expect(args.target == target)
        #expect(args.app == app)
    }

    @Test(arguments: [
        ("record my screen", "start", false, false),
        ("record my screen with sound", "start", true, false),
        ("record my screen with my voice", "start", false, true),
        ("record the screen with audio", "start", true, true),
        ("record part of the screen", "selection", false, false),
        ("stop screen recording", "stop", false, false),
    ])
    func recordings(said: String, action: String, sound: Bool, voice: Bool) throws {
        let args = try #require(DirectCommand(said).flatMap { ScreenRecordTool().directArguments(for: $0) })
        #expect(args.action == action)
        #expect((args.sound ?? false) == sound)
        #expect((args.voice ?? false) == voice)
    }

    @Test(arguments: [
        ("take a screenshot", "screenshot"),
        ("record my screen", "recordScreen"),
        ("record this meeting", "transcribe"),
        ("open my latest screenshot", "openFile"),
        ("start typing", "dictate"),
    ])
    func routes(said: String, tool: String) {
        #expect(DirectMatcher.plan(for: said, tools: ToolRegistry.standard.tools)?.steps.first?.tool.name == tool)
    }

    @Test func fileNamesLikeMacOS() {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 10, minute: 15, second: 30))!
        #expect(CaptureFolder.name("Screenshot", "png", date: date) == "Screenshot 2026-09-28 at 10.15.30.png")
    }
}
