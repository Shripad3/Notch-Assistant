import EventKit
import Foundation

/// Where tasks and reminders go: Apple Reminders or Google Tasks.
public enum TaskProvider: String, CaseIterable, Sendable {
    case apple, google

    public static let defaultsKey = "tasks.provider"

    public static var current: TaskProvider {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(TaskProvider.init(rawValue:)) ?? .apple
    }

    public var title: String {
        switch self {
        case .apple: "Apple Reminders"
        case .google: "Google Tasks"
        }
    }

    var store: any TaskStore {
        switch self {
        case .apple: AppleReminders()
        case .google: GoogleTasks()
        }
    }
}

/// An open task, with what's needed to find it again.
struct OpenTask: Sendable, Equatable {
    let id: String
    let title: String
    /// Due date; `hasTime` false for a date only.
    let due: Date?
    let hasTime: Bool
}

protocol TaskStore: Sendable {
    /// Returns the new task's id.
    func add(title: String, due: SpokenWhen?) async throws -> String
    func openTasks() async throws -> [OpenTask]
    func setCompleted(_ id: String, _ completed: Bool) async throws
    func delete(_ id: String) async throws
    /// True when due times alert by themselves (Reminders); Google Tasks
    /// keeps dates only, so Alfred rings timed ones itself.
    var keepsTimes: Bool { get }
}

// MARK: - Apple Reminders

struct AppleReminders: TaskStore {
    let keepsTimes = true

    private func store() async throws -> EKEventStore {
        let store = EKEventStore()
        guard (try? await store.requestFullAccessToReminders()) == true else {
            throw AssistantFailure("Reminders access is off for Notch Assistant", link: .reminders)
        }
        return store
    }

    func add(title: String, due: SpokenWhen?) async throws -> String {
        let store = try await store()
        guard let calendar = store.defaultCalendarForNewReminders() else { throw ToolError("There's no Reminders list to add to") }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = calendar
        if let due {
            let parts: Set<Calendar.Component> = due.hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
            reminder.dueDateComponents = Calendar.current.dateComponents(parts, from: due.date)
            // A timed reminder needs an alarm to actually alert.
            if due.hasTime { reminder.addAlarm(EKAlarm(absoluteDate: due.date)) }
        }
        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    func openTasks() async throws -> [OpenTask] {
        let store = try await store()
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let tasks = (reminders ?? []).map { reminder in
                    let components = reminder.dueDateComponents
                    return OpenTask(id: reminder.calendarItemIdentifier, title: reminder.title ?? "Untitled",
                                    due: components.flatMap { Calendar.current.date(from: $0) }, hasTime: components?.hour != nil)
                }
                continuation.resume(returning: tasks)
            }
        }
    }

    func setCompleted(_ id: String, _ completed: Bool) async throws {
        let store = try await store()
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { throw ToolError("That reminder has gone") }
        reminder.isCompleted = completed
        try store.save(reminder, commit: true)
    }

    func delete(_ id: String) async throws {
        let store = try await store()
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { throw ToolError("That reminder has gone") }
        try store.remove(reminder, commit: true)
    }
}

// MARK: - Google Tasks

/// Google Tasks, default list, through the Google sign-in in Settings ›
/// Calendar. The API stores due dates without times.
struct GoogleTasks: TaskStore {
    let keepsTimes = false
    private static let base = "https://tasks.googleapis.com/tasks/v1/lists/@default/tasks"

    private var session: OAuthSession {
        get throws {
            guard GoogleCalendar.session.isSignedIn else { throw ToolError("Sign in to Google under Settings › Calendar to use Google Tasks") }
            return GoogleCalendar.session
        }
    }

    func add(title: String, due: SpokenWhen?) async throws -> String {
        var body: [String: Any] = ["title": title]
        if let due { body["due"] = Self.dueString(due.date) }
        let data = try await session.request("POST", URL(string: Self.base)!, json: body)
        struct Created: Decodable { let id: String }
        return try JSONDecoder().decode(Created.self, from: data).id
    }

    func openTasks() async throws -> [OpenTask] {
        let data = try await session.get(URL(string: Self.base + "?showCompleted=false&maxResults=100")!)
        return try Self.tasks(in: data)
    }

    func setCompleted(_ id: String, _ completed: Bool) async throws {
        let body: [String: Any] = completed ? ["status": "completed"] : ["status": "needsAction", "completed": NSNull()]
        _ = try await session.request("PATCH", URL(string: Self.base + "/" + GoogleCalendar.encode(id))!, json: body)
    }

    func delete(_ id: String) async throws {
        _ = try await session.request("DELETE", URL(string: Self.base + "/" + GoogleCalendar.encode(id))!)
    }

    /// Google wants RFC 3339 at midnight UTC for the local calendar day.
    static func dueString(_ date: Date) -> String {
        let local = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02dT00:00:00.000Z", local.year ?? 2000, local.month ?? 1, local.day ?? 1)
    }

    static func tasks(in data: Data) throws -> [OpenTask] {
        struct Page: Decodable {
            struct Item: Decodable { let id: String; let title: String?; let due: String?; let status: String? }
            let items: [Item]?
        }
        return try JSONDecoder().decode(Page.self, from: data).items?.compactMap { item in
            guard item.status != "completed", let title = item.title, !title.isEmpty else { return nil }
            return OpenTask(id: item.id, title: title, due: item.due.map { String($0.prefix(10)) }.flatMap(localDay), hasTime: false)
        } ?? []
    }
}
