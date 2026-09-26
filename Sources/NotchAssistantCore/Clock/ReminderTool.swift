import EventKit
import Foundation
import FoundationModels

@Generable
struct ReminderArguments: Sendable {
    @Guide(description: "What to be reminded of, in the user's words, e.g. \"call Mum\"")
    var task: String
    @Guide(description: "When, as the user said it, e.g. \"at 6\", \"tomorrow\" or \"in 20 minutes\"")
    var when: String?
}

/// Adds a reminder to the Reminders app, so it syncs to the user's other
/// devices and alerts even when this app isn't running.
struct ReminderTool: AssistantTool {
    let name = "reminder"
    let title = "Reminder"
    let symbol = "checklist"
    let keywords: Set<String> = ["remind", "reminder", "reminders"]
    let description = """
        Add a reminder. "remind me to call Mum at 6" → task "call Mum", when "at 6". \
        "remind me tomorrow to buy milk" → task "buy milk", when "tomorrow".
        """
    let requiresNetwork = false
    let permission = ToolPermission.reminders
    let reversibility = Reversibility.notApplicable

    func target(of arguments: ReminderArguments) -> String {
        [arguments.task, arguments.when].compactMap { $0 }.joined(separator: " · ")
    }

    func execute(_ arguments: ReminderArguments) async throws -> ToolResult {
        let task = arguments.task.trimmingCharacters(in: .whitespaces)
        // Every word must have been said; the time may sit in the middle
        // ("remind me to call Mum at 6 about the car").
        if let transcript = CommandContext.transcript, task.isEmpty || !Set(SpokenWords(task).lower).isSubset(of: SpokenWords(transcript).lower) {
            throw ToolError("What should I remind you about?")
        }
        let now = Date()
        let when = ClockPhrases.grounded(arguments.when).flatMap { SpokenWhen.parse($0, now: now) }
        if let when, when.hasTime, when.date <= now {
            throw ToolError("That time has already passed")
        }
        let title = task.prefix(1).uppercased() + task.dropFirst()
        try await Self.add(title: title, when: when)
        guard let when else { return ToolResult("Added “\(title)” to Reminders") }
        return ToolResult("I'll remind you to \(task) \(Self.phrase(when, now: now))")
    }

    /// "at 6:00 PM", "tomorrow at 9:00 AM", "tomorrow".
    static func phrase(_ when: SpokenWhen, now: Date) -> String {
        let text = ClockFormat.when(when.date, now: now, hasTime: when.hasTime)
        return text.first?.isNumber == true ? "at \(text)" : (when.hasTime || text == "today" || text == "tomorrow" ? text : "on \(text)")
    }

    private static func add(title: String, when: SpokenWhen?) async throws {
        let store = EKEventStore()
        let allowed: Bool
        do {
            allowed = try await store.requestFullAccessToReminders()
        } catch {
            allowed = false
        }
        guard allowed else {
            throw AssistantFailure("Reminders access is off for Notch Assistant", link: .reminders)
        }
        guard let calendar = store.defaultCalendarForNewReminders() else {
            throw ToolError("There's no Reminders list to add to")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = calendar
        if let when {
            let components: Set<Calendar.Component> = when.hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
            reminder.dueDateComponents = Calendar.current.dateComponents(components, from: when.date)
            // A timed reminder needs an alarm to actually alert.
            if when.hasTime { reminder.addAlarm(EKAlarm(absoluteDate: when.date)) }
        }
        try store.save(reminder, commit: true)
    }

    private static let starts = [
        "remind me", "set a reminder", "set reminder", "add a reminder", "create a reminder", "make a reminder",
        "new reminder", "reminder",
    ]

    /// "remind me to call Mum at 6", "remind me in 20 minutes to check the
    /// oven", "remind me tomorrow to buy milk", "set a reminder to …".
    func directArguments(for command: DirectCommand) -> ReminderArguments? {
        guard let start = Self.starts.first(where: { command.text == $0 || command.text.hasPrefix($0 + " ") }) else { return nil }
        let words = SpokenWords(command.original)
        // Skip the words of the opening phrase, found in the original text.
        var index = 0
        var matched = 0
        let startWords = start.split(separator: " ").map(String.init)
        while index < words.count, matched < startWords.count {
            if words.lower[index] == startWords[matched] { matched += 1 }
            index += 1
        }
        let when = SpokenWhen.find(in: words, now: Date(), calendar: .current, from: index)
        let taken = when?.consumed ?? []
        var rest = (index..<words.count).filter { !taken.contains($0) }
        // "to call Mum", "about the meeting", "that I need to call Mum".
        while let first = rest.first, ["to", "that", "about", "please"].contains(words.lower[first]) {
            rest.removeFirst()
        }
        let opening = rest.prefix(3).map { words.lower[$0] }
        if opening.count == 3, opening[0] == "i", ["need", "have", "want"].contains(opening[1]), opening[2] == "to" {
            rest.removeFirst(3)
        }
        while let last = rest.last, ["to", "at", "on", "in", "by", "please"].contains(words.lower[last]) {
            rest.removeLast()
        }
        guard !rest.isEmpty else { return nil }
        return ReminderArguments(task: words.text(rest), when: when.map { words.text($0.consumed) })
    }
}
