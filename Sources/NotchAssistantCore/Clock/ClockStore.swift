import Foundation
import Synchronization

/// A timer or an alarm: something that rings at a moment.
public struct Countdown: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable { case timer, alarm }

    public let id: UUID
    public let kind: Kind
    public var label: String?
    /// When it rings, while running.
    public var fireDate: Date
    /// A timer's length as set (plus any time added).
    public var duration: TimeInterval
    /// Set while a timer is paused: the time it had left.
    public var pausedRemaining: TimeInterval?

    public var isPaused: Bool { pausedRemaining != nil }

    public func remaining(at now: Date = Date()) -> TimeInterval {
        pausedRemaining ?? max(0, fireDate.timeIntervalSince(now))
    }

    /// "pasta timer", "10 minute timer", "7:00 AM alarm", "gym alarm".
    public var name: String {
        switch kind {
        case .timer: (label ?? ClockFormat.adjective(duration)) + " timer"
        case .alarm: label.map { "\($0) alarm" } ?? "\(fireDate.formatted(date: .omitted, time: .shortened)) alarm"
        }
    }
}

public struct Stopwatch: Codable, Sendable, Equatable {
    /// Set while running.
    public var startedAt: Date?
    /// Time counted before the current run.
    public var accumulated: TimeInterval = 0
    /// Each lap's length.
    public var laps: [TimeInterval] = []

    public var isRunning: Bool { startedAt != nil }
    /// Stopped at zero: nothing to show.
    public var isIdle: Bool { startedAt == nil && accumulated == 0 }

    public func elapsed(at now: Date = Date()) -> TimeInterval {
        accumulated + (startedAt.map { now.timeIntervalSince($0) } ?? 0)
    }
}

/// A timer or alarm going off, shown in the notch until stopped.
public struct ClockAlert: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let kind: Countdown.Kind
    public let label: String?
    public let title: String
    /// Said aloud: "Your pasta timer is done."
    public let message: String

    public var canSnooze: Bool { kind == .alarm }

    /// For the debug notch preview.
    public static func preview(_ kind: Countdown.Kind) -> ClockAlert {
        ClockAlert(Countdown(id: UUID(), kind: kind, label: kind == .alarm ? "gym" : "pasta", fireDate: Date(), duration: 600))
    }

    init(_ countdown: Countdown) {
        id = countdown.id
        kind = countdown.kind
        label = countdown.label
        switch countdown.kind {
        case .timer:
            title = "Timer done"
            message = "Time's up. Your \(countdown.name) is done."
        case .alarm:
            let time = countdown.fireDate.formatted(date: .omitted, time: .shortened)
            title = countdown.label.map { "Alarm: \($0)" } ?? "Alarm"
            message = countdown.label.map { "It's \(time). \($0.prefix(1).uppercased() + $0.dropFirst())." } ?? "It's \(time)."
        }
    }
}

/// Everything the menu bar shows.
public struct ClockSnapshot: Sendable, Equatable {
    public var countdowns: [Countdown] = []
    public var stopwatch = Stopwatch()

    public var timers: [Countdown] { countdowns.filter { $0.kind == .timer } }
    public var alarms: [Countdown] { countdowns.filter { $0.kind == .alarm } }
    public var isEmpty: Bool { countdowns.isEmpty && stopwatch.isIdle }
    /// Anything whose display changes every second.
    public var isTicking: Bool { timers.contains { !$0.isPaused } || stopwatch.isRunning }

    public init() {}
}

/// Delivers notifications, as a backup for when the app isn't running to
/// ring itself. Implemented by the app (UserNotifications needs a bundle).
public protocol ClockNotifier: Sendable {
    /// Replaces every scheduled clock notification with these.
    func schedule(_ items: [ClockNotification])
    func deliverNow(_ item: ClockNotification)
}

public struct ClockNotification: Sendable, Equatable {
    public let id: String
    public let title: String
    public let body: String
    public let date: Date
}

/// Timers, alarms and the stopwatch. Kept on disk, so they survive a quit
/// or crash, and rung by the app itself: a countdown in the notch, a sound,
/// the voice. A notification is scheduled a few seconds after each one as a
/// backup, and withdrawn when the app rings it itself.
public final class ClockStore: Sendable {
    public static let shared = ClockStore(file: URL.applicationSupportDirectory.appending(path: "NotchAssistant/clock.json"))

