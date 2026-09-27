import Foundation
import FoundationModels

@Generable
struct CalendarEventArguments: Sendable {
    @Guide(description: "What to do", .anyOf(["add", "move", "delete"]))
    var action: String
    @Guide(description: "The event's name as the user said it, e.g. \"lunch with Sam\" or \"dentist\"")
    var title: String?
    @Guide(description: "When it is (add), or which one (move, delete), as the user said it, e.g. \"tomorrow at 1\"")
    var when: String?
    @Guide(description: "Move only: the new time, as the user said it, e.g. \"Friday at 3\"")
    var newWhen: String?
    @Guide(description: "How long, only if the user said, e.g. \"for an hour\"")
    var duration: String?
}

/// Adds, moves and deletes events in the connected calendar (Apple or
/// Google). Asks when something is missing. Adding and moving can be undone;
/// deleting waits for "yes". Events with other people invited are never
/// changed by voice, because that notifies them.
struct CalendarEventTool: AssistantTool {
    let name = "calendarEvent"
    let title = "Calendar"
    let symbol = "calendar.badge.plus"
    let keywords: Set<String> = ["add", "schedule", "book", "move", "reschedule", "postpone", "cancel", "delete", "appointment", "meeting", "event", "calendar", "lunch", "dinner"]
    let description = """
        Add, move or delete a calendar event. "add lunch with Sam tomorrow at 1" → add, title "lunch with Sam", when "tomorrow at 1". \
        "move my dentist appointment to Friday" → move, title "dentist", newWhen "Friday". "cancel my 3 o'clock" → delete, when "3 o'clock".
        """
    let requiresNetwork = false
    let permission = ToolPermission.calendar
    let reversibility = Reversibility.reversible

    var writer: (any CalendarWriting)?

