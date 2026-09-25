import Foundation
import FoundationModels
@testable import NotchAssistantCore
import Testing

struct FileQueryTests {
    @Test func invoiceFromLastMonth() {
        let query = FileQuery(spoken: "my invoice from last month")
        #expect(query == FileQuery(words: ["invoice"], kind: nil, period: .lastMonth))
    }

    @Test func kindAndPeriod() {
        #expect(FileQuery(spoken: "the latest screenshot") == FileQuery(words: [], kind: .screenshot))
        #expect(FileQuery(spoken: "tax pdf from last year") == FileQuery(words: ["tax"], kind: .pdf, period: .lastYear))
    }

    /// Plain names are apps or sites, never files.
    @Test(arguments: ["spotify", "youtube", "visual studio code", "again"])
    func notAFile(spoken: String) {
        #expect(FileQuery(spoken: spoken) == nil)
    }

    @Test func modelTextDropsFiller() {
        #expect(FileQuery(text: "my tax file", kind: nil, period: nil).words == ["tax"])
    }
}

struct FilePeriodTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        calendar.firstWeekday = 2
        return calendar
    }()

    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: text)!
    }

    @Test func lastMonthFromSeptember() {
        let range = FilePeriod.lastMonth.range(now: date("2026-09-25"), calendar: calendar)
        #expect(range == date("2026-08-01")..<date("2026-09-01"))
    }

    @Test func lastMonthInJanuaryIsDecember() {
        let range = FilePeriod.lastMonth.range(now: date("2026-01-10"), calendar: calendar)
        #expect(range == date("2025-12-01")..<date("2026-01-01"))
    }

    @Test func yesterday() {
        let range = FilePeriod.yesterday.range(now: date("2026-09-25"), calendar: calendar)
        #expect(range == date("2026-09-24")..<date("2026-09-25"))
    }
}

struct FileRankingTests {
    let now = Date()

    @Test func betterNameBeatsNewer() {
        let exact = FoundFile(url: URL(fileURLWithPath: "/a/Invoice.pdf"), name: "Invoice.pdf", date: now.addingTimeInterval(-86400 * 20))
        let partial = FoundFile(url: URL(fileURLWithPath: "/a/Invoices-old-scan.pdf"), name: "Invoices-old-scan.pdf", date: now)
        #expect(FileRanking.rank([partial, exact], for: FileQuery(words: ["invoice"])).first == exact)
    }

    @Test func equalNamesPreferNewest() {
        let old = FoundFile(url: URL(fileURLWithPath: "/a/Invoice July.pdf"), name: "Invoice July.pdf", date: now.addingTimeInterval(-86400 * 40))
        let new = FoundFile(url: URL(fileURLWithPath: "/a/Invoice August.pdf"), name: "Invoice August.pdf", date: now)
        #expect(FileRanking.rank([old, new], for: FileQuery(words: ["invoice"])).first == new)
    }
}

struct FileValidationTests {
    /// Real files and symlinks in a temporary tree, with a fake "Documents" root.
    let base: URL
    let root: URL
    let outside: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appending(path: "notch-validation-\(UUID().uuidString)").resolvingSymlinksInPath()
        root = base.appending(path: "Documents")
        outside = base.appending(path: "Secrets")
        let fm = FileManager.default
        for dir in [root, outside, root.appending(path: ".hidden"), root.appending(path: "Tool.app"), root.appending(path: "Library")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        for file in [root.appending(path: "Invoice.pdf"), outside.appending(path: "keys.txt")] {
            try Data().write(to: file)
        }
        try fm.createSymbolicLink(at: root.appending(path: "escape"), withDestinationURL: outside.appending(path: "keys.txt"))
    }

    @Test func fileInsideRootIsAllowed() {
        #expect(FileAccess.validated(root.appending(path: "Invoice.pdf"), roots: [root]) != nil)
    }

    @Test func symlinkOutOfRootIsRefused() {
        #expect(FileAccess.validated(root.appending(path: "escape"), roots: [root]) == nil)
    }

    @Test func dotDotTraversalIsRefused() {
        #expect(FileAccess.validated(root.appending(path: "../Secrets/keys.txt"), roots: [root]) == nil)
    }

