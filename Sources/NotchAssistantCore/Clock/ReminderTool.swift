import Foundation
import FoundationModels

@Generable
struct ReminderArguments: Sendable {
    @Guide(description: "What to be reminded of, in the user's words, e.g. \"call Mum\"")
    var task: String
    @Guide(description: "When, as the user said it, e.g. \"at 6\", \"tomorrow\" or \"in 20 minutes\"")
    var when: String?
}

/// Adds a reminder or task to Apple Reminders or Google Tasks (Settings ›
/// Calendar), so it syncs to the user's other devices.
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
    var store: (any TaskStore)?
    var clock: ClockStore = .shared
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
        let provider = TaskProvider.current
        let store = store ?? provider.store
        let id = try await store.add(title: title, due: when)
        // Google Tasks can't alert at a time: Alfred rings it itself.
        let ring = when.flatMap { $0.hasTime && !store.keepsTimes ? clock.addReminder(title, at: $0.date) : nil }
        RecentUndo.record("Add “\(title)”") {
            try await store.delete(id)
            if let ring { self.clock.remove([ring.id]) }
            return "Removed “\(title)”"
        }
        guard let when else { return ToolResult("Added “\(title)” to \(provider.title)", undoable: true) }
        return ToolResult("I'll remind you to \(task) \(Self.phrase(when, now: now))", undoable: true)
    }

    /// "at 6:00 PM", "tomorrow at 9:00 AM", "tomorrow".
    static func phrase(_ when: SpokenWhen, now: Date) -> String {
        let text = ClockFormat.when(when.date, now: now, hasTime: when.hasTime)
        return text.first?.isNumber == true ? "at \(text)" : (when.hasTime || text == "today" || text == "tomorrow" ? text : "on \(text)")
    }

    private static let starts = [
        "remind me", "set a reminder", "set reminder", "add a reminder", "create a reminder", "make a reminder",
        "new reminder", "reminder", "add a task", "create a task", "new task", "add a to do", "add task",
    ]

    /// "add milk to my to-do list", "put call the bank on my tasks".
    private static let listPhrase = try! NSRegularExpression(
        pattern: #"^\s*(?:please\s+)?(?:add|put)\s+(.+?)\s+(?:to|on|in)\s+(?:my\s+|the\s+)?(?:to-?\s?do|todo|tasks?|reminders)(?:\s+list)?\s*[.!]?\s*$"#,
        options: [.caseInsensitive]
    )

    /// "remind me to call Mum at 6", "remind me in 20 minutes to check the
    /// oven", "remind me tomorrow to buy milk", "set a reminder to …".
    func directArguments(for command: DirectCommand) -> ReminderArguments? {
        let original = command.original
        if let match = Self.listPhrase.firstMatch(in: original, range: NSRange(original.startIndex..., in: original)),
           let range = Range(match.range(at: 1), in: original) {
            let words = SpokenWords(String(original[range]))
            let when = SpokenWhen.find(in: words, now: Date(), calendar: .current)
            let rest = (0..<words.count).filter { !(when?.consumed.contains($0) ?? false) }
            guard !rest.isEmpty else { return nil }
            return ReminderArguments(task: words.text(rest), when: when.map { words.text($0.consumed) })
        }
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
