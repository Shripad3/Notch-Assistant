import Foundation
import Synchronization

/// An action waiting for the user's "yes": deleting an event, sending a
/// message. Parked under a token, like a batch of file changes, and dropped
/// on "no", on the next command, or when the confirmation times out.
enum PendingActions {
    static let prefix = "action_"
    private static let pending = Mutex<(token: String, run: @Sendable () async throws -> String)?>(nil)

    static func park(_ run: @escaping @Sendable () async throws -> String) -> String {
        let token = prefix + String(UUID().uuidString.prefix(8)).lowercased()
        pending.withLock { $0 = (token, run) }
        return token
    }

    static func take(_ token: String) -> (@Sendable () async throws -> String)? {
        pending.withLock { current in
            guard let parked = current, parked.token == token else { return nil }
            current = nil
            return parked.run
        }
    }

    static func discard() {
        pending.withLock { $0 = nil }
    }
}

/// Recent changes outside files that "undo" can reverse (a created or
/// moved event, a completed task), newest last, at most ten. In memory only;
/// file changes have their own journal on disk (`FileJournal`), and
/// `UndoFileChangeTool` merges the two by time.
enum RecentUndo {
    struct Entry: Sendable {
        let id = UUID()
        let date: Date
        let summary: String
        let undo: @Sendable () async throws -> String
    }

    static let depth = 10
    private static let stack = Mutex<[Entry]>([])

    static func record(_ summary: String, undo: @escaping @Sendable () async throws -> String) {
        stack.withLock { list in
            list.append(Entry(date: Date(), summary: summary, undo: undo))
            if list.count > depth { list.removeFirst(list.count - depth) }
        }
    }

    /// Newest first.
    static var entries: [Entry] { stack.withLock { $0.reversed() } }

    static var current: Entry? { stack.withLock { $0.last } }

    /// Removes and returns the newest entry.
    static func take() -> Entry? {
        stack.withLock { $0.popLast() }
    }

    /// Removes a particular entry (the one being undone).
    static func remove(_ id: UUID) -> Entry? {
        stack.withLock { list in
            guard let index = list.firstIndex(where: { $0.id == id }) else { return nil }
            return list.remove(at: index)
        }
    }

    /// Tests: the newest entry with this summary.
    static func take(summary: String) -> Entry? {
        stack.withLock { list in
            guard let index = list.lastIndex(where: { $0.summary == summary }) else { return nil }
            return list.remove(at: index)
        }
    }
}
