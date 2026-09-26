import Foundation
import FoundationModels
import MapKit

/// Shared by the clock tools.
enum ClockPhrases {
    /// Commands for another tool: "open Clock", "play the alarm song".
    static let foreignVerbs: Set<String> = ["open", "launch", "go to", "search", "search for", "google", "look up", "play", "watch"]
    static let cancelWords: Set<String> = ["cancel", "stop", "delete", "remove", "clear", "end", "kill", "dismiss", "disable", "off"]
    static let pauseWords: Set<String> = ["pause", "hold", "freeze"]
    static let resumeWords: Set<String> = ["resume", "continue", "unpause", "restart"]
    static let askWords: Set<String> = ["how", "what", "whats", "which", "when", "check", "status", "left", "remaining", "list", "show", "any", "many"]
    /// Words that are never a timer's or alarm's name.
    static let notLabels: Set<String> = Set<String>([
        "a", "an", "the", "my", "set", "start", "new", "another", "create", "make", "timer", "timers", "alarm", "alarms",
        "for", "of", "to", "on", "is", "at", "in", "and", "all", "every", "this", "that", "add", "up", "me", "wake", "please",
        "how", "much", "long", "left", "check", "put", "i", "want", "need", "can", "you", "could", "hey", "okay", "ok",
        "am", "pm", "oclock", "tomorrow", "today", "tonight", "morning", "evening", "afternoon", "night",
        "do", "does", "have", "has", "got", "any", "set", "there", "are", "what", "whats", "which", "when", "list", "show",
    ]).union(cancelWords).union(pauseWords).union(resumeWords).union(SpokenDuration.unitWords).union(SpokenWords.numberWords)

    /// A name the user gave: "set a pasta timer", "timer called pasta",
    /// "a 10 minute timer for the pasta". Nil when none was given.
    static func label(in words: SpokenWords, noun: String, skipping taken: Set<Int>) -> String? {
        let w = words.lower
        // "called pasta", "named pasta", "labelled pasta".
        if let index = w.firstIndex(where: { ["called", "named", "labelled", "labeled"].contains($0) }), index + 1 < w.count {
            let rest = (index + 1..<w.count).filter { !taken.contains($0) }
            if !rest.isEmpty { return words.text(rest) }
        }
        // "pasta timer": the words just before the noun.
        if let noun = w.firstIndex(where: { $0 == noun || $0 == noun + "s" }) {
            var index = noun - 1
            var name: [Int] = []
            while index >= 0, !taken.contains(index), !notLabels.contains(w[index]), !SpokenWords.isNumeric(w[index]) {
                name.insert(index, at: 0)
                index -= 1
            }
            if !name.isEmpty, name.count <= 3 { return words.text(name) }
        }
        // "for the pasta" at the end, when it isn't the time or duration.
        if let index = w.lastIndex(of: "for"), !taken.contains(index + 1), index + 1 < w.count {
            let rest = (index + 1..<w.count).filter { !["the", "my"].contains(w[$0]) }
            if !rest.isEmpty, rest.count <= 3, rest.allSatisfy({ !taken.contains($0) && !notLabels.contains(w[$0]) && !SpokenWords.isNumeric(w[$0]) }) {
                return words.text(rest)
            }
        }
        return nil
    }

    /// Keeps a model-supplied value only if the user said it.
    static func grounded(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        guard let transcript = CommandContext.transcript else { return value }
        return Grounding.mentions(value, in: transcript) ? value : nil
    }

    static var saidAll: Bool {
        guard let transcript = CommandContext.transcript else { return false }
        return SpokenWords(transcript).containsAny(["all", "every", "everything"])
    }

