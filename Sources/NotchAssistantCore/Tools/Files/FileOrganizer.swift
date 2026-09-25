import Foundation

public enum FileOperation: String, Sendable, CaseIterable {
    case rename, move, copy, trash, createFolder
}

/// A checked, not-yet-applied change. Everything that could be refused has
/// been refused by the time one of these exists (spec §9 "Validation belongs
/// in the executor"): paths are canonical and inside the scoped roots, no
/// target exists (names are auto-suffixed instead), moves stay on one volume,
/// and there are at most 20 items.
struct FileChangePlan: Sendable, Equatable {
    struct Item: Sendable, Equatable {
        let source: URL
        /// Nil for trash.
        let target: URL?
    }

    let operation: FileOperation
    let summary: String
    let items: [Item]
    /// A destination folder to create first ("…into a folder called Receipts").
    let createFolder: URL?

    /// One item happens at once; a batch is shown for one confirmation.
    var needsConfirmation: Bool { items.count > 1 }
}

/// Plans, applies and undoes file changes. The agent never reads or edits a
/// file's contents and never deletes permanently: the only removal is the
/// Trash, and nothing here can empty it (spec §9).
struct FileOrganizer: Sendable {
    static let maxBatch = 20

    let roots: [URL]
    let journal: FileJournal
    /// Moves an item to the Trash and returns where it went. Injectable so
    /// tests never touch the real Trash.
    let trash: @Sendable (URL) throws -> URL
    /// Where trashed items may be restored from.
    let trashFolder: URL

    static let live = FileOrganizer(
        roots: FileAccess.scopedRoots,
        journal: .shared,
        trash: { url in
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            guard let result else { throw ToolError("macOS didn't say where \(url.lastPathComponent) went in the Trash") }
            return result as URL
        },
        trashFolder: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash")
    )

    // MARK: Planning

    func planRename(_ file: URL, to spokenName: String) throws -> FileChangePlan {
        let source = try checkedSource(file)
        let name = try Self.renamed(source.lastPathComponent, to: spokenName)
        guard name != source.lastPathComponent else { throw ToolError("It's already called \(name)") }
        let target = uniqueTarget(in: source.deletingLastPathComponent(), named: name, reserved: [])
        return FileChangePlan(
            operation: .rename,
            summary: "Renamed \(source.lastPathComponent) to \(target.lastPathComponent)",
            items: [.init(source: source, target: target)],
            createFolder: nil
        )
    }

    /// `destination` is a folder that exists, or will be created when
    /// `create` is true.
    func planTransfer(_ files: [URL], copying: Bool, to destination: URL, create: Bool) throws -> FileChangePlan {
        guard !files.isEmpty else { throw ToolError("There are no files to \(copying ? "copy" : "move")") }
        guard files.count <= Self.maxBatch else { throw Self.tooMany(files.count) }
        let folder = try checkedFolder(destination, mustExist: !create)
        var items: [FileChangePlan.Item] = []
        var reserved = Set<String>()
        for file in files {
            let source = try checkedSource(file)
            if !copying {
                guard source.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL else {
                    throw ToolError("\(source.lastPathComponent) is already in \(folder.lastPathComponent)")
                }
                guard !folder.path(percentEncoded: false).hasPrefix(source.path(percentEncoded: false) + "/") else {
                    throw ToolError("Can't move \(source.lastPathComponent) into itself")
                }
                // Moves between volumes are copies and deletes: not reversible (spec §9).
                guard Self.volume(of: source) == Self.volume(of: create ? folder.deletingLastPathComponent() : folder) else {
                    throw ToolError("\(source.lastPathComponent) is on a different disk; I only move files within one disk")
                }
            }
            let target = uniqueTarget(in: folder, named: source.lastPathComponent, reserved: reserved)
            reserved.insert(target.lastPathComponent)
            items.append(.init(source: source, target: target))
        }
        let what = items.count == 1 ? items[0].source.lastPathComponent : "\(items.count) files"
        return FileChangePlan(
            operation: copying ? .copy : .move,
            summary: "\(copying ? "Copied" : "Moved") \(what) to \(folder.lastPathComponent)",
            items: items,
            createFolder: create ? folder : nil
        )
    }

