import Foundation
import FoundationModels

@Generable
struct OrganiseFilesArguments: Sendable {
    @Guide(description: "What to do", .anyOf(["rename", "move", "copy", "trash", "createFolder"]))
    var operation: String
    @Guide(description: "Words from the name of the file(s) to change. Empty for createFolder")
    var name: String
    @Guide(description: "File type if said: document, pdf, image, screenshot, video, audio, spreadsheet, presentation or folder")
    var kind: String?
    @Guide(description: "When they're from, if said: today, yesterday, thisWeek, lastWeek, thisMonth, lastMonth, thisYear or lastYear")
    var period: String?
    @Guide(description: "Folder the files are in, if said: Desktop, Documents or Downloads")
    var folder: String?
    @Guide(description: "New name for rename, or the new folder's name for createFolder")
    var newName: String?
    @Guide(description: "Folder to move or copy into: Desktop, Documents, Downloads, or a folder name")
    var destination: String?

    var files: FileRequestArguments {
        FileRequestArguments(name: name, kind: kind, period: period, folder: folder)
    }
}

/// Rename, move, copy, trash and create folders (spec §9 organiseFiles,
/// reversible). One file changes at once; a batch waits for one yes. Every
/// change goes through the journal, so "undo" reverses it. "Delete" means
/// the Trash: nothing here deletes permanently or empties the Trash.
struct OrganiseFilesTool: AssistantTool {
    let name = "organiseFiles"
    let title = "Files"
    let symbol = "folder"
    let keywords: Set<String> = ["rename", "move", "copy", "trash", "delete", "remove", "bin", "folder", "tidy", "organise", "organize", "name"]

    /// The operation must have been said, as must a new name or destination.
    /// Given "put on something to listen to", the model chose rename
    /// "something" to "something else".
    static let operationWords: [String: Set<String>] = [
        "rename": ["rename", "name", "call", "called", "retitle"],
        "move": ["move", "put", "tidy", "organise", "organize", "file", "into", "sort"],
        "copy": ["copy", "duplicate"],
        "trash": ["trash", "delete", "remove", "bin", "throw", "rid", "erase"],
        "createFolder": ["folder"],
    ]

    static func isGrounded(_ arguments: OrganiseFilesArguments, in transcript: String) -> Bool {
        let words = Set(AppNameMatcher.normalize(transcript).split(separator: " ").map(String.init))
        guard let needed = operationWords[arguments.operation], !needed.isDisjoint(with: words) else { return false }
        for value in [arguments.newName, arguments.destination].compactMap({ $0 }) where !value.isEmpty {
            guard Grounding.mentions(value, in: transcript) || words.contains(AppNameMatcher.normalize(value)) else { return false }
        }
        return true
    }
    let description = """
        Rename, move, copy or trash files, or create a folder. Deleting means moving to the Trash. \
        "rename my invoice from last month to Invoice August" → operation "rename", name "invoice", period "lastMonth", newName "Invoice August". \
        "move my screenshots from today to Receipts" → operation "move", kind "screenshot", period "today", destination "Receipts".
        """
    let requiresNetwork = false
    let permission = ToolPermission.files
    let reversibility = Reversibility.reversible

