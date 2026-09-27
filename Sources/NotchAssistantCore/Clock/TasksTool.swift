import Foundation
import FoundationModels

@Generable
struct TasksArguments: Sendable {
    @Guide(description: "What to do", .anyOf(["list", "complete", "delete"]))
    var action: String
    @Guide(description: "Which task, in the user's words, e.g. \"buy milk\"")
    var task: String?
}

/// Open tasks in Apple Reminders or Google Tasks: read them out, tick one
/// off (undoable), or delete one (after a "yes"). Adding is `reminder`.
struct TasksTool: AssistantTool {
    let name = "tasks"
    let title = "Tasks"
    let symbol = "checklist.checked"
    let keywords: Set<String> = ["tasks", "task", "todo", "to-do", "reminders", "done", "finished", "complete", "tick", "check"]
    let description = """
        The user's tasks and reminders. "what's on my to-do list" → list. "mark buy milk as done" → complete, task "buy milk". \
        "delete the dentist reminder" → delete, task "dentist".
        """
    let requiresNetwork = false
    let permission = ToolPermission.reminders
    let reversibility = Reversibility.reversible

    var store: (any TaskStore)?

    func target(of arguments: TasksArguments) -> String {
        arguments.task ?? "Tasks"
    }

    func execute(_ arguments: TasksArguments) async throws -> ToolResult {
        let provider = TaskProvider.current
        let store = store ?? provider.store
        let tasks = try await store.openTasks()
        let now = Date()
        if arguments.action == "list" {
            guard !tasks.isEmpty else { return ToolResult("Nothing on your list in \(provider.title)", isAnswer: true) }
            let sorted = tasks.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            let named = sorted.prefix(5).map { task in
                task.due.map { "\(task.title), \(ClockFormat.when($0, now: now, hasTime: task.hasTime))" } ?? task.title
            }
            let more = tasks.count > 5 ? ", and \(tasks.count - 5) more" : ""
            return ToolResult("You have \(tasks.count) task\(tasks.count == 1 ? "" : "s"): " + named.joined(separator: "; ") + more, isAnswer: true)
        }

        let words = CalendarEventTool.titleWords(arguments.task ?? "").filter { !["task", "reminder", "list", "todo", "do"].contains($0) }
        guard !words.isEmpty else { return .ask("Which task?") }
        let matches = tasks.filter { task in
            let title = Set(CalendarEventTool.titleWords(task.title))
            return words.allSatisfy { word in title.contains { $0.hasPrefix(word) || word.hasPrefix($0) } }
        }
        guard let task = matches.first else { throw ToolError("I couldn't find “\(arguments.task ?? "")” in \(provider.title)") }
        guard matches.count == 1 else {
            return .ask("Which one: " + matches.prefix(3).map(\.title).joined(separator: ", or ") + "?")
        }

        if arguments.action == "complete" {
            try await store.setCompleted(task.id, true)
            RecentUndo.record("Complete “\(task.title)”") {
                try await store.setCompleted(task.id, false)
                return "“\(task.title)” is back on your list"
            }
            return ToolResult("Ticked off “\(task.title)” · say “undo” to bring it back", undoable: true)
        }
        let token = PendingActions.park {
            try await store.delete(task.id)
            RecentUndo.record("Delete “\(task.title)”") {
                _ = try await store.add(title: task.title, due: task.due.map { SpokenWhen(date: $0, hasTime: task.hasTime, consumed: []) })
                return "Put “\(task.title)” back"
            }
            return "Deleted “\(task.title)” · say “undo” to put it back"
        }
        let item = ResultItem(id: token, title: task.title, detail: task.due.map { ClockFormat.when($0, now: now, hasTime: task.hasTime) } ?? provider.title, symbol: "checklist")
        return ToolResult("Delete “\(task.title)”?", items: [item], confirmation: token)
    }

    private static let listQuestions = [
        "what are my tasks", "what s on my to do list", "whats on my to do list", "what s on my todo list", "what do i have to do",
        "what are my reminders", "what reminders do i have", "show my tasks", "read my tasks", "read my to do list", "my tasks",
        "what s on my list", "what tasks do i have", "list my tasks", "what s left on my to do list",
    ]

    private static let completing = try! NSRegularExpression(
        pattern: #"^(?:mark|tick off|check off|cross off|complete|i finished|i ve finished|i have finished|i did|done with)\s+(?:the\s+)?(.+?)(?:\s+(?:as\s+)?(?:done|complete|completed|finished|off))?(?:\s+(?:task|reminder))?$"#
    )
    private static let deleting = try! NSRegularExpression(
        pattern: #"^(?:delete|remove|clear)\s+(?:the\s+|my\s+)?(.+?)\s+(?:task|reminder|from my (?:to do list|todo list|tasks|reminders|list))$"#
    )

    func directArguments(for command: DirectCommand) -> TasksArguments? {
        let text = command.text.replacingOccurrences(of: "to-do", with: "to do")
        if Self.listQuestions.contains(text) { return TasksArguments(action: "list", task: nil) }
        let range = NSRange(text.startIndex..., in: text)
        if let match = Self.deleting.firstMatch(in: text, range: range), let task = Range(match.range(at: 1), in: text) {
            return TasksArguments(action: "delete", task: String(text[task]))
        }
        if let match = Self.completing.firstMatch(in: text, range: range), let task = Range(match.range(at: 1), in: text) {
            // "mark … as done" needs the "done"; "tick off …" doesn't.
            if text.hasPrefix("mark"), !["done", "complete", "completed", "finished"].contains(where: text.hasSuffix) { return nil }
            return TasksArguments(action: "complete", task: String(text[task]))
        }
        return nil
    }
}