    func target(of arguments: CalendarEventArguments) -> String {
        [arguments.title, arguments.when, arguments.newWhen.map { "→ \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }

    func execute(_ arguments: CalendarEventArguments) async throws -> ToolResult {
        let provider = CalendarProvider.current
        guard let writer = writer ?? provider.writer else {
            throw ToolError("\(provider.title) is read-only here. Use Apple Calendar or Google in Settings › Calendar to add events")
        }
        let now = Date()
        switch arguments.action {
        case "add": return try await add(arguments, writer: writer, now: now)
        case "move": return try await move(arguments, writer: writer, now: now)
        default: return try await delete(arguments, writer: writer, now: now)
        }
    }

    // MARK: Add

    private func add(_ arguments: CalendarEventArguments, writer: any CalendarWriting, now: Date) async throws -> ToolResult {
        let title = Self.said(arguments.title).map(Self.tidyTitle) ?? ""
        guard !Self.titleWords(title).isEmpty else { return .ask("What's it called?") }
        let allDay = Self.transcriptSays(["all day", "all-day", "whole day"])
        guard let when = Self.when(arguments.when, now: now, fallback: true) else { return .ask("For when?") }
        guard when.hasTime || allDay else { return .ask("What time? Or say all day") }
        let calendar = Calendar.current
        let spoken = arguments.when ?? CommandContext.transcript ?? ""
        let start = allDay ? calendar.startOfDay(for: when.date) : Self.daytime(when, said: spoken, day: when.hasDay ? when.date : nil, now: now)
        let length = Self.duration(arguments.duration) ?? (allDay ? 86_400 : 3_600)
        let end = allDay ? (calendar.date(byAdding: .day, value: max(1, Int(length / 86_400)), to: start) ?? start) : start.addingTimeInterval(length)
        guard allDay || start > now.addingTimeInterval(-60) else { throw ToolError("That time has already passed") }

        let created = try await writer.create(EventDraft(title: title, start: start, end: end, isAllDay: allDay))
        RecentUndo.record("Add “\(title)”") {
            try await writer.delete(created, allOccurrences: false)
            return "Removed “\(title)”"
        }
        return ToolResult("Added “\(title)” \(Self.describe(start, allDay: allDay, now: now)) · say “undo” to remove", undoable: true)
    }

    // MARK: Move

    private func move(_ arguments: CalendarEventArguments, writer: any CalendarWriting, now: Date) async throws -> ToolResult {
        let newLength = Self.duration(arguments.duration)
        let newWhen = arguments.newWhen.flatMap { Self.parseTarget($0, now: now) }
        guard newWhen != nil || newLength != nil else { return .ask("To when?") }
        let event: EditableEvent
        switch try await pick(arguments, writer: writer, now: now) {
        case .found(let found): event = found
        case .ask(let question): return .ask(question)
        }
        try Self.checkEditable(event)

        let calendar = Calendar.current
        var start = event.start
        if let newWhen, let spoken = arguments.newWhen {
            if newWhen.hasDay, !newWhen.hasTime {
                // "to Friday": same time, new day.
                let clock = calendar.dateComponents([.hour, .minute], from: event.start)
                start = calendar.date(bySettingHour: clock.hour ?? 0, minute: clock.minute ?? 0, second: 0, of: newWhen.date) ?? newWhen.date
            } else if !newWhen.hasDay {
                // "to 4": same day, new time.
                start = Self.daytime(newWhen, said: spoken, day: event.start, now: now)
            } else {
                start = Self.daytime(newWhen, said: spoken, day: newWhen.date, now: now)
            }
        }
        let end = start.addingTimeInterval(newLength ?? event.end.timeIntervalSince(event.start))
        try await writer.update(event, start: start, end: end)
        let moved = EditableEvent(id: event.id, calendarID: event.calendarID, seriesID: event.seriesID, title: event.title,
                                  start: start, end: end, isAllDay: event.isAllDay, hasAttendees: event.hasAttendees)
        RecentUndo.record("Move “\(event.title)”") {
            try await writer.update(moved, start: event.start, end: event.end)
            return "Moved “\(event.title)” back to \(Self.describe(event.start, allDay: event.isAllDay, now: Date()))"
        }
        let length = newLength.map { " for \(ClockFormat.spoken($0))" } ?? ""
        return ToolResult("Moved “\(event.title)” to \(Self.describe(start, allDay: event.isAllDay, now: now))\(length) · say “undo” to move it back", undoable: true)
    }

    // MARK: Delete

    private func delete(_ arguments: CalendarEventArguments, writer: any CalendarWriting, now: Date) async throws -> ToolResult {
        let event: EditableEvent
        switch try await pick(arguments, writer: writer, now: now) {
        case .found(let found): event = found
        case .ask(let question): return .ask(question)
        }
        try Self.checkEditable(event)
        let all = event.isRecurring && Self.transcriptSays(["all of them", "every time", "all occurrences", "the whole series", "every week", "all future"])
        let when = Self.describe(event.start, allDay: event.isAllDay, now: now)
        let token = PendingActions.park {
            try await writer.delete(event, allOccurrences: all)
            guard !all else { return "Deleted every “\(event.title)”" }
            RecentUndo.record("Delete “\(event.title)”") {
                _ = try await writer.create(EventDraft(title: event.title, start: event.start, end: event.end, isAllDay: event.isAllDay))
                return "Put “\(event.title)” back"
            }
            return "Deleted “\(event.title)” · say “undo” to put it back"
        }
        let question = all ? "Delete every “\(event.title)”? This can't be undone" : "Delete “\(event.title)” \(when)?"
        let item = ResultItem(id: token, title: event.title, detail: when, symbol: "calendar")
        return ToolResult(question, items: [item], confirmation: token)
    }

    // MARK: Finding the event

    private enum Pick { case found(EditableEvent), ask(String) }

    /// The event meant by its name and/or time. Several: ask which.
    private func pick(_ arguments: CalendarEventArguments, writer: any CalendarWriting, now: Date) async throws -> Pick {
        // Only what identifies the event: never the new time of a move.
        let when = Self.when(arguments.when, now: now, fallback: false)
        let words = Self.titleWords(Self.said(arguments.title) ?? "")
        guard when != nil || !words.isEmpty else { return .ask("Which event?") }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let from: Date, to: Date
        if let when, when.hasDay {
            from = calendar.startOfDay(for: when.date)
            to = calendar.date(byAdding: .day, value: 1, to: from)!
        } else if when != nil {
            // "my 3 o'clock": today or the coming week, morning or afternoon.
            from = today
            to = calendar.date(byAdding: .day, value: 7, to: today)!
        } else {
            from = now.addingTimeInterval(-12 * 3600)
            to = now.addingTimeInterval(30 * 86_400)
        }
        let time = when?.hasTime == true ? when?.date : nil
        let found = Self.matching(try await writer.editableEvents(from: from, to: to), words: words, at: time, eitherHalfOfDay: when?.hasDay == false)
        switch found.count {
        case 0:
            let what = arguments.title.map { "“\($0)”" } ?? "an event"
            throw ToolError("I couldn't find \(what)\(when.map { " " + Self.describe($0.date, allDay: !$0.hasTime, now: now) } ?? " in the next month")")
        case 1:
            return .found(found[0])
        default:
            let options = found.prefix(3).map { "\($0.title) \(Self.describe($0.start, allDay: $0.isAllDay, now: now))" }
            return .ask("Which one: " + options.joined(separator: ", or ") + "?")
        }
    }

    /// Events whose title has the spoken words, at the spoken time.
    static func matching(_ events: [EditableEvent], words: [String], at time: Date?, eitherHalfOfDay: Bool = false) -> [EditableEvent] {
        var candidates = events
        if let time {
            let calendar = Calendar.current
            let wanted = calendar.dateComponents([.hour, .minute], from: time)
            candidates = candidates.filter { event in
                guard !event.isAllDay else { return false }
                let clock = calendar.dateComponents([.hour, .minute], from: event.start)
                guard clock.minute == wanted.minute, let hour = clock.hour, let wantedHour = wanted.hour else { return false }
                return eitherHalfOfDay ? hour % 12 == wantedHour % 12 : hour == wantedHour
            }
        }
        if !words.isEmpty {
            let all = candidates.filter { event in
                let title = Set(titleWords(event.title))
                return words.allSatisfy { word in title.contains(word) || title.contains { $0.hasPrefix(word) || word.hasPrefix($0) } }
            }
            candidates = all
        }
        // One series, several days: the next occurrence.
        var seen = Set<String>()
        return candidates.sorted { $0.start < $1.start }.filter { event in
            guard let series = event.seriesID else { return true }
            return seen.insert(series).inserted
        }
    }

    private static let genericWords: Set<String> = [
        "my", "the", "a", "an", "appointment", "meeting", "event", "calendar", "with", "on", "at", "in", "for", "to", "one", "and", "of",
    ]

    static func titleWords(_ text: String) -> [String] {
        AppNameMatcher.normalize(text).split(separator: " ").map(String.init).filter { !genericWords.contains($0) }
    }

    private static func checkEditable(_ event: EditableEvent) throws {
        if event.hasAttendees {
            throw ToolError("“\(event.title)” has other people invited. Change it in your calendar app, so they're told properly")
        }
    }

    // MARK: Spoken values

    /// The model's value if the user said it (word for word, ignoring order).
    private static func said(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        guard let transcript = CommandContext.transcript else { return value }
        return Set(SpokenWords(value).lower).isSubset(of: SpokenWords(transcript).lower) ? value : nil
    }

    /// A time for an appointment. Without am/pm, 1–7 means afternoon or
    /// evening and 8–12 morning or noon ("lunch at 1", "standup at 10");
    /// `day` nil means the next time that comes round.
    static func daytime(_ when: SpokenWhen, said: String, day: Date?, now: Date) -> Date {
        let calendar = Calendar.current
        let words = Set(SpokenWords(said).lower)
        let explicit = !words.isDisjoint(with: ["am", "pm", "morning", "afternoon", "evening", "night", "tonight", "noon", "midnight", "midday"])
        guard !explicit, when.hasTime else { return when.date }
        // The hour as said: parsing with a day keeps it unchanged.
        let parsed = [SpokenWhen.parse("tomorrow " + said, now: now), SpokenWhen.parse("tomorrow at " + said, now: now)]
        let asSaid = parsed.compactMap { $0 }.first(where: \.hasTime)?.date ?? when.date
        var clock = calendar.dateComponents([.hour, .minute], from: asSaid)
        if let hour = clock.hour, (1...7).contains(hour) { clock.hour = hour + 12 }
        let base = day ?? now
        var date = calendar.date(bySettingHour: clock.hour ?? 0, minute: clock.minute ?? 0, second: 0, of: base) ?? when.date
        if day == nil, date <= now { date = calendar.date(byAdding: .day, value: 1, to: date) ?? date }
        return date
    }

    /// When the event is: the model's time if the user said it, else (with
    /// `fallback`) the one time in what they said.
    private static func when(_ spoken: String?, now: Date, fallback: Bool) -> SpokenWhen? {
        let transcript = CommandContext.transcript
        if let spoken, let when = SpokenWhen.parse(spoken, now: now) ?? SpokenWhen.parse("at " + spoken, now: now) {
            guard let transcript else { return when }
            if Grounding.mentions(spoken, in: transcript) || (when.hasTime && SpokenWhen.wasSaid(when.date, in: transcript)) || !when.hasTime {
                return when
            }
        }
        guard fallback, spoken == nil, let transcript, SpokenWhen.clockTimes(in: transcript).count <= 1 else { return nil }
        return SpokenWhen.parse(transcript, now: now)
    }

    /// "to 4", "Friday", "tomorrow at 9": a bare number is a time.
    private static func parseTarget(_ text: String, now: Date) -> SpokenWhen? {
        let cleaned = text.replacingOccurrences(of: #"^\s*(to|till|until)\s+"#, with: "", options: .regularExpression)
        return SpokenWhen.parse(cleaned, now: now) ?? SpokenWhen.parse("at " + cleaned, now: now)
    }

    private static func duration(_ spoken: String?) -> TimeInterval? {
        guard let spoken, let seconds = SpokenDuration.parse(spoken) else { return nil }
        guard let transcript = CommandContext.transcript else { return seconds }
        return SpokenDuration.all(in: transcript).contains(seconds) ? seconds : nil
    }

    private static func transcriptSays(_ phrases: [String]) -> Bool {
        guard let transcript = CommandContext.transcript else { return false }
        let text = " " + AppNameMatcher.normalize(transcript) + " "
        return phrases.contains { text.contains(" " + AppNameMatcher.normalize($0) + " ") }
    }

    /// "lunch with Sam" → "Lunch with Sam"; "an event dentist" → "Dentist".
    static func tidyTitle(_ title: String) -> String {
        var words = title.split(separator: " ").map(String.init)
        if words.count > 1 { words.removeAll { ["event", "calendar"].contains($0.lowercased()) } }
        while let first = words.first, ["a", "an", "the", "my", "new"].contains(first.lowercased()) { words.removeFirst() }
        let text = words.joined(separator: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// "tomorrow at 1:00 PM", "on Friday (all day)".
    static func describe(_ date: Date, allDay: Bool, now: Date) -> String {
        let text = ClockFormat.when(date, now: now, hasTime: !allDay)
        if allDay { return (["today", "tomorrow"].contains(text) ? text : "on \(text)") + " (all day)" }
        return text.first?.isNumber == true ? "at \(text)" : text
    }

    // MARK: Direct phrasings

    private static let otherTools: Set<String> = [
        "timer", "timers", "alarm", "alarms", "stopwatch", "remind", "reminder", "reminders", "note", "notes", "clipboard", "window",
        "task", "tasks", "todo", "playlist", "song", "spotify", "folder", "file", "files", "screenshot", "document", "documents", "downloads",
    ]
    private static let nouns: Set<String> = ["appointment", "meeting", "event", "calendar", "lunch", "dinner", "breakfast", "call", "session", "class", "lecture"]

    /// "add lunch with Sam tomorrow at 1", "schedule a meeting on Friday at
    /// 3 for 30 minutes", "move my dentist appointment to Monday", "push
    /// standup to 10", "cancel my 3 o'clock", "delete lunch with Sam".
    func directArguments(for command: DirectCommand) -> CalendarEventArguments? {
        let words = SpokenWords(command.original)
        let w = words.lower
        guard let first = w.first, !words.containsAny(Self.otherTools) else { return nil }
        let hasNoun = words.containsAny(Self.nouns)
        let now = Date()

        switch first {
        case "add", "create", "schedule", "book", "put", "set":
            // "set up a meeting…"; "put lunch in my calendar…".
            var taken = Set<Int>([0])
            if first == "set" { guard w.count > 1, w[1] == "up" else { return nil }; taken.insert(1) }
            let duration = Self.durationRange(in: words)
            if let duration { taken.formUnion(duration) }
            let when = SpokenWhen.find(in: words, now: now, calendar: .current)
            if let when { taken.formUnion(when.consumed) }
            guard hasNoun || when != nil else { return nil }
            // "…to my calendar", "…in my calendar", "…on my calendar".
            for (index, word) in w.enumerated() where word == "calendar" {
                taken.insert(index)
                if index > 0, w[index - 1] == "my" { taken.insert(index - 1) }
                if index > 1, ["to", "in", "on", "into"].contains(w[index - 2]) { taken.insert(index - 2) }
            }
            let rest = (0..<w.count).filter { !taken.contains($0) }
            let title = words.text(rest)
            return CalendarEventArguments(action: "add", title: title.isEmpty ? nil : title,
                                          when: when.map { words.text($0.consumed) }, newWhen: nil,
                                          duration: duration.map { words.text($0) })
        case "move", "reschedule", "push", "shift", "change", "postpone", "bring", "make":
            // Split at the last "to": the event before it, the new time after.
            let split = w.lastIndex(where: { ["to", "till", "until"].contains($0) })
            let head = split.map { Array(1..<$0) } ?? Array(1..<w.count)
            let tail = split.map { Array(($0 + 1)..<w.count) } ?? []
            let newText = words.text(tail)
            // "for 30 minutes", or "make standup 30 minutes".
            let duration = Self.durationRange(in: words)
                ?? (first == "make" ? SpokenDuration.find(in: words).map { $0.range.lowerBound...($0.range.upperBound - 1) } : nil)
            let newWhen = tail.isEmpty ? nil : Self.parseTarget(newText, now: now)
            // "change" and "bring" are too general without an event word
            // ("change brightness to 5").
            if ["change", "bring"].contains(first), !hasNoun { return nil }
            guard newWhen != nil || duration != nil || (hasNoun && first != "make") else { return nil }
            if first == "make", duration == nil { return nil }
            let headWords = SpokenWords(words.text(head))
            let when = SpokenWhen.find(in: headWords, now: now, calendar: .current)
            var titleIndices = Array(headWords.lower.indices)
            if let when { titleIndices.removeAll { when.consumed.contains($0) } }
            if let range = Self.durationRange(in: headWords) { titleIndices.removeAll { range.contains($0) } }
            let title = headWords.text(titleIndices)
            return CalendarEventArguments(action: "move", title: Self.titleWords(title).isEmpty ? nil : title,
                                          when: when.map { headWords.text($0.consumed) },
                                          newWhen: newWhen == nil ? nil : newText, duration: duration.map { words.text($0) })
        case "cancel", "delete", "remove", "clear", "drop":
            let rest = SpokenWords(words.text(1..<w.count))
            let when = SpokenWhen.find(in: rest, now: now, calendar: .current)
            // "cancel my 3 o'clock" needs no noun; otherwise it must be an event.
            guard hasNoun || when != nil else { return nil }
            var indices = Array(rest.lower.indices)
            if let when { indices.removeAll { when.consumed.contains($0) } }
            let title = rest.text(indices)
            return CalendarEventArguments(action: "delete", title: Self.titleWords(title).isEmpty ? nil : title,
                                          when: when.map { rest.text($0.consumed) }, newWhen: nil, duration: nil)
        default:
            return nil
        }
    }

    /// "for an hour", "for 30 minutes": a duration after "for".
    static func durationRange(in words: SpokenWords) -> ClosedRange<Int>? {
        for (index, word) in words.lower.enumerated() where word == "for" {
            if let (_, range) = SpokenDuration.duration(in: words, at: index + 1) {
                return index...(range.upperBound - 1)
            }
        }
        return nil
    }
}
