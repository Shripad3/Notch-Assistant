import Foundation
@testable import NotchAssistantCore
import Testing

private struct FakeCalendar: CalendarSource {
    let all: [CalendarEvent]
    func events(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        all.filter { $0.start < end && $0.end > start }
    }
}

struct CalendarTests {
    @Test func parsesGoogleEvents() throws {
        let json = """
        {"items": [
          {"summary": "Standup", "status": "confirmed",
           "start": {"dateTime": "2026-09-28T09:30:00+02:00"}, "end": {"dateTime": "2026-09-28T09:45:00+02:00"}},
          {"summary": "Holiday", "start": {"date": "2026-09-28"}, "end": {"date": "2026-09-29"}},
          {"summary": "Gone", "status": "cancelled", "start": {"dateTime": "2026-09-28T10:00:00Z"}, "end": {"dateTime": "2026-09-28T11:00:00Z"}}
        ]}
        """
        let events = try GoogleCalendar.events(in: Data(json.utf8))
        #expect(events.map(\.title) == ["Standup", "Holiday"])
        #expect(events[0].start == ISO8601DateFormatter().date(from: "2026-09-28T07:30:00Z"))
        #expect(events[1].isAllDay)
    }

    @Test func selectsTickedGoogleCalendars() throws {
        let json = #"{"items": [{"id": "me@gmail.com", "selected": true}, {"id": "holidays", "selected": false}, {"id": "other"}]}"#
        #expect(try GoogleCalendar.selectedCalendars(in: Data(json.utf8)) == ["me@gmail.com"])
    }

    @Test func parsesOutlookEvents() throws {
        let json = """
        {"value": [
          {"subject": "Review", "isAllDay": false, "isCancelled": false,
           "start": {"dateTime": "2026-09-28T13:00:00.0000000", "timeZone": "UTC"},
           "end": {"dateTime": "2026-09-28T14:00:00.0000000", "timeZone": "UTC"}},
          {"subject": "Off", "isAllDay": true,
           "start": {"dateTime": "2026-09-29T00:00:00.0000000"}, "end": {"dateTime": "2026-09-30T00:00:00.0000000"}},
          {"subject": "Cancelled", "isCancelled": true,
           "start": {"dateTime": "2026-09-28T15:00:00.0000000"}, "end": {"dateTime": "2026-09-28T16:00:00.0000000"}}
        ]}
        """
        let events = try OutlookCalendar.events(in: Data(json.utf8))
        #expect(events.map(\.title) == ["Review", "Off"])
        #expect(events[0].start == ISO8601DateFormatter().date(from: "2026-09-28T13:00:00Z"))
        #expect(events[1].isAllDay)
        #expect(events[1].start == localDay("2026-09-29"))
    }

    @Test func speaksAnAgenda() {
        let now = Date()
        let day = Calendar.current.startOfDay(for: now)
        let nine = day.addingTimeInterval(9 * 3600)
        let events = [
            CalendarEvent(title: "Holiday", start: day, end: day.addingTimeInterval(86_400), isAllDay: true),
            CalendarEvent(title: "Standup", start: nine, end: nine.addingTimeInterval(900), isAllDay: false),
        ]
        let text = CalendarTool.agenda(events, day: day, now: now)
        #expect(text.hasPrefix("You have 2 events today: Holiday, all day, Standup at "))
        #expect(CalendarTool.agenda([], day: day, now: now) == "Nothing on your calendar today")
    }

    @Test(arguments: [
        ("what's on my calendar today", "agenda"),
        ("What's on my calendar tomorrow?", "agenda"),
        ("do I have any meetings on Friday", "agenda"),
        ("what's my schedule", "agenda"),
        ("when is my next meeting", "next"),
        ("what's my next event", "next"),
        ("am I free at 3", "free"),
        ("am I busy tomorrow at 10 am", "free"),
    ])
    func matches(said: String, action: String) {
        #expect(DirectCommand(said).flatMap { CalendarTool().directArguments(for: $0) }?.action == action)
    }

    @Test(arguments: ["open calendar", "add a meeting tomorrow at 3", "remind me about the meeting", "set a timer for 10 minutes"])
    func leavesOthers(said: String) {
        #expect(DirectCommand(said).flatMap { CalendarTool().directArguments(for: $0) } == nil)
    }

    @Test func routesBeforeOtherTools() {
        #expect(DirectMatcher.plan(for: "what's on my calendar tomorrow", tools: ToolRegistry.standard.tools)?.steps.first?.tool.name == "calendar")
        #expect(DirectMatcher.plan(for: "remind me about the meeting at 5", tools: ToolRegistry.standard.tools)?.steps.first?.tool.name == "reminder")
    }

    @Test func freeOrBusy() async throws {
        let now = Date()
        let busy = try #require(SpokenWhen.parse("at 3 pm tomorrow", now: now)).date
        let tool = CalendarTool(source: FakeCalendar(all: [
            CalendarEvent(title: "Dentist", start: busy.addingTimeInterval(-600), end: busy.addingTimeInterval(1800), isAllDay: false),
        ]))
        let said = "am I free at 3 pm tomorrow"
        let args = try #require(DirectCommand(said).flatMap { tool.directArguments(for: $0) })
        let result = try await CommandContext.$transcript.withValue(said) { try await tool.execute(args) }
        #expect(result.text.hasPrefix("You have Dentist"))

        let free = "am I free at 5 pm tomorrow"
        let freeArgs = try #require(DirectCommand(free).flatMap { tool.directArguments(for: $0) })
        let freeResult = try await CommandContext.$transcript.withValue(free) { try await tool.execute(freeArgs) }
        #expect(freeResult.text.hasPrefix("You're free"))
    }
}
