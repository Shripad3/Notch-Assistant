import FoundationModels
@testable import NotchAssistantCore
import Testing

struct OrganiseRoutingTests {
    let tools = ToolRegistry(tools: ToolRegistry.standard.tools, isEnabled: { _ in true }).enabledTools()

    private func step(_ transcript: String) -> (tool: String, args: OrganiseFilesArguments?)? {
        guard let step = DirectMatcher.plan(for: transcript, tools: tools)?.steps.first else { return nil }
        return (step.tool.name, try? OrganiseFilesArguments(step.arguments))
    }

    @Test func rename() {
        let result = step("Rename my invoice from last month to Invoice August")
        #expect(result?.tool == "organiseFiles")
        #expect(result?.args?.operation == "rename")
        #expect(result?.args?.name == "invoice")
        #expect(result?.args?.period == "lastMonth")
        #expect(result?.args?.newName == "invoice august")
    }

    @Test func moveIntoNewFolder() {
        let result = step("move my screenshots from today into a folder called receipts")
        #expect(result?.args?.operation == "move")
        #expect(result?.args?.kind == "screenshot")
        #expect(result?.args?.period == "today")
        #expect(result?.args?.destination == "receipts")
    }

    @Test func putAndCopy() {
        #expect(step("put the tax pdfs in downloads into documents")?.args?.destination == "documents")
        #expect(step("copy my presentation to desktop")?.args?.operation == "copy")
    }

    @Test(arguments: ["delete my old draft pdf", "trash my screenshots from yesterday", "move my screenshots to the trash", "get rid of my old invoices from last year"])
    func trash(transcript: String) {
        #expect(step(transcript)?.args?.operation == "trash")
    }

    @Test func createFolder() {
        let result = step("create a folder called Taxes 2026 on my desktop")
        #expect(result?.args?.operation == "createFolder")
        #expect(result?.args?.newName == "taxes 2026")
        #expect(result?.args?.folder == "Desktop")
    }

    @Test(arguments: ["undo", "Undo that.", "put it back"])
    func undo(transcript: String) {
        #expect(DirectMatcher.plan(for: transcript, tools: tools)?.steps.first?.tool.name == "undoFileChange")
    }

    /// Opening and listing are unaffected, and "move" isn't a bare file name.
    @Test func othersUnaffected() {
        let tool = { (t: String) in DirectMatcher.plan(for: t, tools: tools)?.steps.first?.tool.name }
        #expect(tool("open my invoice from last month") == "openFile")
        #expect(tool("find my tax documents from last year") == "findFiles")
        #expect(tool("Foundations of process mining introduction.PDF") == "openFile")
        #expect(tool("move my screenshots to receipts") == "organiseFiles")
    }

    @Test func destinationCleaning() {
        #expect(FileDestination.clean("a new folder called Receipts") == "receipts")
        #expect(FileDestination.clean("the Projects folder") == "projects")
        #expect(FileDestination.clean("my desktop") == "desktop")
    }
}

struct ConfirmationTests {
    @Test(arguments: [("Yes", true), ("yes please", true), ("Go ahead.", true), ("no", false), ("Cancel", false), ("never mind", false)] as [(String, Bool)])
    func answers(transcript: String, expected: Bool) {
        #expect(Confirmations.answer(in: transcript) == expected)
    }

    @Test func otherSpeechIsANewCommand() {
        #expect(Confirmations.answer(in: "open spotify") == nil)
        #expect(Confirmations.answer(in: "yes open spotify") == nil)
    }

    let rows = [ResultItem(id: "r1", title: "a.png", detail: "→ Receipts", symbol: "doc")]

    @Test func confirmStateFlow() {
        let acting = AssistantState.acting(tool: ToolLabel(name: "organiseFiles", title: "Files", symbol: "folder"), target: "")
        #expect(StateMachine.transition(from: acting, on: .needsConfirmation("Move 2 files?", rows)) == .confirm("Move 2 files?", rows))
        #expect(StateMachine.transition(from: .confirm("q", rows), on: .selected("Moved 2 files")) == .result("Moved 2 files"))
        #expect(StateMachine.transition(from: .confirm("q", rows), on: .activation) == .listening(partial: ""))
        #expect(StateMachine.transition(from: .confirm("q", rows), on: .cancel) == .idle)
        #expect(StateMachine.transition(from: .confirm("q", rows), on: .dismiss) == .idle)
    }
}