    /// Picks the countdowns a command means: all of them, the named one,
    /// or the only one. Throws when it can't tell.
    static func select(_ candidates: [Countdown], label: String?, all: Bool, what: String) throws -> [Countdown] {
        guard !candidates.isEmpty else { throw ToolError("You don't have any \(what)s") }
        if all || label == "all" { return candidates }
        if let label = label?.lowercased(), !label.isEmpty {
            let named = candidates.filter { ($0.label ?? "").lowercased().contains(label) || $0.name.lowercased().contains(label) }
            guard !named.isEmpty else { throw ToolError("There's no \(label) \(what)") }
            return named
        }
        if candidates.count == 1 { return candidates }
        let names = candidates.map(\.name).joined(separator: ", ")
        throw ToolError("Which one? You have \(names)")
    }
}

// MARK: - Timer

@Generable
struct TimerArguments: Sendable {
    @Guide(description: "What to do", .anyOf(["start", "cancel", "pause", "resume", "add", "status"]))
    var action: String
    @Guide(description: "How long, as the user said it, e.g. \"10 minutes\"")
    var duration: String?
    @Guide(description: "The timer's name, only if the user gave one, e.g. \"pasta\"")
    var label: String?
}

/// Countdown timers, several at once, optionally named. They ring in the
/// notch with a sound and the voice.
struct TimerTool: AssistantTool {
    let name = "timer"
    let title = "Timer"
    let symbol = "timer"
    let keywords: Set<String> = ["timer", "timers", "countdown", "time"]
    let description = """
        Countdown timers. "set a timer for 10 minutes" → start, duration "10 minutes". \
        "how long is left on the pasta timer" → status, label "pasta". "cancel the timer" → cancel.
        """
    let requiresNetwork = false
    let permission = ToolPermission.none
    let reversibility = Reversibility.notApplicable

    var store: ClockStore = .shared

    func target(of arguments: TimerArguments) -> String {
        [arguments.label, arguments.duration].compactMap { $0 }.joined(separator: " · ")
    }

    func execute(_ arguments: TimerArguments) async throws -> ToolResult {
        let label = ClockPhrases.grounded(arguments.label).flatMap { $0 == "all" ? nil : $0 }
        let timers = store.snapshot.timers
        switch arguments.action {
        case "start":
            guard let seconds = duration(arguments.duration) else {
                throw ToolError("For how long? Say “set a timer for 10 minutes”")
            }
            guard seconds >= 1, seconds <= ClockStore.limit else { throw ToolError("Timers can run for up to a week") }
            let timer = store.addTimer(seconds, label: label)
            return ToolResult("\(timer.name.prefix(1).uppercased() + timer.name.dropFirst()) set for \(ClockFormat.spoken(seconds))")
        case "cancel":
            let chosen = try ClockPhrases.select(timers, label: label, all: ClockPhrases.saidAll, what: "timer")
            store.remove(Set(chosen.map(\.id)))
            return ToolResult(chosen.count == 1 ? "Cancelled the \(chosen[0].name)" : "Cancelled \(chosen.count) timers")
        case "pause":
            let chosen = try ClockPhrases.select(timers.filter { !$0.isPaused }, label: label, all: ClockPhrases.saidAll, what: "running timer")
            chosen.forEach { store.pause($0.id) }
            return ToolResult(chosen.count == 1
                ? "Paused the \(chosen[0].name) with \(ClockFormat.spoken(chosen[0].remaining())) left"
                : "Paused \(chosen.count) timers")
        case "resume":
            let chosen = try ClockPhrases.select(timers.filter(\.isPaused), label: label, all: ClockPhrases.saidAll, what: "paused timer")
            chosen.forEach { store.resume($0.id) }
            return ToolResult(chosen.count == 1 ? "Resumed the \(chosen[0].name)" : "Resumed \(chosen.count) timers")
        case "add":
            guard let seconds = duration(arguments.duration) else { throw ToolError("How much time should I add?") }
            let chosen = try ClockPhrases.select(timers, label: label, all: false, what: "timer")
            chosen.forEach { store.extend($0.id, by: seconds) }
            let timer = store.snapshot.timers.first { $0.id == chosen[0].id }
            return ToolResult("Added \(ClockFormat.spoken(seconds)). \(ClockFormat.spoken(timer?.remaining() ?? seconds)) left", isAnswer: true)
        default:
            return ToolResult(Self.status(of: timers, label: label), isAnswer: true)
        }
    }