    @Test(arguments: [".hidden/x", "Tool.app/Contents", "Library/prefs"])
    func deniedPlacesAreRefused(path: String) {
        #expect(FileAccess.validated(root.appending(path: path), roots: [root]) == nil)
    }

    @Test func rootItselfIsNotAFile() {
        #expect(FileAccess.validated(root, roots: [root]) == nil)
    }
}

struct FileRoutingTests {
    let tools = ToolRegistry(tools: ToolRegistry.standard.tools, isEnabled: { _ in true }).enabledTools()

    private func tool(_ transcript: String) -> String? {
        DirectMatcher.plan(for: transcript, tools: tools)?.steps.first?.tool.name
    }

    @Test func routes() {
        #expect(tool("Open my invoice from last month") == "openFile")
        #expect(tool("open the latest screenshot") == "openFile")
        #expect(tool("find my tax documents from last year") == "findFiles")
        #expect(tool("where is my passport scan") == "findFiles")
        #expect(tool("open spotify") == "openApp")
        #expect(tool("open youtube") == "openURL")
    }
}

struct CompoundCommandTests {
    let tools = ToolRegistry(tools: ToolRegistry.standard.tools, isEnabled: { _ in true }).enabledTools()

    @Test(arguments: [
        "Open Arc and play the Mat Armstrong YouTube video",
        "open spotify and then open gmail",
        "open my invoice then play music",
    ])
    func compoundGoesToModel(transcript: String) {
        #expect(DirectMatcher.plan(for: transcript, tools: tools) == nil)
    }
}

/// Real Spotlight, against this project's own folder.
struct SpotlightIntegrationTests {
    let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()

    @Test func findsTheSpecByName() async throws {
        let found = try await SpotlightSearch.run(FileQuery(words: ["technical", "specification"]), roots: [projectRoot])
        #expect(found.first?.name == "Notch Assistant Technical Specification.md")
    }

    /// Proves the date and screenshot clauses are valid Spotlight syntax.
    @Test func periodAndScreenshotQueriesExecute() async throws {
        let recent = try await SpotlightSearch.run(FileQuery(words: ["specification"], period: .thisYear), roots: [projectRoot])
        #expect(recent.first?.name == "Notch Assistant Technical Specification.md")
        let lastYear = try await SpotlightSearch.run(FileQuery(words: ["specification"], period: .lastYear), roots: [projectRoot])
        #expect(lastYear.isEmpty)
        _ = try await SpotlightSearch.run(FileQuery(words: [], kind: .screenshot), roots: [projectRoot])
    }

    @Test func nameSearchNeverMatchesContents() async throws {
        // "DynamicNotchKit" appears inside the spec, but in no file name there.
        let found = try await SpotlightSearch.run(FileQuery(words: ["dynamicnotchkit"], kind: .document), roots: [projectRoot.appending(path: "Notch Assistant Technical Specification.md").deletingLastPathComponent()])
        #expect(!found.contains { $0.name.hasSuffix("Specification.md") })
    }
}

struct FileGroundingTests {
    @Test func unspokenPeriodAndKindAreDropped() {
        let arguments = FileRequestArguments(name: "tax", kind: "document", period: "lastYear")
        let query = CommandContext.$transcript.withValue("what's inside my tax file") { arguments.query }
        #expect(query == FileQuery(words: ["tax"]))
    }

    @Test func spokenPeriodAndKindAreKept() {
        let arguments = FileRequestArguments(name: "tax", kind: "pdf", period: "lastYear")
        let query = CommandContext.$transcript.withValue("open my tax pdf from last year") { arguments.query }
        #expect(query == FileQuery(words: ["tax"], kind: .pdf, period: .lastYear))
    }

    @Test(arguments: ["open the file that mentions Acme", "what's inside my tax file", "find documents about the merger"])
    func contentRequestsAreDeclined(transcript: String) {
        #expect(throws: ToolError.self) {
            try CommandContext.$transcript.withValue(transcript) { try FileTools.refuseContentRequests() }
        }
    }

    @Test func ordinaryRequestIsNotDeclined() throws {
        try CommandContext.$transcript.withValue("open my invoice from last month") { try FileTools.refuseContentRequests() }
    }
}

struct FileFolderAndListingTests {
    let tools = ToolRegistry(tools: ToolRegistry.standard.tools, isEnabled: { _ in true }).enabledTools()