    func planTrash(_ files: [URL]) throws -> FileChangePlan {
        guard !files.isEmpty else { throw ToolError("There are no files to move to the Trash") }
        guard files.count <= Self.maxBatch else { throw Self.tooMany(files.count) }
        let items = try files.map { FileChangePlan.Item(source: try checkedSource($0), target: nil) }
        let what = items.count == 1 ? items[0].source.lastPathComponent : "\(items.count) files"
        return FileChangePlan(operation: .trash, summary: "Moved \(what) to the Trash", items: items, createFolder: nil)
    }

    func planCreateFolder(named spokenName: String, in parent: URL) throws -> FileChangePlan {
        let folder = try checkedFolder(parent, mustExist: true)
        let name = try Self.cleanName(spokenName)
        let target = uniqueTarget(in: folder, named: name, reserved: [])
        return FileChangePlan(
            operation: .createFolder,
            summary: "Created the folder \(target.lastPathComponent) in \(folder.lastPathComponent)",
            items: [],
            createFolder: target
        )
    }

    // MARK: Applying

    /// Journals each step before making it. On failure, reverses the steps
    /// already made, so a change is all or nothing.
    func apply(_ plan: FileChangePlan) throws -> String {
        let id = try journal.begin(plan.summary)
        let fm = FileManager.default
        do {
            if let folder = plan.createFolder {
                try journal.record(.createFolder(folder), in: id)
                try fm.createDirectory(at: folder, withIntermediateDirectories: false)
            }
            for item in plan.items {
                switch (plan.operation, item.target) {
                case (.rename, let target?), (.move, let target?):
                    try journal.record(.move(from: item.source, to: target), in: id)
                    try fm.moveItem(at: item.source, to: target)
                case (.copy, let target?):
                    try journal.record(.copy(created: target), in: id)
                    try fm.copyItem(at: item.source, to: target)
                case (.trash, _):
                    // Recorded first with a placeholder, then with where it went.
                    try journal.record(.trash(original: item.source, inTrash: item.source), in: id)
                    let trashed = try trash(item.source)
                    try journal.amendLast(.trash(original: item.source, inTrash: trashed), in: id)
                default:
                    break
                }
            }
            try journal.setStatus(.done, for: id)
            Log.tools.notice("files: \(plan.summary, privacy: .public)")
            return plan.summary
        } catch {
            _ = try? undo(id)
            throw ToolError("Couldn't finish (\(error.localizedDescription)). Nothing was changed")
        }
    }