    static func status(of timers: [Countdown], label: String?) -> String {
        var timers = timers
        if let label = label?.lowercased() {
            let named = timers.filter { $0.name.lowercased().contains(label) }
            if !named.isEmpty { timers = named }
        }
        guard !timers.isEmpty else { return "You don't have any timers" }
        if timers.count == 1 {
            let timer = timers[0]
            return "\(ClockFormat.spoken(timer.remaining())) left on your \(timer.name)" + (timer.isPaused ? ". It's paused" : "")
        }
        return timers.map { "\($0.name): \(ClockFormat.spoken($0.remaining()))\($0.isPaused ? ", paused" : "")" }.joined(separator: ". ")
    }

    /// The model's duration when the user said that length, even in other
    /// words ("90 minutes" for "an hour and a half"). Otherwise the one
    /// duration the user said; with several ("10, 20 and 30 seconds") there
    /// is no guessing which.
    private func duration(_ spoken: String?) -> TimeInterval? {
        let model = spoken.flatMap(SpokenDuration.parse)
        guard let transcript = CommandContext.transcript else { return model }
        let said = SpokenDuration.all(in: transcript)
        if let model, said.contains(model) { return model }
        return said.count == 1 ? said[0] : nil
    }

    /// "set a timer for 10 minutes", "10 minute pasta timer", "how long is
    /// left", "cancel all timers", "add 5 minutes to the timer".
    func directArguments(for command: DirectCommand) -> TimerArguments? {
        guard !ClockPhrases.foreignVerbs.contains(command.verb) else { return nil }
        let words = SpokenWords(command.original)
        let asksLeft = words.containsAny(["left", "remaining"]) && (command.text.hasPrefix("how") || command.text.hasPrefix("what"))
        // "time 5 minutes for my tea".
        let timeVerb = command.text.hasPrefix("time ") && SpokenDuration.find(in: words) != nil
        guard words.containsAny(["timer", "timers", "countdown"]) || asksLeft || timeVerb,
              !words.containsAny(["stopwatch", "alarm", "alarms", "remind", "reminder"]) else { return nil }
        let found = SpokenDuration.find(in: words)
        let taken = Set(found?.range ?? 0..<0)
        let duration = found.map { words.text($0.range) }
        var label = ClockPhrases.label(in: words, noun: "timer", skipping: taken)
        if words.containsAny(["all", "every"]) { label = "all" }

        let first = words.lower.first ?? ""
        let action: String
        if words.containsAny(ClockPhrases.cancelWords) {
            action = "cancel"
        } else if words.containsAny(ClockPhrases.pauseWords) {
            action = "pause"
        } else if words.containsAny(ClockPhrases.resumeWords) {
            action = "resume"
        } else if words.containsAny(["add", "extend"]) || (first == "another" && found != nil && words.contains("to")) {
            action = "add"
        } else if words.containsAny(ClockPhrases.askWords) || asksLeft {
            action = "status"
        } else {
            action = "start"
        }
        return TimerArguments(action: action, duration: duration, label: label)
    }
}

// MARK: - Alarm

@Generable
struct AlarmArguments: Sendable {
    @Guide(description: "What to do", .anyOf(["set", "cancel", "list"]))
    var action: String
    @Guide(description: "When, as the user said it, e.g. \"7 am\" or \"tomorrow at 6:30\"")
    var time: String?
    @Guide(description: "The alarm's name, only if the user gave one, e.g. \"gym\"")
    var label: String?
    @Guide(description: "Only if the alarm repeats, as the user said it, e.g. \"every weekday\"")
    var repeats: String?
}

