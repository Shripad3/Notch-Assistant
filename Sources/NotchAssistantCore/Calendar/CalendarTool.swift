import Foundation
import FoundationModels

@Generable
struct CalendarArguments: Sendable {
    @Guide(description: "What the user asked", .anyOf(["agenda", "next", "free"]))
    var action: String
    @Guide(description: "Which day or time, as the user said it, e.g. \"tomorrow\", \"on Friday\", \"at 3\"")
    var when: String?
}

/// Reads the connected calendar aloud: a day's events, the next event, or
/// whether a time is free. Read-only; event details stay on this Mac (and
/// the calendar provider).
struct CalendarTool: AssistantTool {
    let name = "calendar"
    let title = "Calendar"
    let symbol = "calendar"
    let keywords: Set<String> = ["calendar", "schedule", "agenda", "meeting", "meetings", "event", "events", "appointment", "appointments", "free", "busy"]
    let description = """
        Read the user's calendar. "what's on my calendar tomorrow" → agenda, when "tomorrow". \
        "when is my next meeting" → next. "am I free at 3" → free, when "at 3".
        """
    let requiresNetwork = false
    let permission = ToolPermission.calendar
    let reversibility = Reversibility.notApplicable

    var source: (any CalendarSource)?

    func target(of arguments: CalendarArguments) -> String {
        arguments.when ?? (arguments.action == "next" ? "Next event" : "Today")
    }

    func execute(_ arguments: CalendarArguments) async throws -> ToolResult {
        let source = source ?? CalendarProvider.current.source
        let now = Date()
        let calendar = Calendar.current
        let when = ClockPhrases.grounded(arguments.when).flatMap { SpokenWhen.parse($0, now: now) }
            ?? CommandContext.transcript.flatMap { SpokenWhen.parse($0, now: now) }

        switch arguments.action {
        case "next":
            let events = try await source.events(from: now, to: now.addingTimeInterval(14 * 86_400))
            guard let next = events.filter({ !$0.isAllDay && $0.start >= now }).min(by: { $0.start < $1.start }) else {
                return ToolResult("Nothing on your calendar in the next two weeks", isAnswer: true)
            }
            return ToolResult("Your next event is \(next.title), \(ClockFormat.when(next.start, now: now))", isAnswer: true)
        case "free":
            guard let when, when.hasTime else { throw ToolError("Free when? Say “am I free at 3”") }
            let slotEnd = when.date.addingTimeInterval(30 * 60)
            let events = try await source.events(from: when.date.addingTimeInterval(-86_400), to: slotEnd)
            let clashes = events.filter { !$0.isAllDay && $0.start < slotEnd && $0.end > when.date }
            let time = ClockFormat.when(when.date, now: now)
            guard !clashes.isEmpty else { return ToolResult("You're free \(Self.at(time))", isAnswer: true) }
            return ToolResult("You have \(Self.list(clashes.map(\.title))) \(Self.at(time))", isAnswer: true)
        default:
            let day = calendar.startOfDay(for: when?.date ?? now)
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: day)!
            let events = try await source.events(from: day, to: dayEnd).sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
            return ToolResult(Self.agenda(events, day: day, now: now), isAnswer: true)
        }
    }

    /// "You have 3 events today: Standup at 9:30 AM, …". At most five named.
    static func agenda(_ events: [CalendarEvent], day: Date, now: Date, calendar: Calendar = .current) -> String {
        let name = ClockFormat.when(day, now: now, hasTime: false)
        let dayName = ["today", "tomorrow"].contains(name) ? name : "on \(name)"
        guard !events.isEmpty else { return "Nothing on your calendar \(dayName)" }
        let described = events.prefix(5).map { event in
            event.isAllDay ? "\(event.title), all day" : "\(event.title) at \(event.start.formatted(date: .omitted, time: .shortened))"
        }
        let more = events.count > 5 ? ", and \(events.count - 5) more" : ""
        let count = events.count == 1 ? "1 event" : "\(events.count) events"
        return "You have \(count) \(dayName): \(described.joined(separator: ", "))\(more)"
    }

    private static func at(_ time: String) -> String {
        time.first?.isNumber == true ? "at \(time)" : time
    }

    private static func list(_ titles: [String]) -> String {
        titles.count == 1 ? titles[0] : titles.dropLast().joined(separator: ", ") + " and " + titles.last!
    }

    private static let nouns: Set<String> = ["calendar", "schedule", "agenda", "meeting", "meetings", "event", "events", "appointment", "appointments", "plans"]

    /// "what's on my calendar tomorrow", "what's my next meeting", "am I
    /// free at 3", "do I have any meetings on Friday".
    func directArguments(for command: DirectCommand) -> CalendarArguments? {
        guard !ClockPhrases.foreignVerbs.contains(command.verb) else { return nil }
        let words = SpokenWords(command.original)
        let text = command.text
        let asksFree = ["am i free", "am i busy", "do i have anything", "is my calendar free", "have i got anything"].contains { text.hasPrefix($0) }
        guard asksFree || words.containsAny(Self.nouns) else { return nil }
        // Something to do, not a question about the calendar.
        guard !words.containsAny(["add", "create", "schedule a", "book", "delete", "cancel", "move", "remind", "reminder"]) || asksFree else { return nil }
        guard asksFree || ["what", "whats", "when", "whens", "do", "have", "any", "is", "show", "read", "tell", "how"].contains(words.lower.first ?? "") || text.hasPrefix("my ") else {
            return nil
        }
        let when = SpokenWhen.find(in: words, now: Date(), calendar: .current).map { words.text($0.consumed) }
        if asksFree { return CalendarArguments(action: "free", when: when) }
        if words.containsAny(["next", "upcoming"]) { return CalendarArguments(action: "next", when: nil) }
        return CalendarArguments(action: "agenda", when: when)
    }
}
