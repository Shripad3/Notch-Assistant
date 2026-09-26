import CoreGraphics
import Foundation
@testable import NotchAssistantCore
import Testing

struct WindowToolTests {
    func args(_ said: String) -> WindowArguments? {
        DirectCommand(said).flatMap { WindowTool().directArguments(for: $0) }
    }

    @Test(arguments: [
        ("put Safari on the left half", "leftHalf", "safari" as String?),
        ("move this window to the right", "rightHalf", nil),
        ("snap Arc to the left side", "leftHalf", "arc"),
        ("maximize the window", "maximize", nil),
        ("make Notes full screen", "fullScreen", "notes"),
        ("exit full screen", "exitFullScreen", nil),
        ("minimise this", "minimize", nil),
        ("move this to the other display", "nextDisplay", nil),
        ("center the window", "center", nil),
        ("top half", "topHalf", nil),
    ])
    func matches(said: String, action: String, app: String?) throws {
        let parsed = try #require(args(said))
        #expect(parsed.action == action)
        #expect(parsed.app == app)
    }

    @Test(arguments: ["what's on the left", "open the left door", "play full screen video on youtube", "move my screenshot to documents", "turn right at the lights"])
    func ignores(said: String) {
        #expect(args(said) == nil)
    }

    @Test func halvesAndCentre() {
        let visible = CGRect(x: 0, y: 80, width: 1512, height: 862)
        let window = CGRect(x: 10, y: 100, width: 800, height: 600)
        #expect(WindowLayout.frame(for: "leftHalf", in: visible, current: window) == CGRect(x: 0, y: 80, width: 756, height: 862))
        #expect(WindowLayout.frame(for: "rightHalf", in: visible, current: window) == CGRect(x: 756, y: 80, width: 756, height: 862))
        #expect(WindowLayout.frame(for: "topHalf", in: visible, current: window) == CGRect(x: 0, y: 511, width: 1512, height: 431))
        #expect(WindowLayout.frame(for: "center", in: visible, current: window) == CGRect(x: 356, y: 211, width: 800, height: 600))
        #expect(WindowLayout.frame(for: "maximize", in: visible, current: window) == visible)
    }

    @Test func flipsBetweenCoordinateSystems() {
        let rect = CGRect(x: 0, y: 80, width: 756, height: 862)
        let ax = WindowLayout.flipped(rect, primaryHeight: 982)
        #expect(ax == CGRect(x: 0, y: 40, width: 756, height: 862))
        #expect(WindowLayout.flipped(ax, primaryHeight: 982) == rect)
    }

    @Test func movesToAnotherDisplayProportionally() {
        let laptop = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let external = CGRect(x: 1000, y: 0, width: 2000, height: 1600)
        let moved = WindowLayout.moved(CGRect(x: 0, y: 0, width: 500, height: 800), from: laptop, to: external)
        #expect(moved == CGRect(x: 1000, y: 0, width: 1000, height: 1600))
    }
}

struct ClipboardAndNoteTests {
    @Test(arguments: [
        ("what's on my clipboard", "read"),
        ("what did I copy", "read"),
        ("clear the clipboard", "clear"),
        ("remove formatting from the clipboard", "plainText"),
        ("paste as plain text", "pastePlainText"),
    ])
    func clipboard(said: String, action: String) {
        #expect(DirectCommand(said).flatMap { ClipboardTool().directArguments(for: $0) }?.action == action)
    }

    @Test(arguments: [
        ("Note that the Wi-Fi password is on the router.", "the Wi-Fi password is on the router"),
        ("take a note: buy more coffee", "buy more coffee"),
        ("Make a note saying call the plumber on Monday", "call the plumber on Monday"),
        ("jot down 42 is the answer", "42 is the answer"),
        ("write down pick up the dry cleaning", "pick up the dry cleaning"),
    ])
    func notes(said: String, text: String) {
        #expect(DirectCommand(said).flatMap { NoteTool().directArguments(for: $0) }?.text == text)
    }

    @Test(arguments: ["notes", "open notes", "show my notes", "take a note"])
    func notNotes(said: String) {
        #expect(DirectCommand(said).flatMap { NoteTool().directArguments(for: $0) } == nil)
    }

    @Test func escapesHTML() {
        #expect(NoteTool.html("a < b & c > d") == "a &lt; b &amp; c &gt; d")
    }

    @Test(arguments: [
        ("put Safari on the left half", "arrangeWindow"),
        ("note that the meeting moved to 3", "takeNote"),
        ("what's on my clipboard", "clipboard"),
        ("move my latest screenshot to documents", "organiseFiles"),
        ("open notes", "openApp"),
    ])
    func routes(said: String, tool: String) {
        #expect(DirectMatcher.plan(for: said, tools: ToolRegistry.standard.tools)?.steps.first?.tool.name == tool)
    }
}
