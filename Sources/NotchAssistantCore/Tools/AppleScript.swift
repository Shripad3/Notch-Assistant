import AppKit
import Synchronization

/// Runs AppleScript against another app (Spotify, System Events). This is
/// Apple Events, not a shell: the scripts are fixed strings built here, with
/// only escaped values interpolated, never text from the model.
enum AppleScript {
    /// One serial queue for every script. Never the main thread: an Apple
    /// Event blocks until the target answers, which can be seconds while an
    /// app launches, or indefinitely while macOS's "allow control?" prompt
    /// waits for the user. On the main thread that froze the whole app.
    private static let queue = DispatchQueue(label: "dev.shripad.NotchAssistant.applescript")

    static func run(_ source: String, controlling appName: String) async throws {
        _ = try await evaluate(source, controlling: appName)
    }

    /// Runs a script and returns its result as strings: one for a text
    /// result, each item for a list.
    static func evaluate(_ source: String, controlling appName: String) async throws -> [String] {
        // Bound each event, so an unresponsive app fails instead of hanging.
        let bounded = "with timeout of 10 seconds\n\(source)\nend timeout"
        let (code, values): (Int?, [String]) = await withCheckedContinuation { continuation in
            queue.async {
                var error: NSDictionary?
                let script = NSAppleScript(source: bounded)
                let result = script?.executeAndReturnError(&error)
                if let error {
                    Log.tools.error("AppleScript for \(appName, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
                var values: [String] = []
                if let result, result.numberOfItems > 0 {
                    values = (1...result.numberOfItems).compactMap { result.atIndex($0)?.stringValue }
                } else if let text = result?.stringValue {
                    values = [text]
                }
                continuation.resume(returning: (script == nil ? -1 : error.map { $0[NSAppleScript.errorNumber] as? Int ?? 0 }, values))
            }
        }
        switch code {
        case nil:
            return values
        case -1743:
            throw AssistantFailure("Notch Assistant isn't allowed to control \(appName)", link: .automation)
        case -1712:
            throw ToolError("\(appName) didn't respond in time")
        case -600, -609:
            throw ToolError("\(appName) isn't responding")
        default:
            throw ToolError("\(appName) didn't accept the command")
        }
    }

    /// Escapes a value for use inside an AppleScript string literal.
    static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Whether this app may send Apple Events to another, checked without
/// prompting (spec §10 live permission status).
public enum AutomationStatus: Sendable, Equatable {
    case granted, denied, notRequested
    /// macOS can only answer while the target app is running.
    case targetNotRunning
    /// The check didn't answer within its time limit.
    case unknown

    private static let pending = Mutex<Set<String>>([])

    /// Never blocks the caller. AEDeterminePermissionToAutomateTarget can
    /// block indefinitely (seen with System Events not running, which froze
    /// the app when called on the main thread), so it runs on a background
    /// thread, only while the target runs, at most once at a time per target,
    /// and the answer is abandoned after two seconds.
    public static func check(bundleIdentifier: String) async -> AutomationStatus {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty else {
            return .targetNotRunning
        }
        guard pending.withLock({ $0.insert(bundleIdentifier).inserted }) else { return .unknown }
        let answer = OneShot<AutomationStatus>()
        return await withCheckedContinuation { continuation in
            answer.set(continuation)
            DispatchQueue.global(qos: .utility).async {
                let status = blockingCheck(bundleIdentifier)
                pending.withLock { _ = $0.remove(bundleIdentifier) }
                answer.resume(status)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { answer.resume(.unknown) }
        }
    }

    private static func blockingCheck(_ bundleIdentifier: String) -> AutomationStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        guard let desc = target.aeDesc else { return .notRequested }
        switch AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false) {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound): return .targetNotRunning
        default: return .notRequested
        }
    }
}

/// Resumes a continuation exactly once, whichever caller gets there first.
final class OneShot<Value: Sendable>: Sendable {
    private let continuation = Mutex<CheckedContinuation<Value, Never>?>(nil)

    func set(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation.withLock { $0 = continuation }
    }

    func resume(_ value: Value) {
        continuation.withLock { $0.take()?.resume(returning: value) }
    }
}