    /// Longest timer or furthest alarm accepted.
    static let limit: TimeInterval = 7 * 24 * 3600
    /// The backup notification's delay after the app should have rung.
    static let backupDelay: TimeInterval = 5
    /// Overdue by more than this at launch: the notification covered it.
    static let staleAfter: TimeInterval = 5 * 60
    public static let snoozeMinutes = 9

    private struct State: Codable {
        var countdowns: [Countdown] = []
        var stopwatch = Stopwatch()
    }

    private struct Hooks {
        var onFire: (@Sendable (ClockAlert) -> Void)?
        var onChange: (@Sendable (ClockSnapshot) -> Void)?
        var notifier: (any ClockNotifier)?
        var scheduler: Task<Void, Never>?
    }

    private let file: URL?
    private let state: Mutex<State>
    private let hooks = Mutex(Hooks())

    /// `file` nil keeps everything in memory (tests).
    init(file: URL?) {
        self.file = file
        let loaded = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(State.self, from: $0) }
        state = Mutex(loaded ?? State())
    }

    /// Starts ringing. Call once the hooks are set.
    public func start(notifier: (any ClockNotifier)?, onChange: @escaping @Sendable (ClockSnapshot) -> Void, onFire: @escaping @Sendable (ClockAlert) -> Void) {
        hooks.withLock {
            $0.notifier = notifier
            $0.onChange = onChange
            $0.onFire = onFire
        }
        // Long overdue (the app wasn't running): the notification told the
        // user already; ringing now, hours late, would only confuse.
        let now = Date()
        state.withLock { $0.countdowns.removeAll { !$0.isPaused && $0.fireDate < now.addingTimeInterval(-Self.staleAfter) } }
        changed()
    }

    public var snapshot: ClockSnapshot {
        state.withLock { state in
            var snapshot = ClockSnapshot()
            snapshot.countdowns = state.countdowns.sorted { $0.remaining() < $1.remaining() }
            snapshot.stopwatch = state.stopwatch
            return snapshot
        }
    }

    // MARK: Timers and alarms

    @discardableResult
    func addTimer(_ seconds: TimeInterval, label: String?, now: Date = Date()) -> Countdown {
        let timer = Countdown(id: UUID(), kind: .timer, label: label, fireDate: now.addingTimeInterval(seconds), duration: seconds)
        mutate { $0.countdowns.append(timer) }
        return timer
    }

    @discardableResult
    func addAlarm(at date: Date, label: String?) -> Countdown {
        let alarm = Countdown(id: UUID(), kind: .alarm, label: label, fireDate: date, duration: 0)
        mutate { $0.countdowns.append(alarm) }
        return alarm
    }

    public func remove(_ ids: Set<UUID>) {
        mutate { $0.countdowns.removeAll { ids.contains($0.id) } }
    }

    public func pause(_ id: UUID, now: Date = Date()) {
        mutate { state in
            guard let index = state.countdowns.firstIndex(where: { $0.id == id }), !state.countdowns[index].isPaused else { return }
            state.countdowns[index].pausedRemaining = state.countdowns[index].remaining(at: now)
        }
    }

    public func resume(_ id: UUID, now: Date = Date()) {
        mutate { state in
            guard let index = state.countdowns.firstIndex(where: { $0.id == id }), let remaining = state.countdowns[index].pausedRemaining else { return }
            state.countdowns[index].fireDate = now.addingTimeInterval(remaining)
            state.countdowns[index].pausedRemaining = nil
        }
    }

    func extend(_ id: UUID, by seconds: TimeInterval) {
        mutate { state in
            guard let index = state.countdowns.firstIndex(where: { $0.id == id }) else { return }
            state.countdowns[index].duration += seconds
            if let paused = state.countdowns[index].pausedRemaining {
                state.countdowns[index].pausedRemaining = paused + seconds
            } else {
                state.countdowns[index].fireDate.addTimeInterval(seconds)
            }
        }
    }

    /// Rings again in a few minutes, as the same alarm.
    @discardableResult
    public func snooze(_ alert: ClockAlert, now: Date = Date()) -> Date {
        let date = now.addingTimeInterval(TimeInterval(Self.snoozeMinutes * 60))
        mutate { $0.countdowns.append(Countdown(id: UUID(), kind: alert.kind, label: alert.label, fireDate: date, duration: 0)) }
        return date
    }

    /// Rang and nobody stopped it: leave a notification to find later.
    public func missed(_ alert: ClockAlert) {
        let notifier = hooks.withLock { $0.notifier }
        notifier?.deliverNow(ClockNotification(id: "missed-\(alert.id)", title: alert.title, body: alert.message, date: Date()))
    }

    // MARK: Stopwatch

    /// The menu bar's Stop / Resume.
    public func toggleStopwatch(now: Date = Date()) {
        _ = updateStopwatch { watch in
            if watch.isRunning {
                watch.accumulated = watch.elapsed(at: now)
                watch.startedAt = nil
            } else {
                watch.startedAt = now
            }
        }
    }

    public func resetStopwatch() {
        _ = updateStopwatch { $0 = Stopwatch() }
    }

    func updateStopwatch(_ change: (inout Stopwatch) -> Void) -> Stopwatch {
        var result = Stopwatch()
        mutate { state in
            change(&state.stopwatch)
            result = state.stopwatch
        }
        return result
    }

    // MARK: Ringing

    /// Ring whatever is due now. Public for tests and for waking from sleep.
    func fireDue(now: Date = Date()) {
        var due: [Countdown] = []
        mutate { state in
            due = state.countdowns.filter { !$0.isPaused && $0.fireDate <= now.addingTimeInterval(0.05) }
            state.countdowns.removeAll { item in due.contains { $0.id == item.id } }
        }
        let onFire = hooks.withLock { $0.onFire }
        for countdown in due.sorted(by: { $0.fireDate < $1.fireDate }) {
            Log.tools.notice("clock: ringing \(countdown.name, privacy: .public)")
            onFire?(ClockAlert(countdown))
        }
    }

    private func mutate(_ change: (inout State) -> Void) {
        state.withLock { change(&$0) }
        changed()
    }

    private func changed() {
        let snapshot = self.snapshot
        let (onChange, notifier) = hooks.withLock { ($0.onChange, $0.notifier) }
        save()
        reschedule()
        notifier?.schedule(snapshot.countdowns.filter { !$0.isPaused }.map { countdown in
            let alert = ClockAlert(countdown)
            return ClockNotification(id: countdown.id.uuidString, title: alert.title, body: alert.message,
                                     date: countdown.fireDate.addingTimeInterval(Self.backupDelay))
        })
        onChange?(snapshot)
    }

    private func save() {
        guard let file else { return }
        let data = state.withLock { try? JSONEncoder().encode($0) }
        guard let data else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// One task sleeps until the next countdown is due, checking at least
    /// every minute (so sleep, wake and clock changes can't strand it). No
    /// task at all when nothing is counting down.
    private func reschedule() {
        let hasHooks = hooks.withLock { $0.onFire != nil }
        guard hasHooks else { return }
        let task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self, let next = self.nextFireDate else { return }
                let wait = next.timeIntervalSinceNow
                if wait > 0 {
                    try? await Task.sleep(for: .seconds(min(wait, 60)))
                    continue
                }
                self.fireDue()
                return // fireDue changed state, which started a new task.
            }
        }
        let previous = hooks.withLock { hooks in
            let previous = hooks.scheduler
            hooks.scheduler = task
            return previous
        }
        previous?.cancel()
    }

    private var nextFireDate: Date? {
        state.withLock { $0.countdowns.filter { !$0.isPaused }.map(\.fireDate).min() }
    }
}

/// What the user said over a ringing alert.
enum AlertReply: Equatable {
    case stop, snooze

    static func interpret(_ transcript: String) -> AlertReply? {
        let words = SpokenWords(transcript).lower
        if words.contains("snooze") || words.joined(separator: " ").contains("few more minutes") { return .snooze }
        let stops: Set<String> = [
            "stop", "ok", "okay", "dismiss", "thanks", "thank", "off", "cancel", "enough", "quiet", "silence",
            "shut", "done", "awake", "got", "alright",
        ]
        let text = words.joined(separator: " ")
        if ["im up", "i m up", "i am up"].contains(text) { return .stop }
        // Short replies only: "stop", "okay thanks", "turn it off". Longer
        // ones ("turn off the lights") are new commands.
        guard words.count <= 3, words.contains(where: stops.contains) else { return nil }
        return .stop
    }
}