    func target(of arguments: OrganiseFilesArguments) -> String {
        [arguments.files.summary, arguments.newName.map { "→ \($0)" }, arguments.destination.map { "→ \($0)" }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    func execute(_ arguments: OrganiseFilesArguments) async throws -> ToolResult {
        try FileTools.refuseContentRequests()
        try FileAccess.ensureAccess()
        guard let operation = FileOperation(rawValue: arguments.operation) else {
            throw ToolError("I can't do “\(arguments.operation)” to files")
        }
        if let transcript = CommandContext.transcript, !Self.isGrounded(arguments, in: transcript) {
            Log.tools.notice("organiseFiles: \(arguments.operation, privacy: .public) not grounded in \"\(transcript, privacy: .public)\"")
            throw ToolError("I didn't catch what to do with which files")
        }
        let organizer = FileOrganizer.live

        if operation == .createFolder {
            guard let folderName = arguments.newName ?? arguments.destination else { throw ToolError("What should the folder be called?") }
            let parent = FileDestination.root(named: arguments.folder) ?? FileDestination.defaultParent
            return try result(of: organizer.planCreateFolder(named: folderName, in: parent), organizer)
        }

        let found = try await SpotlightSearch.run(arguments.files.query, limit: FileOrganizer.maxBatch + 1)
        guard !found.isEmpty else { throw FileTools.notFound(arguments.files) }

        switch operation {
        case .rename:
            guard let newName = arguments.newName else { throw ToolError("What should it be renamed to?") }
            // Rename acts on exactly one file: the only match, or an exact name.
            let exact = found.filter { FileRanking.nameScore($0.name, arguments.files.query.words) == 3 }
            guard found.count == 1 || exact.count == 1 else {
                let names = found.prefix(3).map(\.name).joined(separator: ", ")
                throw ToolError("Which one? I found \(found.count > 20 ? "20+" : "\(found.count)"): \(names). Say more of the name")
            }
            return try result(of: organizer.planRename((found.count == 1 ? found[0] : exact[0]).url, to: newName), organizer)
        case .move, .copy:
            guard let destination = arguments.destination else { throw ToolError("Where to?") }
            let sources = found.map(\.url)
            let (folder, create) = try await FileDestination.resolve(destination, near: sources)
            return try result(of: organizer.planTransfer(sources, copying: operation == .copy, to: folder, create: create), organizer)
        case .trash:
            return try result(of: organizer.planTrash(found.map(\.url)), organizer)
        case .createFolder:
            fatalError("handled above")
        }
    }

    /// One change happens now; a batch is parked for the user's yes.
    private func result(of plan: FileChangePlan, _ organizer: FileOrganizer) throws -> ToolResult {
        guard plan.needsConfirmation else {
            return ToolResult(try organizer.apply(plan) + " · say “undo” to reverse", undoable: true)
        }
        let rows = plan.items.map { item in
            ResultItem(
                id: "row_" + UUID().uuidString,
                title: item.source.lastPathComponent,
                detail: item.target.map { "→ \($0.deletingLastPathComponent().lastPathComponent)" } ?? "→ Trash",
                symbol: "doc"
            )
        }
        let question = plan.summary
            .replacingOccurrences(of: "Moved", with: "Move")
            .replacingOccurrences(of: "Copied", with: "Copy") + "?"
        return ToolResult(question, items: rows, confirmation: PendingChanges.park(plan))
    }

    // MARK: Direct phrasings

    func directArguments(for command: DirectCommand) -> OrganiseFilesArguments? {
        let text = command.text
        func files(_ description: String) -> FileQuery? {
            FileQuery(spoken: description)
        }
        func arguments(_ operation: String, _ query: FileQuery, newName: String? = nil, destination: String? = nil) -> OrganiseFilesArguments {
            OrganiseFilesArguments(
                operation: operation, name: query.words.joined(separator: " "), kind: query.kind?.rawValue,
                period: query.period?.rawValue, folder: query.folder, newName: newName, destination: destination
            )
        }

        // "create a folder called Taxes (on my desktop)"
        for prefix in ["create a new folder called ", "create a folder called ", "make a new folder called ", "make a folder called ",
                       "create a folder named ", "make a folder named ", "new folder called ", "new folder named "]
        where text.hasPrefix(prefix) {
            var rest = String(text.dropFirst(prefix.count))
            var parent: String?
            for (phrase, root) in FileQuery.folders {
                for preposition in [" on my ", " in my ", " on the ", " in the ", " in ", " on "] where rest.hasSuffix(preposition + phrase) {
                    rest.removeLast((preposition + phrase).count)
                    parent = root
                }
            }
            guard !rest.isEmpty else { return nil }
            return OrganiseFilesArguments(operation: "createFolder", name: "", kind: nil, period: nil, folder: parent, newName: rest, destination: nil)
        }

        // "rename my invoice from last month to invoice august"
        if text.hasPrefix("rename "), let split = text.range(of: " to ", options: .backwards) {
            let description = String(text[text.index(text.startIndex, offsetBy: 7)..<split.lowerBound])
            let newName = String(text[split.upperBound...])
            let query = files(description) ?? FileQuery(text: description, kind: nil, period: nil)
            guard !query.words.isEmpty || query.kind != nil, !newName.isEmpty else { return nil }
            return arguments("rename", query, newName: newName)
        }

        // "trash / delete / remove my …", "move my … to the trash"
        for prefix in ["move to the trash ", "throw away ", "get rid of ", "trash ", "delete ", "remove ", "bin "] where text.hasPrefix(prefix) {
            guard let query = files(String(text.dropFirst(prefix.count))) else { return nil }
            return arguments("trash", query)
        }
        for suffix in [" to the trash", " to trash", " to the bin", " in the trash", " in the bin"] where text.hasSuffix(suffix) {
            for prefix in ["move ", "put ", "send "] where text.hasPrefix(prefix) {
                let description = String(text.dropFirst(prefix.count).dropLast(suffix.count))
                guard let query = files(description) else { return nil }
                return arguments("trash", query)
            }
        }

        // "move / put / copy my … to|into <folder>"
        for (prefix, operation) in [("move ", "move"), ("put ", "move"), ("copy ", "copy")] where text.hasPrefix(prefix) {
            let rest = String(text.dropFirst(prefix.count))
            guard let split = [" into ", " to ", " in "].compactMap({ rest.range(of: $0, options: .backwards) }).max(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
            let description = String(rest[..<split.lowerBound])
            let destination = FileDestination.clean(String(rest[split.upperBound...]))
            guard let query = files(description), !destination.isEmpty else { return nil }
            return arguments(operation, query, destination: destination)
        }
        return nil
    }
}

/// "Undo that": reverses the most recent file change from the journal.
struct UndoFileChangeTool: AssistantTool {
    let name = "undoFileChange"
    let title = "Undo"
    let symbol = "arrow.uturn.backward"
    let keywords: Set<String> = ["undo", "revert", "back"]
    let description = """
        Undo the last file change (a rename, move, copy, trash or new folder). "undo that" → undo.
        """
    let requiresNetwork = false
    let permission = ToolPermission.files
    let reversibility = Reversibility.notApplicable

    @Generable
    struct Arguments: Sendable {
        @Guide(description: "Always \"last\"")
        var which: String
    }

    func target(of arguments: Arguments) -> String {
        FileJournal.shared.lastUndoable?.summary ?? "Last change"
    }

    func execute(_ arguments: Arguments) async throws -> ToolResult {
        guard let last = FileJournal.shared.lastUndoable else { throw ToolError("There's nothing to undo") }
        return ToolResult(try FileOrganizer.live.undo(last.id))
    }

    func directArguments(for command: DirectCommand) -> Arguments? {
        ["undo", "undo that", "undo it", "undo the last change", "undo last change", "undo the last one", "revert that", "put it back"]
            .contains(command.text) ? Arguments(which: "last") : nil
    }
}

/// Where "…to Receipts" means: a scoped root by name, an existing folder
/// with that name, or a new folder beside the files (or in Documents).
enum FileDestination {
    static var defaultParent: URL {
        FileAccess.scopedRoots.first { $0.lastPathComponent == "Documents" } ?? FileAccess.scopedRoots[0]
    }

    static func root(named spoken: String?) -> URL? {
        guard let spoken else { return nil }
        let key = FileQuery.folders[AppNameMatcher.normalize(spoken)] ?? spoken
        return FileAccess.scopedRoots.first { $0.lastPathComponent.lowercased() == key.lowercased() }
    }

    /// "a folder called receipts" → "receipts".
    static func clean(_ spoken: String) -> String {
        var text = AppNameMatcher.normalize(spoken)
        for filler in ["a new folder called ", "a folder called ", "a new folder named ", "a folder named ", "the folder called ",
                       "the folder named ", "the folder ", "folder called ", "folder named ", "my ", "the "]
        where text.hasPrefix(filler) {
            text.removeFirst(filler.count)
        }
        if text.hasSuffix(" folder") { text.removeLast(" folder".count) }
        return text
    }

    /// (folder, needs creating).
    static func resolve(_ spoken: String, near sources: [URL]) async throws -> (URL, Bool) {
        let name = clean(spoken)
        if let root = root(named: name) { return (root, false) }
        let existing = try await SpotlightSearch.run(FileQuery(text: name, kind: .folder, period: nil), limit: 10)
            .filter { AppNameMatcher.key($0.name) == AppNameMatcher.key(name) }
        if let folder = existing.first { return (folder.url, false) }
        // New: beside the files if they share a folder, else in Documents.
        let parents = Set(sources.map { $0.deletingLastPathComponent().standardizedFileURL })
        let parent = parents.count == 1 ? parents.first! : defaultParent
        return (parent.appending(path: try FileOrganizer.cleanName(name.capitalized(with: nil)), directoryHint: .isDirectory), true)
    }
}

/// The Files pane: history and undo, without exposing the organizer.
public enum FileChanges {
    public static var history: [FileJournal.Entry] { FileJournal.shared.history }

    public static func undo(_ id: UUID) throws -> String {
        try FileOrganizer.live.undo(id)
    }
}
