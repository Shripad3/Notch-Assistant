import EventKit
import Foundation

/// An event that may be changed, with what's needed to find it again.
struct EditableEvent: Sendable, Equatable {
    /// The event, or this occurrence of a repeating one.
    let id: String
    /// Google: the calendar it's in. Apple: nil.
    let calendarID: String?
    /// The repeating series it belongs to, if any.
    let seriesID: String?
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    /// Other people are invited: changing it would notify them.
    let hasAttendees: Bool
    var isRecurring: Bool { seriesID != nil }
}

struct EventDraft: Sendable, Equatable {
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
}

/// Adding, moving and deleting events. Only calendars the user can edit are
/// searched.
protocol CalendarWriting: Sendable {
    func editableEvents(from start: Date, to end: Date) async throws -> [EditableEvent]
    func create(_ draft: EventDraft) async throws -> EditableEvent
    /// Moves this occurrence only.
    func update(_ event: EditableEvent, start: Date, end: Date) async throws
    func delete(_ event: EditableEvent, allOccurrences: Bool) async throws
}

extension CalendarProvider {
    /// Nil for Outlook: it stays read-only.
    var writer: (any CalendarWriting)? {
        switch self {
        case .apple: AppleCalendar()
        case .google: GoogleCalendar()
        case .outlook: nil
        }
    }
}

// MARK: - Apple Calendar

extension AppleCalendar: CalendarWriting {
    private func store() async throws -> EKEventStore {
        let store = EKEventStore()
        guard (try? await store.requestFullAccessToEvents()) == true else {
            throw AssistantFailure("Calendar access is off for Notch Assistant", link: .calendars)
        }
        return store
    }

    func editableEvents(from start: Date, to end: Date) async throws -> [EditableEvent] {
        let store = try await store()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { $0.calendar.allowsContentModifications }
            .map(Self.editable)
    }

    func create(_ draft: EventDraft) async throws -> EditableEvent {
        let store = try await store()
        guard let calendar = store.defaultCalendarForNewEvents else { throw ToolError("There's no calendar to add events to") }
        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.startDate = draft.start
        event.endDate = draft.end
        event.isAllDay = draft.isAllDay
        event.calendar = calendar
        try store.save(event, span: .thisEvent, commit: true)
        return Self.editable(event)
    }

    func update(_ event: EditableEvent, start: Date, end: Date) async throws {
        let store = try await store()
        let found = try occurrence(of: event, in: store)
        found.startDate = start
        found.endDate = end
        try store.save(found, span: .thisEvent, commit: true)
    }

    func delete(_ event: EditableEvent, allOccurrences: Bool) async throws {
        let store = try await store()
        if allOccurrences, let series = store.event(withIdentifier: event.id) {
            // The first occurrence with "future events" removes the series.
            try store.remove(series, span: .futureEvents, commit: true)
        } else {
            try store.remove(try occurrence(of: event, in: store), span: .thisEvent, commit: true)
        }
    }

    private func occurrence(of event: EditableEvent, in store: EKEventStore) throws -> EKEvent {
        let predicate = store.predicateForEvents(withStart: event.start.addingTimeInterval(-60), end: event.end.addingTimeInterval(60), calendars: nil)
        guard let found = store.events(matching: predicate).first(where: { $0.eventIdentifier == event.id && abs($0.startDate.timeIntervalSince(event.start)) < 1 }) else {
            throw ToolError("That event has changed or gone; ask again")
        }
        return found
    }

    private static func editable(_ event: EKEvent) -> EditableEvent {
        EditableEvent(
            id: event.eventIdentifier ?? "",
            calendarID: nil,
            seriesID: event.hasRecurrenceRules ? event.eventIdentifier : nil,
            title: event.title ?? "Untitled",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            hasAttendees: !(event.attendees ?? []).filter { !$0.isCurrentUser }.isEmpty
        )
    }
}

// MARK: - Google Calendar

extension GoogleCalendar: CalendarWriting {
    private static let base = "https://www.googleapis.com/calendar/v3/calendars/"