/// Alarms at a time of day. They ring like timers, and can be snoozed.
struct AlarmTool: AssistantTool {
    let name = "alarm"
    let title = "Alarm"
    let symbol = "alarm"
    let keywords: Set<String> = ["alarm", "alarms", "wake", "snooze"]
    let description = """
        Alarms at a time of day. "set an alarm for 7 am" → set, time "7 am". "wake me up tomorrow at 6:30" → set, \
        time "tomorrow at 6:30". "what alarms do I have" → list. "cancel my 7 am alarm" → cancel, time "7 am".
        """
    let requiresNetwork = false
    let permission = ToolPermission.none
    let reversibility = Reversibility.notApplicable

    var store: ClockStore = .shared

    func target(of arguments: AlarmArguments) -> String {
        [arguments.label, arguments.time].compactMap { $0 }.joined(separator: " · ")
    }

    func execute(_ arguments: AlarmArguments) async throws -> ToolResult {
        let label = ClockPhrases.grounded(arguments.label).flatMap { $0 == "all" ? nil : $0 }
        let alarms = store.snapshot.alarms
        let now = Date()
        switch arguments.action {
        case "set":
            guard let (when, text) = when(arguments.time, now: now), when.hasTime else {
                throw ToolError("For what time? Say “set an alarm for 7 am”")
            }
            if let days = try repeatDays(arguments.repeats) {
                // "every weekday at 7" is 7 am unless said otherwise: read
                // the hour as said, as with "tomorrow at 7".
                let clock = SpokenWhen.parse("tomorrow " + text, now: now)?.date ?? when.date
                guard let first = AlarmRepeat.next(after: now, at: clock, on: days) else { throw ToolError("I couldn't work out when that alarm rings") }
                let alarm = store.addAlarm(at: first, label: label, repeatDays: days)
                let time = first.formatted(date: .omitted, time: .shortened)
                let name = alarm.label.map { " (\($0))" } ?? ""
                return ToolResult("Alarm set for \(time) \(AlarmRepeat.describe(days))\(name)")
            }
            guard when.date > now, when.date.timeIntervalSince(now) <= ClockStore.limit else {
                throw ToolError("Alarms can be set for up to a week ahead")
            }
            let alarm = store.addAlarm(at: when.date, label: label)
            let name = alarm.label.map { " (\($0))" } ?? ""
            return ToolResult("Alarm set for \(ClockFormat.when(alarm.fireDate, now: now))\(name)")
        case "cancel":
            var candidates = alarms
            // "cancel my 7 am alarm": the alarm at that time.
            if let (when, _) = when(arguments.time, now: now), when.hasTime {
                let calendar = Calendar.current
                let wanted = calendar.dateComponents([.hour, .minute], from: when.date)
                candidates = alarms.filter { calendar.dateComponents([.hour, .minute], from: $0.fireDate) == wanted }
                if candidates.isEmpty { throw ToolError("There's no alarm at \(when.date.formatted(date: .omitted, time: .shortened))") }
            }
            let chosen = try ClockPhrases.select(candidates, label: label, all: ClockPhrases.saidAll, what: "alarm")
            store.remove(Set(chosen.map(\.id)))
            return ToolResult(chosen.count == 1
                ? "Cancelled the alarm for \(ClockFormat.when(chosen[0].fireDate, now: now))"
                : "Cancelled \(chosen.count) alarms")
        default:
            guard !alarms.isEmpty else { return ToolResult("You don't have any alarms", isAnswer: true) }
            let list = alarms.sorted { $0.fireDate < $1.fireDate }.map { alarm in
                let when = alarm.repeatDays.map { "\(alarm.fireDate.formatted(date: .omitted, time: .shortened)) \(AlarmRepeat.describe($0))" }
                    ?? ClockFormat.when(alarm.fireDate, now: now)
                return when + (alarm.label.map { " for \($0)" } ?? "")
            }
            return ToolResult(list.count == 1 ? "You have an alarm \(Self.at(list[0]))" : "You have \(list.count) alarms: " + list.joined(separator: ", "), isAnswer: true)
        }
    }

    /// "at 7:00 AM", "tomorrow at 7:00 AM".
    private static func at(_ when: String) -> String {
        when.first?.isNumber == true ? "at \(when)" : when
    }

