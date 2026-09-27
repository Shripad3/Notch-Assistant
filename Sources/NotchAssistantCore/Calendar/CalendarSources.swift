import EventKit
import Foundation

/// One event, from whichever calendar is connected.
public struct CalendarEvent: Sendable, Equatable {
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool

    public init(title: String, start: Date, end: Date, isAllDay: Bool) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
    }
}

protocol CalendarSource: Sendable {
    func events(from start: Date, to end: Date) async throws -> [CalendarEvent]
}

/// Which calendar the assistant reads. One at a time; switching disconnects
/// the others. Read-only: nothing is ever created, changed or deleted.
public enum CalendarProvider: String, CaseIterable, Sendable {
    case apple, google, outlook

    public static let defaultsKey = "calendar.provider"

    public static var current: CalendarProvider {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(CalendarProvider.init(rawValue:)) ?? .apple
    }

    public var title: String {
        switch self {
        case .apple: "Apple Calendar"
        case .google: "Google Calendar"
        case .outlook: "Outlook"
        }
    }

    var source: any CalendarSource {
        switch self {
        case .apple: AppleCalendar()
        case .google: GoogleCalendar()
        case .outlook: OutlookCalendar()
        }
    }

    // Settings for Google and Outlook.
    public static let googleClientIDKey = GoogleCalendar.clientIDKey
    public static let outlookClientIDKey = OutlookCalendar.clientIDKey
    public static func setGoogleSecret(_ secret: String) { GoogleCalendar.setSecret(secret) }
    public static var hasGoogleSecret: Bool { GoogleCalendar.hasSecret }

    /// Asks for Calendar access (Apple Calendar). True when granted.
    public static func requestAppleAccess() async -> Bool {
        (try? await EKEventStore().requestFullAccessToEvents()) ?? false
    }

    public static var appleAccessGranted: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Signed in (Google, Outlook) or allowed (Apple).
    public var isConnected: Bool {
        self == .apple ? Self.appleAccessGranted : (session?.isSignedIn ?? false)
    }

    /// Disconnects this provider; Apple Calendar becomes the one read.
    public func disconnect() async {
        await session?.signOut()
        if Self.current == self { UserDefaults.standard.set(CalendarProvider.apple.rawValue, forKey: Self.defaultsKey) }
    }

    /// Connects this provider and disconnects the others: one at a time.
    public func connect() async throws {
        try await session?.signIn()
        for other in Self.allCases where other != self {
            await other.session?.signOut()
        }
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }

    /// The sign-in, for Google and Outlook.
    public var session: OAuthSession? {
        switch self {
        case .apple: nil
        case .google: GoogleCalendar.session
        case .outlook: OutlookCalendar.session
        }
    }
}

// MARK: - Apple Calendar

/// EventKit: every calendar in the Calendar app, including Google, Exchange
/// and iCloud accounts added in System Settings › Internet Accounts.
struct AppleCalendar: CalendarSource {
    func events(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        let store = EKEventStore()
        let allowed = (try? await store.requestFullAccessToEvents()) ?? false
        guard allowed else { throw AssistantFailure("Calendar access is off for Notch Assistant", link: .calendars) }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map {
            CalendarEvent(title: $0.title ?? "Untitled", start: $0.startDate, end: $0.endDate, isAllDay: $0.isAllDay)
        }
    }
}

// MARK: - Google Calendar

/// Google Calendar API, read-only, with the user's own OAuth client
/// ("Desktop app" type; Google requires its secret even for desktop apps,
/// where it isn't really secret. Kept in the Keychain regardless).
struct GoogleCalendar: CalendarSource {
    static let clientIDKey = "calendar.google.clientID"
    static let secretAccount = "calendar.google.secret"

    static let session = OAuthSession(
        .init(
            service: "Google Calendar",
            authorizeURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenURL: URL(string: "https://oauth2.googleapis.com/token")!,
            // Reading calendars; adding, moving and deleting events; tasks;
            // sending an email only after the user says "send it".
            scopes: "https://www.googleapis.com/auth/calendar.readonly https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/tasks https://www.googleapis.com/auth/gmail.send",
            tokenAccount: "calendar.google.token",
            redirectHost: "127.0.0.1",
            extraParameters: ["access_type": "offline", "prompt": "consent"],
            refreshSendsScope: false
        ),
        credentials: {
            let id = UserDefaults.standard.string(forKey: clientIDKey)?.trimmingCharacters(in: .whitespaces) ?? ""
            let secret = Keychain.data(for: secretAccount).flatMap { String(data: $0, encoding: .utf8) }
            guard !id.isEmpty, let secret, !secret.isEmpty else { return nil }
            return (id, secret)
        }
    )

    static func setSecret(_ secret: String) {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { Keychain.delete(secretAccount) } else { Keychain.set(Data(trimmed.utf8), for: secretAccount) }
    }

    static var hasSecret: Bool { Keychain.data(for: secretAccount) != nil }

