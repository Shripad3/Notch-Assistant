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

/// The last change outside files that "undo that" can reverse (a created or
/// moved event). Kept for ten minutes, in memory only; file changes have
/// their own journal on disk.
enum RecentUndo {
    struct Entry: Sendable {
        let date: Date
        let summary: String
        let undo: @Sendable () async throws -> String
    }

    static let lifetime: TimeInterval = 600
    private static let last = Mutex<Entry?>(nil)

    static func record(_ summary: String, undo: @escaping @Sendable () async throws -> String) {
        last.withLock { $0 = Entry(date: Date(), summary: summary, undo: undo) }
    }

    /// The entry if still fresh, without removing it.
    static var current: Entry? {
        last.withLock { entry in
            guard let entry, Date().timeIntervalSince(entry.date) < lifetime else { return nil }
            return entry
        }
    }

    static func take() -> Entry? {
        last.withLock { entry in
            defer { entry = nil }
            guard let found = entry, Date().timeIntervalSince(found.date) < lifetime else { return nil }
            return found
        }
    }
}