    /// The model's days when the user said them, even in other words
    /// ("every weekday" for "on weekdays"). A command with one alarm uses
    /// the days it said; with several ("7 on weekdays and 8 on weekends")
    /// the model's split is the only one there is, so it must check out.
    private func repeatDays(_ spoken: String?) throws -> Set<Int>? {
        let model = spoken.flatMap(AlarmRepeat.parse)
        guard let transcript = CommandContext.transcript else { return model }
        guard let said = AlarmRepeat.parse(transcript) else { return nil }
        if let model, model.isSubset(of: said) { return model }
        guard SpokenWhen.clockTimes(in: transcript).count <= 1 else {
            throw ToolError("I couldn't tell which days each alarm is for; set them one at a time")
        }
        return said
    }

    /// The model's time when the user said it, with the text to read it
    /// from; otherwise the one time in what the user said.
    private func when(_ spoken: String?, now: Date) -> (when: SpokenWhen, text: String)? {
        guard let transcript = CommandContext.transcript else {
            return spoken.flatMap { text in SpokenWhen.parse(text, now: now).map { ($0, text) } }
        }
        if let spoken, let when = SpokenWhen.parse(spoken, now: now),
           Grounding.mentions(spoken, in: transcript) || (when.hasTime && SpokenWhen.wasSaid(when.date, in: transcript)) {
            return (when, spoken)
        }
        guard SpokenWhen.clockTimes(in: transcript).count <= 1 else { return nil }
        return SpokenWhen.parse(transcript, now: now).map { ($0, transcript) }
    }

    /// "set an alarm for 7 am", "wake me up at 6:30 tomorrow", "alarm for
    /// 7 called gym", "cancel my 7 am alarm", "what alarms do I have".
    func directArguments(for command: DirectCommand) -> AlarmArguments? {
        guard !ClockPhrases.foreignVerbs.contains(command.verb) else { return nil }
        let words = SpokenWords(command.original)
        let wake = command.text.hasPrefix("wake me")
        guard words.containsAny(["alarm", "alarms"]) || wake,
              !words.containsAny(["timer", "timers", "stopwatch", "remind", "reminder"]) else { return nil }
        // "every Monday at 7": the days repeat, so only the time is parsed.
        let repeating = AlarmRepeat.find(in: words)
        let consumed: Set<Int>?
        if let repeating {
            consumed = SpokenWhen.time(in: words, from: 0, excluding: repeating.consumed)?.consumed
        } else {
            consumed = SpokenWhen.find(in: words, now: Date(), calendar: .current)?.consumed
        }
        let taken = (consumed ?? []).union(repeating?.consumed ?? [])
        let time = consumed.map { words.text($0) }
        var label = ClockPhrases.label(in: words, noun: "alarm", skipping: taken)
        if words.containsAny(["all", "every"]) { label = "all" }

        let action: String
        if words.containsAny(ClockPhrases.cancelWords) || command.text.contains("turn off") {
            action = "cancel"
        } else if !wake, words.containsAny(["what", "whats", "which", "when", "list", "show", "any", "check", "many"]) {
            action = "list"
        } else {
            action = "set"
        }
        return AlarmArguments(action: action, time: time, label: label, repeats: repeating.map { words.text($0.consumed) })
    }
}

// MARK: - Stopwatch

@Generable
struct StopwatchArguments: Sendable {
    @Guide(description: "What to do", .anyOf(["start", "stop", "resume", "reset", "restart", "lap", "status"]))
    var action: String
}

struct StopwatchTool: AssistantTool {
    let name = "stopwatch"
    let title = "Stopwatch"
    let symbol = "stopwatch"
    let keywords: Set<String> = ["stopwatch", "lap", "laps"]
    let description = """
        A stopwatch. "start a stopwatch" → start. "stop the stopwatch" → stop. "how long has the stopwatch been running" → status. \
        "lap" → lap.
        """
    let requiresNetwork = false
    let permission = ToolPermission.none
    let reversibility = Reversibility.notApplicable