struct EverythingTests {
    let tools = ToolRegistry(tools: ToolRegistry.standard.tools, isEnabled: { _ in true }).enabledTools()

    /// "Everything" is every file in the folder: the batch limits then apply
    /// (confirm up to 20, refuse more), never a file named "everything".
    @Test func everythingMeansTheWholeFolder() throws {
        let step = DirectMatcher.plan(for: "delete everything in downloads", tools: tools)?.steps.first
        let args = try OrganiseFilesArguments(step!.arguments)
        #expect(args.operation == "trash")
        #expect(args.name.isEmpty)
        #expect(args.folder == "Downloads")
    }
}

struct ToolRouterTests {
    let tools = ToolRegistry(tools: ToolRegistry.standard.tools, isEnabled: { _ in true }).enabledTools()

    private func names(_ transcript: String) -> [String] {
        ToolRouter.relevant(for: transcript, among: tools).map(\.name)
    }

    @Test func atMostFour() {
        #expect(names("open the file and play music on youtube then move it to the trash and search google").count <= ToolRouter.maximum)
    }

    @Test func picksByWhatWasSaid() {
        #expect(names("change the name of my resume to CV").contains("organiseFiles"))
        #expect(names("can you tidy up by moving the screenshots on my desktop into a folder").contains("organiseFiles"))
        #expect(names("put on something to listen to").contains("controlSpotify"))
        #expect(names("make the screen a bit darker").first == "systemControl")
        #expect(names("Open Arc and play the Mat Armstrong YouTube video").contains("playYouTube"))
    }

    @Test func fallsBackToGeneralTools() {
        #expect(names("banana") == ["openApp", "openURL", "webSearch"])
    }
}

struct BareNameTighteningTests {
    let tools = ToolRegistry(tools: ToolRegistry.standard.tools, isEnabled: { _ in true }).enabledTools()

    @Test(arguments: [
        "can you tidy up by moving the screenshots on my desktop into a screenshots folder",
        "please bin that old budget spreadsheet",
    ])
    func sentencesAreNotBareNames(transcript: String) {
        #expect(DirectMatcher.plan(for: transcript, tools: tools)?.steps.first?.tool.name != "openFile")
    }

    @Test func binIsTrash() throws {
        let step = DirectMatcher.plan(for: "bin my old budget spreadsheet", tools: tools)?.steps.first
        #expect(try OrganiseFilesArguments(step!.arguments).operation == "trash")
    }
}

struct OrganiseGroundingTests {
    private func args(_ operation: String, name: String = "x", newName: String? = nil, destination: String? = nil) -> OrganiseFilesArguments {
        OrganiseFilesArguments(operation: operation, name: name, kind: nil, period: nil, folder: nil, newName: newName, destination: destination)
    }

    /// From the model: "put on something to listen to" → rename "something".
    @Test func inventedRenameIsRefused() {
        #expect(!OrganiseFilesTool.isGrounded(args("rename", name: "something", newName: "something else"), in: "put on something to listen to"))
    }

    @Test func spokenChangesAreAllowed() {
        #expect(OrganiseFilesTool.isGrounded(args("rename", newName: "CV"), in: "change the name of my resume to CV"))
        #expect(OrganiseFilesTool.isGrounded(args("move", destination: "screenshots"), in: "tidy up by moving the screenshots into a screenshots folder"))
        #expect(OrganiseFilesTool.isGrounded(args("trash"), in: "please bin that old budget spreadsheet"))
    }

    @Test func destinationMustBeSaid() {
        #expect(!OrganiseFilesTool.isGrounded(args("move", destination: "Archive"), in: "move my screenshots somewhere"))
    }

    /// Reading is allowed now (`readFile`); changing a file's contents never is.
    @Test(arguments: ["edit my notes file", "rewrite my essay", "fix the typo in the contract", "add a line to my notes"])
    func contentChangesDeclined(transcript: String) {
        #expect(ContentRequests.refusal(for: transcript) != nil)
    }

    @Test func kindWordsLeaveTheName() {
        #expect(FileQuery(text: "screenshots", kind: .screenshot, period: nil).words.isEmpty)
    }
}
