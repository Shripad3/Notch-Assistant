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