    var store: ClockStore = .shared

    func target(of arguments: StopwatchArguments) -> String {
        arguments.action
    }

    func execute(_ arguments: StopwatchArguments) async throws -> ToolResult {
        let now = Date()
        let current = store.snapshot.stopwatch
        switch arguments.action {
        case "start", "restart":
            if arguments.action == "start", current.isRunning {
                return ToolResult("The stopwatch is already running: \(ClockFormat.spoken(current.elapsed(at: now)))", isAnswer: true)
            }
            // A new start times from zero; "resume" continues.
            _ = store.updateStopwatch { $0 = Stopwatch(startedAt: now) }
            return ToolResult(arguments.action == "restart" ? "Stopwatch restarted" : "Stopwatch started")
        case "stop":
            guard current.isRunning else {
                if current.isIdle { throw ToolError("The stopwatch isn't running") }
                return ToolResult("The stopwatch is stopped at \(ClockFormat.spoken(current.elapsed(at: now)))", isAnswer: true)
            }
            let stopped = store.updateStopwatch { watch in
                watch.accumulated = watch.elapsed(at: now)
                watch.startedAt = nil
            }
            return ToolResult("Stopwatch stopped at \(Self.reading(stopped.elapsed(at: now)))", isAnswer: true)
        case "resume":
            guard !current.isRunning else { return ToolResult("The stopwatch is already running") }
            _ = store.updateStopwatch { $0.startedAt = now }
            return ToolResult(current.isIdle ? "Stopwatch started" : "Stopwatch resumed at \(ClockFormat.stopwatch(current.accumulated))")
        case "reset":
            _ = store.updateStopwatch { $0 = Stopwatch() }
            return ToolResult("Stopwatch reset")
        case "lap":
            guard current.isRunning else { throw ToolError("The stopwatch isn't running") }
            let watch = store.updateStopwatch { watch in
                watch.laps.append(watch.elapsed(at: now) - watch.laps.reduce(0, +))
            }
            return ToolResult("Lap \(watch.laps.count): \(Self.reading(watch.laps.last ?? 0))", isAnswer: true)
        default:
            guard !current.isIdle else { return ToolResult("The stopwatch isn't running", isAnswer: true) }
            return ToolResult("\(Self.reading(current.elapsed(at: now)))\(current.isRunning ? "" : ", stopped")", isAnswer: true)
        }
    }

    /// "1 minute 23 seconds", with tenths under a minute: "12.4 seconds".
    static func reading(_ elapsed: TimeInterval) -> String {
        elapsed < 60 ? String(format: "%.1f seconds", elapsed) : ClockFormat.spoken(elapsed)
    }

    /// "start a stopwatch", "stop the stopwatch", "lap", "reset the stopwatch".
    func directArguments(for command: DirectCommand) -> StopwatchArguments? {
        guard !ClockPhrases.foreignVerbs.contains(command.verb) else { return nil }
        let words = SpokenWords(command.original)
        let text = words.lower.joined(separator: " ")
        if text == "lap" || text == "split" { return StopwatchArguments(action: "lap") }
        guard words.contains("stopwatch") else { return nil }
        let rest = Set(words.lower.filter { $0 != "stopwatch" })
        let action: String
        if rest.contains("restart") || text.contains("start over") || text.contains("start again") {
            action = "restart"
        } else if !rest.isDisjoint(with: ["reset", "clear", "zero"]) {
            action = "reset"
        } else if !rest.isDisjoint(with: ["lap", "split"]) {
            action = "lap"
        } else if !rest.isDisjoint(with: ["stop", "pause", "end", "halt", "finish"]) {
            action = "stop"
        } else if !rest.isDisjoint(with: ["resume", "continue", "unpause"]) {
            action = "resume"
        } else if !rest.isDisjoint(with: ["how", "what", "whats", "check", "status", "time", "long", "reading"]) {
            action = "status"
        } else {
            action = "start"
        }
        return StopwatchArguments(action: action)
    }
}

// MARK: - Time and date

