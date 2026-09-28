import AppKit
import FoundationModels

@Generable
struct FileRequestArguments: Sendable {
    @Guide(description: "Words from the file's name, e.g. \"invoice\" or \"tax return\". Empty if only a type or date was given")
    var name: String
    @Guide(description: "File type if said: document, pdf, image, screenshot, video, audio, spreadsheet, presentation or folder")
    var kind: String?
    @Guide(description: "When it's from, if said: today, yesterday, thisWeek, lastWeek, thisMonth, lastMonth, thisYear or lastYear")
    var period: String?
    @Guide(description: "Folder if said: Desktop, Documents or Downloads")
    var folder: String?

    /// The query, keeping only what the user actually said: the model added
    /// periods and kinds nobody mentioned ("what's inside my tax file" came
    /// back with period lastYear), which would silently narrow the search.
    var query: FileQuery {
        var kind = kind.flatMap(FileKind.init(rawValue:))
        var period = period.flatMap(FilePeriod.init(rawValue:))
        if let transcript = CommandContext.transcript {
            let spoken = Set(AppNameMatcher.normalize(transcript).split(separator: " ").map(String.init))
            if let chosen = kind, !spoken.contains(where: { FileKind(spokenWord: $0) == chosen }) { kind = nil }
            if let chosen = period, !chosen.phrases.contains(where: { Grounding.mentions($0, in: transcript) }) { period = nil }
        }
        var folder = folder.flatMap { name in FileQuery.folders[name.lowercased()] }
        if let chosen = folder, let transcript = CommandContext.transcript,
           !Grounding.mentions(chosen, in: transcript) {
            folder = nil
        }
        return FileQuery(text: name, kind: kind, period: period, folder: folder)
    }

