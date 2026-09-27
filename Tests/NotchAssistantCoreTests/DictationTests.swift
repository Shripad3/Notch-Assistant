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