    private func step(_ transcript: String) -> (tool: String, query: FileQuery?)? {
        guard let step = DirectMatcher.plan(for: transcript, tools: tools)?.steps.first else { return nil }
        let arguments = try? FileRequestArguments(step.arguments)
        return (step.tool.name, CommandContext.$transcript.withValue(transcript) { arguments?.query })
    }

    @Test func listScreenshotsOnDesktop() {
        let result = step("Show me the list of all the screenshots in my desktop")
        #expect(result?.tool == "findFiles")
        #expect(result?.query == FileQuery(words: [], kind: .screenshot, folder: "Desktop"))
    }

    @Test func allFilesFromDesktop() {
        #expect(step("show me all the files on my desktop")?.query == FileQuery(words: [], folder: "Desktop"))
    }

    @Test func openLatestScreenshot() {
        let result = step("Open the latest screenshot")
        #expect(result?.tool == "openFile")
        #expect(result?.query == FileQuery(words: [], kind: .screenshot))
    }

    @Test(arguments: ["show me the weather", "find a good restaurant", "list the planets"])
    func notFileRequests(transcript: String) {
        #expect(step(transcript)?.tool != "findFiles")
    }
}

struct SpotlightQueryStringTests {
    @Test func namesKindsAndNoContent() {
        let text = SpotlightSearch.queryString(for: FileQuery(words: ["tax", "invoice"], kind: .pdf))
        #expect(text == "kMDItemFSName == \"*tax*\"cd && kMDItemFSName == \"*invoice*\"cd && kMDItemContentTypeTree == \"com.adobe.pdf\"")
        #expect(!text.contains("TextContent"))
    }

    @Test func screenshotsAndFolders() {
        #expect(SpotlightSearch.queryString(for: FileQuery(words: [], kind: .screenshot)) == "kMDItemIsScreenCapture == 1")
        #expect(SpotlightSearch.queryString(for: FileQuery(words: ["notes"])).contains("!= \"public.folder\""))
    }

    @Test func periodUsesBothDates() {
        let text = SpotlightSearch.queryString(for: FileQuery(words: ["x"], period: .lastMonth))
        #expect(text.contains("kMDItemFSContentChangeDate >= $time.iso("))
        #expect(text.contains("kMDItemDateAdded < $time.iso("))
    }
}

struct FileTokenTests {
    @Test func tokensAreOpaqueAndExpire() async throws {
        let file = FoundFile(url: URL(fileURLWithPath: "/tmp/secret/path/report.pdf"), name: "report.pdf", date: Date())
        let items = FileTokens.register([file])
        #expect(items.first?.id.hasPrefix("file_") == true)
        #expect(items.first?.title == "report.pdf")
        #expect(!(items.first?.id.contains("/") ?? true))
        ResultActions.reset()
        await #expect(throws: ToolError.self) { try await ResultActions.select(items[0].id) }
    }

    @Test func pathOutsideRootsIsRefusedAtOpen() async {
        // Registered, but /tmp is not a scoped root: the executor re-validates.
        let items = FileTokens.register([FoundFile(url: URL(fileURLWithPath: "/tmp/x.pdf"), name: "x.pdf", date: Date())])
        await #expect(throws: ToolError.self) { try await ResultActions.select(items[0].id) }
    }

    @Test func stringLiteralIsPlainResult() {
        let result: ToolResult = "Opened \("Notes")"
        #expect(result == ToolResult("Opened Notes"))
        #expect(result.items.isEmpty)
    }
}

struct BareFileNameTests {
    let tools = ToolRegistry(tools: ToolRegistry.standard.tools, isEnabled: { _ in true }).enabledTools()

    /// From the log: said without "open", this became a one-row list.
    @Test func bareNameWithTypeOpens() {
        let step = DirectMatcher.plan(for: "Foundations of process mining introduction.PDF", tools: tools)?.steps.first
        #expect(step?.tool.name == "openFile")
        let query = try? FileRequestArguments(step!.arguments).query
        #expect(query?.kind == .pdf)
        #expect(query?.words == ["foundations", "process", "mining", "introduction"])
    }

    @Test(arguments: ["pdf", "the weather", "screenshots"])
    func notBareNames(transcript: String) {
        #expect(DirectMatcher.plan(for: transcript, tools: tools)?.steps.first?.tool.name != "openFile")
    }
}
