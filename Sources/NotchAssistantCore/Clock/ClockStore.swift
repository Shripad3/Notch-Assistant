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
    /// A repeating alarm's days, 1 = Sunday … 7 = Saturday.
    public var repeatDays: Set<Int>?

    /// An alarm switched off in Settings: kept, but never rings.
    public var disabled: Bool?

    public var isPaused: Bool { pausedRemaining != nil }
    public var isEnabled: Bool { disabled != true }
    /// Counting down to ring: not paused, not switched off.
    public var isArmed: Bool { !isPaused && isEnabled }

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
    public private(set) var title: String
    /// Said aloud: "Your pasta timer is done."
    public private(set) var message: String
    /// The Settings "Test" button: nothing to snooze or report as missed.
    public private(set) var isTest = false

    public var canSnooze: Bool { kind == .alarm && !isTest }

    /// How an alarm or timer will ring, from Settings.
    public static func test(_ kind: Countdown.Kind) -> ClockAlert {
        var alert = ClockAlert(Countdown(id: UUID(), kind: kind, label: nil, fireDate: Date(), duration: 600))
        alert.isTest = true
        alert.title = kind == .alarm ? "Test alarm" : "Test timer"
        alert.message = kind == .alarm ? "This is how your alarms will sound." : "This is how your timers will sound."
        return alert
    }

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
        state.withLock { $0.countdowns.removeAll { $0.isArmed && $0.fireDate < now.addingTimeInterval(-Self.staleAfter) } }
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

    /// Switches an alarm on or off without deleting it. Switching on moves
    /// it to the next time it can ring.
    public func setEnabled(_ id: UUID, _ enabled: Bool, now: Date = Date()) {
        mutate { state in
            guard let index = state.countdowns.firstIndex(where: { $0.id == id }) else { return }
            state.countdowns[index].disabled = enabled ? nil : true
            if enabled { state.countdowns[index].fireDate = Self.nextRing(of: state.countdowns[index], now: now) }
        }
    }

    /// Changes an alarm's time, name or days (Settings). Nil days: rings once.
    public func updateAlarm(_ id: UUID, hour: Int, minute: Int, label: String?, days: Set<Int>?, now: Date = Date()) {
        mutate { state in
            guard let index = state.countdowns.firstIndex(where: { $0.id == id }) else { return }
            var alarm = state.countdowns[index]
            let calendar = Calendar.current
            alarm.fireDate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: alarm.fireDate) ?? alarm.fireDate
            alarm.label = label.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            alarm.repeatDays = days.flatMap { $0.isEmpty ? nil : $0 }
            alarm.fireDate = Self.nextRing(of: alarm, now: now)
            state.countdowns[index] = alarm
        }
    }

    /// A new alarm at the next `hour:minute` (Settings' Add Alarm).
    @discardableResult
    public func addAlarm(hour: Int, minute: Int, label: String?, days: Set<Int>?, now: Date = Date()) -> Countdown {
        let today = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        var alarm = Countdown(id: UUID(), kind: .alarm, label: label.flatMap { $0.isEmpty ? nil : $0 }, fireDate: today, duration: 0,
                              repeatDays: days.flatMap { $0.isEmpty ? nil : $0 })
        alarm.fireDate = Self.nextRing(of: alarm, now: now)
        mutate { $0.countdowns.append(alarm) }
        return alarm
    }

    /// When an alarm next rings from `now`: its own time if still ahead, else
    /// the next matching day (repeating) or the same time tomorrow (once).
    static func nextRing(of alarm: Countdown, now: Date) -> Date {
        if let days = alarm.repeatDays {
            return AlarmRepeat.next(after: now, at: alarm.fireDate, on: days) ?? alarm.fireDate
        }
        guard alarm.fireDate <= now else { return alarm.fireDate }
        let calendar = Calendar.current
        let clock = calendar.dateComponents([.hour, .minute], from: alarm.fireDate)
        let today = calendar.date(bySettingHour: clock.hour ?? 0, minute: clock.minute ?? 0, second: 0, of: now) ?? now
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today) ?? today
    }

    @discardableResult
    func addAlarm(at date: Date, label: String?, repeatDays: Set<Int>? = nil) -> Countdown {
        let alarm = Countdown(id: UUID(), kind: .alarm, label: label, fireDate: date, duration: 0, repeatDays: repeatDays)
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
        guard !alert.isTest else { return }
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
            due = state.countdowns.filter { $0.isArmed && $0.fireDate <= now.addingTimeInterval(0.05) }
            state.countdowns.removeAll { item in due.contains { $0.id == item.id } }
            // A repeating alarm comes back for its next day.
            for alarm in due {
                guard let days = alarm.repeatDays, let next = AlarmRepeat.next(after: max(now, alarm.fireDate), at: alarm.fireDate, on: days) else { continue }
                var again = alarm
                again.fireDate = next
                state.countdowns.append(again)
            }
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
        notifier?.schedule(snapshot.countdowns.filter(\.isArmed).map { countdown in
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
        state.withLock { $0.countdowns.filter(\.isArmed).map(\.fireDate).min() }
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

/// Repeating alarms: "every day", "on weekdays", "every Monday and Wednesday".
public enum AlarmRepeat {
    static let weekdays = [2, 3, 4, 5, 6]
    private static let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    /// Days (1 = Sunday) and the words that said them.
    static func find(in words: SpokenWords) -> (days: Set<Int>, consumed: Set<Int>)? {
        let w = words.lower
        var days = Set<Int>()
        var consumed = Set<Int>()
        for (index, word) in w.enumerated() {
            switch word {
            case "daily", "everyday":
                days.formUnion(1...7); consumed.insert(index)
            case "day" where index > 0 && w[index - 1] == "every":
                days.formUnion(1...7); consumed.formUnion([index - 1, index])
            case "weekdays", "workdays":
                days.formUnion(weekdays); consumed.insert(index)
            case "weekday" where index > 0 && ["every", "on"].contains(w[index - 1]):
                days.formUnion(weekdays); consumed.insert(index)
            case "weekends":
                days.formUnion([1, 7]); consumed.insert(index)
            case "weekend" where index > 0 && ["every", "on", "at"].contains(w[index - 1]):
                days.formUnion([1, 7]); consumed.insert(index)
            default:
                // "every Monday", "on Mondays", "Monday and Wednesday".
                let singular = word.hasSuffix("s") ? String(word.dropLast()) : word
                guard let day = names.firstIndex(of: singular) else { continue }
                let plural = word != singular
                let every = index > 0 && w[index - 1] == "every"
                let listed = index > 1 && ["and", "or"].contains(w[index - 1]) && !days.isEmpty
                guard plural || every || listed || (index > 0 && w[index - 1] == "," ) else { continue }
                days.insert(day + 1); consumed.insert(index)
                if listed { consumed.insert(index - 1) }
            }
            if consumed.contains(index), index > 0, ["every", "on", "at"].contains(w[index - 1]) { consumed.insert(index - 1) }
        }
        return days.isEmpty ? nil : (days, consumed)
    }

    public static func parse(_ text: String) -> Set<Int>? {
        find(in: SpokenWords(text))?.days
    }

    /// The first of `days` after `now`, at `time`'s hour and minute.
    public static func next(after now: Date, at time: Date, on days: Set<Int>, calendar: Calendar = .current) -> Date? {
        let clock = calendar.dateComponents([.hour, .minute], from: time)
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now),
                  days.contains(calendar.component(.weekday, from: day)),
                  let date = calendar.date(bySettingHour: clock.hour ?? 0, minute: clock.minute ?? 0, second: 0, of: day),
                  date > now else { continue }
            return date
        }
        return nil
    }

    /// "every day", "on weekdays", "at weekends", "every Monday and Wednesday".
    public static func describe(_ days: Set<Int>) -> String {
        if days.count == 7 { return "every day" }
        if days == Set(weekdays) { return "on weekdays" }
        if days == [1, 7] { return "at weekends" }
        let ordered = days.sorted { ($0 + 5) % 7 < ($1 + 5) % 7 } // Monday first
        let named = ordered.map { names[$0 - 1].capitalized }
        return "every " + (named.count > 1 ? named.dropLast().joined(separator: ", ") + " and " + named.last! : named[0])
    }
}
