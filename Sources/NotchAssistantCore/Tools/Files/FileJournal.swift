import Foundation
import Synchronization

/// The undo journal (spec §9 "Reversibility instead of confirmation").
/// Every change is written here, with how to reverse it, *before* it is made,
/// and the file is on disk rather than in memory, so undo survives a crash.
public final class FileJournal: Sendable {
    public struct Entry: Codable, Sendable, Identifiable, Equatable {
        public enum Status: String, Codable, Sendable {
            /// Written before acting. If the app died mid-change, the steps
            /// that did happen are still undoable (each step checks).
            case pending
            case done
            case undone
        }

        public let id: UUID
        public let date: Date
        public let summary: String
        public var steps: [Step]
        public var status: Status
    }

    /// One change and everything needed to reverse it.
    public enum Step: Codable, Sendable, Equatable {
        /// Rename or move: reversed by moving back.
        case move(from: URL, to: URL)
        /// Reversed by trashing the copy.
        case copy(created: URL)
        /// Reversed by moving the item back out of the Trash.
        case trash(original: URL, inTrash: URL)
        /// Reversed by trashing the folder, only if it is still empty.
        case createFolder(URL)
    }

    public static let shared = FileJournal(file: URL.applicationSupportDirectory.appending(path: "NotchAssistant/file-journal.json"))
    static let keep = 200

    private let file: URL
    private let entries: Mutex<[Entry]>

    init(file: URL) {
        self.file = file
        let loaded = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        entries = Mutex(loaded)
    }

    /// Newest first.
    public var history: [Entry] {
        entries.withLock { $0.reversed() }
    }

    /// Records an intended change before it is made.
    func begin(_ summary: String) throws -> UUID {
        let entry = Entry(id: UUID(), date: Date(), summary: summary, steps: [], status: .pending)
        try update { $0.append(entry) }
        return entry.id
    }

    /// Records one step *before* performing it.
    func record(_ step: Step, in id: UUID) throws {
        try update { entries in
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[index].steps.append(step)
        }
    }

    /// Replaces the last step (a trash's final location is only known after).
    func amendLast(_ step: Step, in id: UUID) throws {
        try update { entries in
            guard let index = entries.firstIndex(where: { $0.id == id }), !entries[index].steps.isEmpty else { return }
            entries[index].steps[entries[index].steps.count - 1] = step
        }
    }

    func setStatus(_ status: Entry.Status, for id: UUID) throws {
        try update { entries in
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[index].status = status
        }
    }

    /// The most recent entry that can still be undone.
    public var lastUndoable: Entry? {
        entries.withLock { $0.last { $0.status != .undone && !$0.steps.isEmpty } }
    }

    public func entry(_ id: UUID) -> Entry? {
        entries.withLock { $0.first { $0.id == id } }
    }

    private func update(_ change: (inout [Entry]) -> Void) throws {
        let snapshot = entries.withLock { entries -> [Entry] in
            change(&entries)
            if entries.count > Self.keep { entries.removeFirst(entries.count - Self.keep) }
            return entries
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Atomic: a crash mid-write can't leave half a journal.
        try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
    }
}
