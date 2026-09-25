import Foundation
import Synchronization

/// Batches of file changes waiting for the user's yes (spec §9: "Batch of
/// 2–20 files: shows the list, one confirmation"). A plan is parked here
/// under a token until confirmed, cancelled, or replaced by the next one.
enum PendingChanges {
    private static let pending = Mutex<(token: String, plan: FileChangePlan)?>(nil)

    static func park(_ plan: FileChangePlan) -> String {
        let token = "change_" + String(UUID().uuidString.prefix(8)).lowercased()
        pending.withLock { $0 = (token, plan) }
        return token
    }

    static func take(_ token: String) -> FileChangePlan? {
        pending.withLock { current in
            guard let parked = current, parked.token == token else { return nil }
            current = nil
            return parked.plan
        }
    }

    static func discard() {
        pending.withLock { $0 = nil }
    }
}

/// What the notch's Confirm button and a spoken "yes" do.
public enum Confirmations {
    public static let yesWords: Set<String> = ["yes", "yeah", "yep", "sure", "confirm", "do it", "go ahead", "ok", "okay", "yes please"]
    public static let noWords: Set<String> = ["no", "nope", "cancel", "don t", "stop", "never mind", "no thanks"]

    /// True for yes, false for no, nil when it's neither (a new command).
    public static func answer(in transcript: String) -> Bool? {
        let text = AppNameMatcher.normalize(transcript)
        if yesWords.contains(text) { return true }
        if noWords.contains(text) { return false }
        return nil
    }

    public static func confirm(_ token: String) async throws -> String {
        guard let plan = PendingChanges.take(token) else { throw ToolError("That change has expired; ask again") }
        return try FileOrganizer.live.apply(plan) + " · say “undo” to reverse"
    }

    public static func discard() {
        PendingChanges.discard()
    }
}