    var summary: String {
        [name.isEmpty ? nil : name, kind, period.map(Self.describe), folder.map { "in \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    init(name: String, kind: String?, period: String?, folder: String? = nil) {
        self.name = name
        self.kind = kind
        self.period = period
        self.folder = folder
    }

    init(_ query: FileQuery) {
        self.init(name: query.words.joined(separator: " "), kind: query.kind?.rawValue, period: query.period?.rawValue, folder: query.folder)
    }

    private static func describe(_ period: String) -> String {
        FilePeriod(rawValue: period)?.phrases.last ?? period
    }
}

/// Opens the best match for a description: the name match first, then the
/// most recent. Opening hands the file to its app; the agent never reads it.
struct OpenFileTool: AssistantTool {
    let name = "openFile"
    let title = "Open file"
    let symbol = "doc"
    let keywords: Set<String> = ["open", "file", "files", "document", "pdf", "my", "show", "screenshot", "photo", "presentation"]
    let description = """
        Open a file on this Mac, found by its name, type and date, never by what is inside it. \
        "open my invoice from last month" → name "invoice", period "lastMonth". \
        "open the latest screenshot" → name "", kind "screenshot".
        """
    let requiresNetwork = false
    let permission = ToolPermission.files
    let reversibility = Reversibility.notApplicable

    func target(of arguments: FileRequestArguments) -> String {
        arguments.summary
    }

    func execute(_ arguments: FileRequestArguments) async throws -> ToolResult {
        try FileAccess.ensureAccess()
        let found = try await SpotlightSearch.run(arguments.query)
        guard let best = found.first else { throw FileTools.notFound(arguments) }
        let opened = try await FileTools.open(best)
        let others = found.count - 1
        return ToolResult(others > 0 ? "\(opened) · \(others) other match\(others == 1 ? "" : "es")" : opened)
    }

    static let extensions: Set<String> = ["pdf", "doc", "docx", "pages", "key", "pptx", "ppt", "xls", "xlsx", "numbers", "csv", "txt", "md", "rtf", "png", "jpg", "jpeg", "heic", "mov", "mp4", "mp3", "m4a", "zip"]

    func directArguments(for command: DirectCommand) -> FileRequestArguments? {
        if command.verb == "open" {
            return FileQuery(spoken: command.rest).map(FileRequestArguments.init)
        }
        // A bare name with a file type ("Foundations of process mining
        // introduction.PDF") means open it; the model chose findFiles.
        let words = command.text.split(separator: " ").map(String.init)
        guard command.verb.isEmpty, let first = words.first, let last = words.last,
              !WakePhrase.commandStarts.contains(first),
              // Only a name ending in an extension ("…introduction.PDF"), not
              // sentences that mention a kind ("…bin that old spreadsheet").
              Self.extensions.contains(last), words.count <= 10,
              !FindFilesTool.prefixes.contains(where: { command.text.hasPrefix($0 + " ") }),
              let query = FileQuery(spoken: command.text), query.kind != nil, !query.words.isEmpty
        else { return nil }
        return FileRequestArguments(query)
    }
}

/// Lists the best matches in the notch without opening anything.
struct FindFilesTool: AssistantTool {
    static let limit = 6
    let name = "findFiles"
    let title = "Find files"
    let symbol = "magnifyingglass.circle"
    let keywords: Set<String> = ["find", "where", "list", "show", "files", "documents", "screenshots", "photos"]
    let description = """
        Find files on this Mac by name, type and date, never by contents, and list them. \
        "find my tax documents from last year" → name "tax", kind "document", period "lastYear".
        """
    let requiresNetwork = false
    let permission = ToolPermission.files
    let reversibility = Reversibility.notApplicable

    func target(of arguments: FileRequestArguments) -> String {
        arguments.summary
    }

    func execute(_ arguments: FileRequestArguments) async throws -> ToolResult {
        try FileAccess.ensureAccess()
        let found = try await SpotlightSearch.run(arguments.query, limit: Self.limit + 1)
        guard !found.isEmpty else { throw FileTools.notFound(arguments) }
        // One match: nothing to choose, so open it (a one-row list is just an
        // extra click). Lists are for choosing between several.
        if found.count == 1, CommandContext.isFinalStep {
            return ToolResult(try await FileTools.open(found[0]))
        }
        let shown = Array(found.prefix(Self.limit))
        let count = found.count > Self.limit ? "\(Self.limit)+" : "\(found.count)"
        return ToolResult("Found \(count) — click one to open", items: FileTokens.register(shown))
    }

    static let prefixes = ["show me the list of", "show me a list of", "show me", "list", "find", "where is", "where s", "what s on", "what s in"]

    func directArguments(for command: DirectCommand) -> FileRequestArguments? {
        guard let prefix = Self.prefixes.first(where: { command.text.hasPrefix($0 + " ") }) else { return nil }
        // Only when the rest itself sounds like files ("my…", a kind, a folder,
        // a date), so "show me the weather" or "find a restaurant" aren't.
        return FileQuery(spoken: String(command.text.dropFirst(prefix.count + 1))).map(FileRequestArguments.init)
    }
}

enum FileTools {
    /// "Desktop", or "BDM in Projects": enough to tell same-named files apart.
    static func location(of url: URL) -> String {
        let folder = url.deletingLastPathComponent()
        let parent = folder.deletingLastPathComponent().lastPathComponent
        let roots = Set(FileAccess.scopedRoots.map(\.lastPathComponent))
        return roots.contains(folder.lastPathComponent) || parent.isEmpty
            ? folder.lastPathComponent
            : "\(folder.lastPathComponent) in \(parent)"
    }

    /// Opens a found file, validating its path again at the moment of use.
    static func open(_ file: FoundFile) async throws -> String {
        try Task.checkCancellation()
        guard let url = FileAccess.validated(file.url) else { throw ToolError("That file is outside the folders I may open") }
        Log.tools.notice("openFile → \(file.name, privacy: .public)")
        _ = try await NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
        return "Opened \(file.name)"
    }

    private static let contentWords: Set<String> = ["mentions", "mentioning", "contains", "containing", "inside", "says", "saying", "about", "read"]

    /// Organising picks files by name, type and date, never by what they
    /// say ("move the file that mentions X"): that would act on files chosen
    /// by a guess at their contents. Reading them is a separate tool.
    static func refuseContentRequests() throws {
        guard let transcript = CommandContext.transcript else { return }
        let words = AppNameMatcher.normalize(transcript).split(separator: " ").map(String.init)
        if words.contains(where: contentWords.contains) {
            throw ToolError("I move and rename files by their names, types and dates, not by what's inside them")
        }
    }

    static func notFound(_ arguments: FileRequestArguments) -> ToolError {
        ToolError("No file matching “\(arguments.summary)” in Documents, Downloads or Desktop. I search names and dates, not what's inside files")
    }
}