    /// Reverses an entry, newest step first. A step whose files have changed
    /// since is left alone rather than forced.
    @discardableResult
    func undo(_ id: UUID) throws -> String {
        guard let entry = journal.entry(id) else { throw ToolError("There's nothing to undo") }
        guard entry.status != .undone else { throw ToolError("That was already undone") }
        let fm = FileManager.default
        var skipped = 0
        for step in entry.steps.reversed() {
            switch step {
            case .move(let from, let to):
                guard allowed(from), allowed(to), fm.fileExists(atPath: to.path(percentEncoded: false)),
                      !fm.fileExists(atPath: from.path(percentEncoded: false)) else { skipped += 1; continue }
                try fm.moveItem(at: to, to: from)
            case .copy(let created):
                guard allowed(created), fm.fileExists(atPath: created.path(percentEncoded: false)) else { skipped += 1; continue }
                _ = try trash(created)
            case .trash(let original, let inTrash):
                guard allowed(original), inTrash != original, isInTrash(inTrash),
                      fm.fileExists(atPath: inTrash.path(percentEncoded: false)),
                      !fm.fileExists(atPath: original.path(percentEncoded: false)) else { skipped += 1; continue }
                try fm.moveItem(at: inTrash, to: original)
            case .createFolder(let folder):
                let contents = (try? fm.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
                guard allowed(folder), contents.allSatisfy({ $0 == ".DS_Store" }),
                      fm.fileExists(atPath: folder.path(percentEncoded: false)) else { skipped += 1; continue }
                _ = try trash(folder)
            }
        }
        try journal.setStatus(.undone, for: id)
        let note = skipped > 0 ? " (\(skipped) item\(skipped == 1 ? " had" : "s had") changed since and \(skipped == 1 ? "was" : "were") left alone)" : ""
        return "Undid: \(entry.summary)\(note)"
    }

    // MARK: Checks

    private func checkedSource(_ url: URL) throws -> URL {
        guard let source = FileAccess.validated(url, roots: roots) else {
            throw ToolError("\(url.lastPathComponent) is outside the folders I may change")
        }
        guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else {
            throw ToolError("\(source.lastPathComponent) no longer exists")
        }
        // An iCloud file that isn't downloaded can't be moved back reliably.
        if let values = try? source.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
           values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current {
            throw ToolError("\(source.lastPathComponent) is in iCloud but not downloaded; open it once first")
        }
        return source
    }

    /// A folder inside the roots, or a root itself.
    private func checkedFolder(_ url: URL, mustExist: Bool) throws -> URL {
        let folder = url.standardizedFileURL.resolvingSymlinksInPath()
        let isRoot = roots.contains { $0.standardizedFileURL == folder }
        guard isRoot || FileAccess.validated(folder, roots: roots) != nil else {
            throw ToolError("\(folder.lastPathComponent) is outside the folders I may change")
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: folder.path(percentEncoded: false), isDirectory: &isDirectory)
        if mustExist, !(exists && isDirectory.boolValue) { throw ToolError("There's no folder called \(folder.lastPathComponent)") }
        if !mustExist, exists { throw ToolError("\(folder.lastPathComponent) already exists") }
        return folder
    }

    /// Whether undo may touch this path. It often doesn't exist yet (it is
    /// where a file is being put back), and a missing path resolves
    /// differently, so the check is on its parent folder plus the name.
    private func allowed(_ url: URL) -> Bool {
        if isInTrash(url) { return true }
        let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let parentAllowed = roots.contains { $0.standardizedFileURL.resolvingSymlinksInPath() == parent }
            || FileAccess.validated(parent, roots: roots) != nil
        return parentAllowed && !url.lastPathComponent.hasPrefix(".") && !url.lastPathComponent.hasSuffix(".app")
    }

    private func isInTrash(_ url: URL) -> Bool {
        let trash = trashFolder.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        return parent == trash || parent.hasPrefix(trash + "/")
    }

    /// Never overwrites: a taken name gets " 2", " 3", … before its extension.
    func uniqueTarget(in folder: URL, named name: String, reserved: Set<String>) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = name
        var number = 2
        while reserved.contains(candidate) || FileManager.default.fileExists(atPath: folder.appending(path: candidate).path(percentEncoded: false)) {
            candidate = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            number += 1
        }
        return folder.appending(path: candidate)
    }

    private static func volume(of url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }

    private static func tooMany(_ count: Int) -> ToolError {
        ToolError("That's \(count) files; I change at most \(maxBatch) at a time. Narrow it down")
    }

    // MARK: Names (pure)

    /// The extension is kept unless the new name gives one ("report.txt").
    static func renamed(_ current: String, to spoken: String) throws -> String {
        let name = try cleanName(spoken)
        let currentExt = (current as NSString).pathExtension
        let spokenExt = (name as NSString).pathExtension
        let explicit = !spokenExt.isEmpty && spokenExt.count <= 5 && spokenExt.allSatisfy { $0.isLetter || $0.isNumber }
        return explicit || currentExt.isEmpty ? name : "\(name).\(currentExt)"
    }

    static func cleanName(_ spoken: String) throws -> String {
        let name = spoken.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”'")))
        guard !name.isEmpty, name.count <= 200, !name.hasPrefix("."),
              !name.contains("/"), !name.contains(":")
        else { throw ToolError("“\(spoken)” isn't a name I can use") }
        return name
    }
}