    func events(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        let list = try await Self.session.get(URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList?minAccessRole=reader")!)
        let calendars = try Self.selectedCalendars(in: list)
        return try await withThrowingTaskGroup(of: [CalendarEvent].self) { group in
            for id in calendars {
                group.addTask {
                    var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/")!
                    components.percentEncodedPath += id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/", "@", "#"])) ?? id
                    components.percentEncodedPath += "/events"
                    let iso = ISO8601DateFormatter()
                    components.queryItems = [
                        .init(name: "timeMin", value: iso.string(from: start)),
                        .init(name: "timeMax", value: iso.string(from: end)),
                        .init(name: "singleEvents", value: "true"),
                        .init(name: "orderBy", value: "startTime"),
                        .init(name: "maxResults", value: "100"),
                    ]
                    return try Self.events(in: try await Self.session.get(components.url!))
                }
            }
            var all: [CalendarEvent] = []
            for try await events in group { all += events }
            return all
        }
    }

    /// The calendars ticked in Google Calendar.
    static func selectedCalendars(in data: Data) throws -> [String] {
        struct List: Decodable {
            struct Entry: Decodable { let id: String; let selected: Bool? }
            let items: [Entry]?
        }
        let list = try JSONDecoder().decode(List.self, from: data)
        return (list.items ?? []).filter { $0.selected ?? false }.map(\.id)
    }

    static func events(in data: Data) throws -> [CalendarEvent] {
        struct Page: Decodable {
            struct Item: Decodable {
                struct Moment: Decodable { let dateTime: String?; let date: String? }
                let summary: String?
                let status: String?
                let start: Moment?
                let end: Moment?
            }
            let items: [Item]?
        }
        let iso = ISO8601DateFormatter()
        return try JSONDecoder().decode(Page.self, from: data).items?.compactMap { item in
            guard item.status != "cancelled", let start = item.start, let end = item.end else { return nil }
            if let s = start.dateTime.flatMap(iso.date(from:)), let e = end.dateTime.flatMap(iso.date(from:)) {
                return CalendarEvent(title: item.summary ?? "Untitled", start: s, end: e, isAllDay: false)
            }
            if let s = start.date.flatMap(localDay), let e = end.date.flatMap(localDay) {
                return CalendarEvent(title: item.summary ?? "Untitled", start: s, end: e, isAllDay: true)
            }
            return nil
        } ?? []
    }
}

// MARK: - Outlook

/// Microsoft Graph, read-only, with the user's own app registration (a
/// public client: no secret). Works for Outlook.com and work accounts.
struct OutlookCalendar: CalendarSource {
    static let clientIDKey = "calendar.outlook.clientID"

    static let session = OAuthSession(
        .init(
            service: "Outlook",
            authorizeURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
            tokenURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
            scopes: "offline_access Calendars.Read",
            tokenAccount: "calendar.outlook.token",
            redirectHost: "localhost",
            extraParameters: [:],
            refreshSendsScope: true
        ),
        credentials: {
            let id = UserDefaults.standard.string(forKey: clientIDKey)?.trimmingCharacters(in: .whitespaces) ?? ""
            return id.isEmpty ? nil : (id, nil)
        }
    )

    func events(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        var components = URLComponents(string: "https://graph.microsoft.com/v1.0/me/calendarView")!
        let iso = ISO8601DateFormatter()
        components.queryItems = [
            .init(name: "startDateTime", value: iso.string(from: start)),
            .init(name: "endDateTime", value: iso.string(from: end)),
            .init(name: "$select", value: "subject,start,end,isAllDay,isCancelled"),
            .init(name: "$orderby", value: "start/dateTime"),
            .init(name: "$top", value: "100"),
        ]
        let data = try await Self.session.get(components.url!, headers: ["Prefer": "outlook.timezone=\"UTC\""])
        return try Self.events(in: data)
    }

    static func events(in data: Data) throws -> [CalendarEvent] {
        struct Page: Decodable {
            struct Item: Decodable {
                struct Moment: Decodable { let dateTime: String }
                let subject: String?
                let start: Moment
                let end: Moment
                let isAllDay: Bool?
                let isCancelled: Bool?
            }
            let value: [Item]
        }
        let items = try JSONDecoder().decode(Page.self, from: data).value
        return items.compactMap { (item: Page.Item) -> CalendarEvent? in
            guard item.isCancelled != true else { return nil }
            let allDay = item.isAllDay ?? false
            // All-day events are whole local days; timed ones are in UTC.
            func parse(_ text: String) -> Date? {
                allDay ? localDay(String(text.prefix(10))) : utcDateTime(text)
            }
            guard let start = parse(item.start.dateTime), let end = parse(item.end.dateTime) else { return nil }
            return CalendarEvent(title: item.subject ?? "Untitled", start: start, end: end, isAllDay: allDay)
        }
    }

    /// "2026-09-26T09:00:00.0000000", in UTC.
    static func utcDateTime(_ text: String) -> Date? {
        let trimmed = String(text.prefix(19))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: trimmed)
    }
}

/// "2026-09-26" as the start of that day here.
func localDay(_ text: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: text)
}
