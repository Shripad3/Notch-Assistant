import Foundation
@testable import NotchAssistantCore
import Testing

/// Everything happens in a temporary tree with a fake Trash, never in the
/// user's folders or real Trash.
@Suite(.serialized)
final class FileOrganizerTests {
    let base: URL
    let documents: URL
    let downloads: URL
    let trashFolder: URL
    let journalFile: URL
    let organizer: FileOrganizer
    let fm = FileManager.default

    init() throws {
        base = FileManager.default.temporaryDirectory.appending(path: "notch-organizer-\(UUID().uuidString)").resolvingSymlinksInPath()
        documents = base.appending(path: "Documents")
        downloads = base.appending(path: "Downloads")
        trashFolder = base.appending(path: ".Trash")
        journalFile = base.appending(path: "journal.json")
        for dir in [documents, downloads, trashFolder, documents.appending(path: ".hidden")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let trash = trashFolder
        organizer = FileOrganizer(
            roots: [documents, downloads],
            journal: FileJournal(file: journalFile),
            trash: { url in
                let target = trash.appending(path: UUID().uuidString + "-" + url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: target)
                return target
            },
            trashFolder: trashFolder
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    @discardableResult
    private func file(_ path: String, in folder: URL? = nil, contents: String = "x") throws -> URL {
        let url = (folder ?? documents).appending(path: path)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path(percentEncoded: false)) }
    private func lastID() -> UUID { organizer.journal.lastUndoable!.id }

    // MARK: Rename

    @Test func renameKeepsExtensionAndUndoes() throws {
        let original = try file("Invoice-0823.pdf")
        let plan = try organizer.planRename(original, to: "Invoice August")
        #expect(plan.items[0].target?.lastPathComponent == "Invoice August.pdf")
        #expect(!plan.needsConfirmation)
        _ = try organizer.apply(plan)
        #expect(!exists(original))
        #expect(exists(documents.appending(path: "Invoice August.pdf")))

        try organizer.undo(lastID())
        #expect(exists(original))
        #expect(!exists(documents.appending(path: "Invoice August.pdf")))
    }

    @Test func explicitExtensionIsHonoured() throws {
        #expect(try FileOrganizer.renamed("notes.md", to: "notes.txt") == "notes.txt")
        #expect(try FileOrganizer.renamed("notes.md", to: "Meeting notes") == "Meeting notes.md")
    }

    /// Never overwrites: a taken name gets a number.
    @Test func renameNeverOverwrites() throws {
        let a = try file("a.pdf", contents: "A")
        try file("Report.pdf", contents: "existing")
        let plan = try organizer.planRename(a, to: "Report")
        #expect(plan.items[0].target?.lastPathComponent == "Report 2.pdf")
        _ = try organizer.apply(plan)
        #expect(try String(contentsOf: documents.appending(path: "Report.pdf"), encoding: .utf8) == "existing")
    }

    @Test(arguments: ["", "  ", ".hidden", "a/b", "a:b"])
    func badNamesRefused(name: String) throws {
        let a = try file("a-\(UUID().uuidString).pdf")
        #expect(throws: ToolError.self) { try organizer.planRename(a, to: name) }
    }

    // MARK: Move, copy, folders

    @Test func batchMoveIntoNewFolderAndUndo() throws {
        let shots = try (1...3).map { try file("Screenshot \($0).png", in: downloads) }
        let folder = documents.appending(path: "Receipts")
        let plan = try organizer.planTransfer(shots, copying: false, to: folder, create: true)
        #expect(plan.needsConfirmation)
        #expect(plan.summary == "Moved 3 files to Receipts")
        _ = try organizer.apply(plan)
        #expect(shots.allSatisfy { !exists($0) })
        #expect(try fm.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).count == 3)

        try organizer.undo(lastID())
        #expect(shots.allSatisfy(exists))
        #expect(!exists(folder)) // Empty again, so trashed.
    }

    @Test func copyAndUndo() throws {
        let a = try file("plan.key", in: downloads)
        _ = try organizer.apply(try organizer.planTransfer([a], copying: true, to: documents, create: false))
        #expect(exists(a))
        #expect(exists(documents.appending(path: "plan.key")))
        try organizer.undo(lastID())
        #expect(exists(a))
        #expect(!exists(documents.appending(path: "plan.key")))
    }

    @Test func moveCollisionGetsSuffix() throws {
        let a = try file("report.pdf", in: downloads, contents: "new")
        try file("report.pdf", contents: "old")
        _ = try organizer.apply(try organizer.planTransfer([a], copying: false, to: documents, create: false))
        #expect(try String(contentsOf: documents.appending(path: "report.pdf"), encoding: .utf8) == "old")
        #expect(try String(contentsOf: documents.appending(path: "report 2.pdf"), encoding: .utf8) == "new")
    }

    @Test func movingIntoSameFolderIsRefused() throws {
        let a = try file("x.pdf")
        #expect(throws: ToolError.self) { try organizer.planTransfer([a], copying: false, to: documents, create: false) }
    }

    @Test func createFolderAndUndo() throws {
        let plan = try organizer.planCreateFolder(named: "Taxes 2026", in: documents)
        _ = try organizer.apply(plan)
        #expect(exists(documents.appending(path: "Taxes 2026")))
        try organizer.undo(lastID())
        #expect(!exists(documents.appending(path: "Taxes 2026")))
    }

    // MARK: Trash

    @Test func trashIsTheOnlyRemovalAndUndoes() throws {
        let a = try file("old draft.docx")
        _ = try organizer.apply(try organizer.planTrash([a]))
        #expect(!exists(a))
        #expect(try fm.contentsOfDirectory(atPath: trashFolder.path(percentEncoded: false)).count == 1)
        try organizer.undo(lastID())
        #expect(exists(a))
    }

    // MARK: Refusals

    @Test func outsideRootsRefused() throws {
        let outside = base.appending(path: "secret.txt")
        try Data("s".utf8).write(to: outside)
        #expect(throws: ToolError.self) { try organizer.planTrash([outside]) }
        #expect(throws: ToolError.self) { try organizer.planTransfer([try file("y.pdf")], copying: false, to: base, create: false) }
    }

    @Test func hiddenAndSymlinkRefused() throws {
        let hidden = try file("h.txt", in: documents.appending(path: ".hidden"))
        #expect(throws: ToolError.self) { try organizer.planTrash([hidden]) }
        let outside = base.appending(path: "outside.txt")
        try Data("o".utf8).write(to: outside)
        let link = documents.appending(path: "link.txt")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(throws: ToolError.self) { try organizer.planTrash([link]) }
    }

    @Test func moreThanTwentyRefused() throws {
        let many = try (1...21).map { try file("f\($0).txt", in: downloads) }
        #expect(throws: ToolError.self) { try organizer.planTransfer(many, copying: false, to: documents, create: false) }
        #expect(throws: ToolError.self) { try organizer.planTrash(many) }
    }

    // MARK: Safety of the journal

    /// A failure mid-batch reverses what was already done.
    @Test func partialFailureRollsBack() throws {
        let a = try file("a.txt", in: downloads)
        let b = try file("b.txt", in: downloads)
        let plan = try organizer.planTransfer([a, b], copying: false, to: documents, create: false)
        try fm.removeItem(at: b) // Disappears between planning and applying.
        #expect(throws: ToolError.self) { try organizer.apply(plan) }
        #expect(exists(a))
        #expect(!exists(documents.appending(path: "a.txt")))
    }

    /// Undo works from the journal on disk, as after a crash and relaunch.
    @Test func undoSurvivesRestart() throws {
        let a = try file("keep.pdf")
        _ = try organizer.apply(try organizer.planRename(a, to: "renamed"))
        let reloaded = FileOrganizer(roots: organizer.roots, journal: FileJournal(file: journalFile), trash: organizer.trash, trashFolder: trashFolder)
        try reloaded.undo(reloaded.journal.lastUndoable!.id)
        #expect(exists(a))
    }

    /// A step whose files changed since is left alone, not forced.
    @Test func undoLeavesChangedFilesAlone() throws {
        let a = try file("x.txt")
        _ = try organizer.apply(try organizer.planRename(a, to: "y"))
        try file("x.txt", contents: "someone recreated it")
        let message = try organizer.undo(lastID())
        #expect(message.contains("left alone"))
        #expect(exists(documents.appending(path: "y.txt")))
    }
}