@Generable
struct CurrentTimeArguments: Sendable {
    @Guide(description: "What the user asked for", .anyOf(["time", "date"]))
    var what: String
    @Guide(description: "City or place, only if the user named one, e.g. \"Tokyo\"")
    var place: String?
}

/// "What time is it", "what's the date", "what time is it in Tokyo".
struct CurrentTimeTool: AssistantTool {
    let name = "currentTime"
    let title = "Clock"
    let symbol = "clock"
    let keywords: Set<String> = ["time", "date", "day", "today", "clock"]
    let description = """
        Say the current time or date. "what time is it in Tokyo" → what "time", place "Tokyo". "what's the date" → what "date".
        """
    let requiresNetwork = false
    let permission = ToolPermission.none
    let reversibility = Reversibility.notApplicable

    func target(of arguments: CurrentTimeArguments) -> String {
        arguments.place ?? (arguments.what == "date" ? "Today" : "Now")
    }

    func execute(_ arguments: CurrentTimeArguments) async throws -> ToolResult {
        let now = Date()
        var zone = TimeZone.current
        var place: String?
        if let spoken = ClockPhrases.grounded(arguments.place) {
            let (name, found) = try await Self.timeZone(for: spoken)
            zone = found
            place = name
        }
        var style = Date.FormatStyle.dateTime
        style.timeZone = zone
        if arguments.what == "date" {
            let date = now.formatted(style.weekday(.wide).day().month(.wide).year())
            return ToolResult(place.map { "In \($0) it's \(date)" } ?? "It's \(date)", isAnswer: true)
        }
        let time = now.formatted(style.hour().minute())
        guard let place else { return ToolResult("It's \(time)", isAnswer: true) }
        // Say the day too when it differs from here.
        var here = Calendar.current
        var there = Calendar.current
        there.timeZone = zone
        here.timeZone = .current
        let day = there.component(.day, from: now) != here.component(.day, from: now)
            ? ", \(now.formatted(style.weekday(.wide)))" : ""
        return ToolResult("It's \(time)\(day) in \(place)", isAnswer: true)
    }

    /// A city in the time zone database ("Tokyo" → Asia/Tokyo), else
    /// Apple's geocoder, which knows every place's time zone.
    static func timeZone(for place: String) async throws -> (String, TimeZone) {
        let key = AppNameMatcher.key(place)
        if let identifier = TimeZone.knownTimeZoneIdentifiers.first(where: {
            AppNameMatcher.key(String($0.split(separator: "/").last ?? "").replacingOccurrences(of: "_", with: " ")) == key
        }), let zone = TimeZone(identifier: identifier) {
            return (place.capitalized, zone)
        }
        guard let request = MKGeocodingRequest(addressString: place),
              let item = try? await request.mapItems.first, let zone = item.timeZone
        else { throw ToolError("I couldn't find the time zone for \(place)") }
        return (item.name ?? place.capitalized, zone)
    }

    private static let timePhrases: Set<String> = [
        "time", "what time is it", "whats the time", "what is the time", "tell me the time", "current time",
        "what time it is", "do you know what time it is", "what s the time", "the time",
    ]
    private static let datePhrases: Set<String> = [
        "date", "whats the date", "what s the date", "what is the date", "what is today s date", "what s today s date",
        "whats todays date", "todays date", "today s date", "what day is it", "what day is today", "what s today",
        "whats today", "what is today", "what date is it", "what is the date today", "what s the date today", "the date",
    ]

    func directArguments(for command: DirectCommand) -> CurrentTimeArguments? {
        var text = command.text
        var place: String?
        if let range = text.range(of: " in ") {
            place = String(text[range.upperBound...])
            text = String(text[..<range.lowerBound])
        }
        if Self.timePhrases.contains(text) || (place != nil && text.hasPrefix("time")) {
            return CurrentTimeArguments(what: "time", place: place)
        }
        if Self.datePhrases.contains(text) {
            return CurrentTimeArguments(what: "date", place: place)
        }
        return nil
    }
}
