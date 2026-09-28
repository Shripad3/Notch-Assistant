@testable import NotchAssistantCore
import Synchronization
import Testing

struct ScreenTestNode: TextNode {
    var role: String
    var subrole = ""
    var texts: [String] = []
    var children: [any TextNode] = []
}

struct ScreenReadTests {
    /// A native "Save changes?" dialog, as Accessibility exposes it.
    static let dialog = ScreenTestNode(role: "AXWindow", texts: ["Save changes"], children: [
        ScreenTestNode(role: "AXStaticText", texts: ["Do you want to save the changes made to the document “Budget 2026”?"]),
        ScreenTestNode(role: "AXStaticText", texts: ["Your changes will be lost if you don't save them."]),
        ScreenTestNode(role: "AXButton", texts: ["Don't Save"]), ScreenTestNode(role: "AXButton", texts: ["Cancel"]), ScreenTestNode(role: "AXButton", texts: ["Save"]),
    ])

    @Test func nativeDialogsAreReadWithoutRecognition() async throws {
        let recognized = Mutex(false)
        let reading = try await ScreenText.read(root: Self.dialog, app: "Numbers") {
            recognized.withLock { $0 = true }
            return ""
        }
        #expect(!recognized.withLock { $0 })
        #expect(!reading.usedRecognition)
        #expect(reading.text.contains("Your changes will be lost"))
        #expect(reading.text.contains("Don't Save"))
    }

    @Test func thinWindowsFallBackToRecognition() async throws {
        let electron = ScreenTestNode(role: "AXWindow", texts: ["Figma"], children: [ScreenTestNode(role: "AXGroup")])
        let reading = try await ScreenText.read(root: electron, app: "Figma") { "Frame 12 — Button / Primary — Export 2x PNG, and a lot of layer names on the canvas" }
        #expect(reading.usedRecognition)
        #expect(reading.text.contains("Export 2x PNG"))
    }

    @Test func passwordFieldsAreNeverRead() async throws {
        let login = ScreenTestNode(role: "AXWindow", texts: ["Sign in"], children: [
            ScreenTestNode(role: "AXStaticText", texts: [String(repeating: "Enter your account details to continue. ", count: 4)]),
            ScreenTestNode(role: "AXTextField", texts: ["priya@example.com"]),
            ScreenTestNode(role: "AXSecureTextField", texts: ["hunter2-secret"]),
            ScreenTestNode(role: "AXTextField", subrole: "AXSecureTextField", texts: ["another-secret"]),
        ])
        let reading = try await ScreenText.read(root: login, app: "App") { "" }
        #expect(!reading.text.contains("hunter2"))
        #expect(!reading.text.contains("another-secret"))
        #expect(reading.text.contains("priya@example.com"))
    }

    @Test func secretsOnScreenAreHidden() async throws {
        let terminal = ScreenTestNode(role: "AXWindow", children: [
            ScreenTestNode(role: "AXTextArea", texts: [String(repeating: "build log line\n", count: 10) + "export API_KEY=sk-abcdefghijklmnopqrstuvwxyz\npassword: correct-horse"]),
        ])
        let reading = try await ScreenText.read(root: terminal, app: "Terminal") { "" }
        #expect(!reading.text.contains("sk-abcdefghijklmnopqrstuvwxyz"))
        #expect(!reading.text.contains("correct-horse"))
    }

    @Test(arguments: [
        ("what's on my screen", "readScreen"),
        ("what does this error say", "readScreen"),
        ("read this to me", "readScreen"),
        ("what's this app asking me", "readScreen"),
        ("summarise this page", "readScreen"),
        ("summarise the contract", "readFile"),
        ("what's on my calendar tomorrow", "calendar"),
    ])
    func routes(said: String, tool: String) {
        #expect(DirectMatcher.plan(for: said, tools: ToolRegistry.standard.tools)?.steps.first?.tool.name == tool)
    }
}