    func editableEvents(from start: Date, to end: Date) async throws -> [EditableEvent] {
        let list = try await Self.session.get(URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList?minAccessRole=writer")!)
        let calendars = try Self.selectedCalendars(in: list)
        return try await withThrowingTaskGroup(of: [EditableEvent].self) { group in
            for calendar in calendars {
                group.addTask {
                    var components = URLComponents(string: Self.base + Self.encode(calendar) + "/events")!
                    let iso = ISO8601DateFormatter()
                    components.queryItems = [
                        .init(name: "timeMin", value: iso.string(from: start)),
                        .init(name: "timeMax", value: iso.string(from: end)),
                        .init(name: "singleEvents", value: "true"),
                        .init(name: "orderBy", value: "startTime"),
                        .init(name: "maxResults", value: "250"),
                    ]
                    return try Self.editableEvents(in: try await Self.session.get(components.url!), calendar: calendar)
                }
            }
            var all: [EditableEvent] = []
            for try await events in group { all += events }
            return all
        }
    }

    func create(_ draft: EventDraft) async throws -> EditableEvent {
        let body: [String: Any] = ["summary": draft.title, "start": Self.moment(draft.start, allDay: draft.isAllDay), "end": Self.moment(draft.end, allDay: draft.isAllDay)]
        let data = try await Self.session.request("POST", URL(string: Self.base + "primary/events")!, json: body)
        struct Created: Decodable { let id: String }
        let created = try JSONDecoder().decode(Created.self, from: data)
        return EditableEvent(id: created.id, calendarID: "primary", seriesID: nil, title: draft.title, start: draft.start, end: draft.end,
                             isAllDay: draft.isAllDay, hasAttendees: false)
    }

    func update(_ event: EditableEvent, start: Date, end: Date) async throws {
        let body: [String: Any] = ["start": Self.moment(start, allDay: event.isAllDay), "end": Self.moment(end, allDay: event.isAllDay)]
        _ = try await Self.session.request("PATCH", eventURL(event.id, in: event.calendarID), json: body)
    }

    func delete(_ event: EditableEvent, allOccurrences: Bool) async throws {
        let id = allOccurrences ? (event.seriesID ?? event.id) : event.id
        _ = try await Self.session.request("DELETE", eventURL(id, in: event.calendarID))
    }

    private func eventURL(_ id: String, in calendar: String?) -> URL {
        URL(string: Self.base + Self.encode(calendar ?? "primary") + "/events/" + Self.encode(id))!
    }

    static func encode(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/", "@", "#"])) ?? id
    }

    /// {"dateTime": …, "timeZone": …} or {"date": "2026-09-28"}.
    static func moment(_ date: Date, allDay: Bool) -> [String: String] {
        if allDay {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return ["date": formatter.string(from: date)]
        }
        return ["dateTime": ISO8601DateFormatter().string(from: date), "timeZone": TimeZone.current.identifier]
    }

    static func editableEvents(in data: Data, calendar: String) throws -> [EditableEvent] {
        struct Page: Decodable {
            struct Item: Decodable {
                struct Moment: Decodable { let dateTime: String?; let date: String? }
                struct Attendee: Decodable { let `self`: Bool? }
                let id: String
                let summary: String?
                let status: String?
                let start: Moment?
                let end: Moment?
                let recurringEventId: String?
                let attendees: [Attendee]?
            }
            let items: [Item]?
        }
        let iso = ISO8601DateFormatter()
        return try JSONDecoder().decode(Page.self, from: data).items?.compactMap { item in
            guard item.status != "cancelled", let s = item.start, let e = item.end else { return nil }
            let others = (item.attendees ?? []).contains { $0.`self` != true }
            let timed = s.dateTime.flatMap(iso.date(from:)).flatMap { start in e.dateTime.flatMap(iso.date(from:)).map { (start, $0) } }
            let allDay = s.date.flatMap(localDay).flatMap { start in e.date.flatMap(localDay).map { (start, $0) } }
            guard let (start, end) = timed ?? allDay else { return nil }
            return EditableEvent(id: item.id, calendarID: calendar, seriesID: item.recurringEventId, title: item.summary ?? "Untitled",
                                 start: start, end: end, isAllDay: timed == nil, hasAttendees: others)
        } ?? []
    }
}
