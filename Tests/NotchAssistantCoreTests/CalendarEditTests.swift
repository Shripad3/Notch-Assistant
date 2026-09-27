import Foundation
@testable import NotchAssistantCore
import Synchronization
import Testing

/// An in-memory calendar.
private final class FakeWriter: CalendarWriting, @unchecked Sendable {
    let events = Mutex<[EditableEvent]>([])

    init(_ initial: [EditableEvent] = []) { events.withLock { $0 = initial } }

    func editableEvents(from start: Date, to end: Date) async throws -> [EditableEvent] {
        events.withLock { $0.filter { $0.start < end && $0.end > start } }
    }

    func create(_ draft: EventDraft) async throws -> EditableEvent {
        let event = EditableEvent(id: UUID().uuidString, calendarID: nil, seriesID: nil, title: draft.title, start: draft.start,
                                  end: draft.end, isAllDay: draft.isAllDay, hasAttendees: false)
        events.withLock { $0.append(event) }
        return event
    }

    func update(_ event: EditableEvent, start: Date, end: Date) async throws {
        events.withLock { all in
            guard let index = all.firstIndex(where: { $0.id == event.id }) else { return }
            let old = all[index]
            all[index] = EditableEvent(id: old.id, calendarID: nil, seriesID: old.seriesID, title: old.title, start: start, end: end,
                                       isAllDay: old.isAllDay, hasAttendees: old.hasAttendees)
        }
    }

    func delete(_ event: EditableEvent, allOccurrences: Bool) async throws {
        events.withLock { $0.removeAll { $0.id == event.id } }
    }
}

/// Serialized: "undo" is one shared slot.
@Suite(.serialized)
struct CalendarEditTests {
    static func tomorrow(_ hour: Int, _ minute: Int = 0) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    static func event(_ title: String, at start: Date, invited: Bool = false) -> EditableEvent {
        EditableEvent(id: UUID().uuidString, calendarID: nil, seriesID: nil, title: title, start: start, end: start.addingTimeInterval(3600),
                      isAllDay: false, hasAttendees: invited)
    }

    func run(_ said: String, _ tool: CalendarEventTool) async throws -> ToolResult {
        let args = try #require(DirectCommand(said).flatMap { tool.directArguments(for: $0) }, "no direct match for \(said)")
        return try await CommandContext.$transcript.withValue(said) { try await tool.execute(args) }
    }

    @Test func addsAnEventAndUndoes() async throws {
        let writer = FakeWriter()
        let tool = CalendarEventTool(writer: writer)
        let result = try await run("add lunch with Sam tomorrow at 1 for 30 minutes", tool)
        #expect(result.text.hasPrefix("Added “Lunch with Sam” tomorrow at"))
        let event = try #require(writer.events.withLock { $0.first })
        #expect(event.start == Self.tomorrow(13))
        #expect(event.end == Self.tomorrow(13, 30))
        let undo = try #require(RecentUndo.take())
        _ = try await undo.undo()
        #expect(writer.events.withLock { $0.isEmpty })
    }

    @Test func asksForWhatsMissing() async throws {
        let tool = CalendarEventTool(writer: FakeWriter())
        #expect(try await run("add lunch with Sam", tool).followUp == "For when?")
        #expect(try await run("add a dentist appointment tomorrow", tool).followUp == "What time? Or say all day")
        #expect(try await run("schedule an event tomorrow at 3", tool).followUp == "What's it called?")
        // The answer is added to the command, which then goes through.
        let answered = try await run("add lunch with Sam tomorrow at 1", tool)
        #expect(answered.followUp == nil)
    }

    @Test func allDayEvents() async throws {
        let writer = FakeWriter()
        _ = try await run("add holiday tomorrow all day", CalendarEventTool(writer: writer))
        let event = try #require(writer.events.withLock { $0.first })
        #expect(event.isAllDay)
    }

    @Test func movesToAnotherDayKeepingTheTime() async throws {
        let writer = FakeWriter([Self.event("Dentist", at: Self.tomorrow(15))])
        let result = try await run("move my dentist appointment to the day after tomorrow", CalendarEventTool(writer: writer))
        #expect(result.text.hasPrefix("Moved “Dentist”"))
        let moved = try #require(writer.events.withLock { $0.first })
        #expect(Calendar.current.component(.hour, from: moved.start) == 15)
        #expect(moved.start.timeIntervalSince(Self.tomorrow(15)) == 86_400)
    }

    @Test func movesToAnotherTimeSameDay() async throws {
        let writer = FakeWriter([Self.event("Standup", at: Self.tomorrow(9))])
        _ = try await run("push standup to 10", CalendarEventTool(writer: writer))
        #expect(writer.events.withLock { $0.first?.start } == Self.tomorrow(10))
    }

    @Test func deletingWaitsForYes() async throws {
        let writer = FakeWriter([Self.event("Dentist", at: Self.tomorrow(15))])
        let result = try await run("cancel my dentist appointment", CalendarEventTool(writer: writer))
        let token = try #require(result.confirmation)
        #expect(result.text.hasPrefix("Delete “Dentist”"))
        #expect(writer.events.withLock { $0.count } == 1)
        _ = try await Confirmations.confirm(token)
        #expect(writer.events.withLock { $0.isEmpty })
    }

    @Test func refusesEventsWithOtherPeople() async throws {
        let tool = CalendarEventTool(writer: FakeWriter([Self.event("Team review", at: Self.tomorrow(14), invited: true)]))
        await #expect(throws: ToolError.self) { try await run("move the team review meeting to 4", tool) }
        await #expect(throws: ToolError.self) { try await run("cancel the team review meeting", tool) }
    }

    @Test func asksWhichWhenSeveralMatch() async throws {
        let later = Calendar.current.date(byAdding: .day, value: 3, to: Self.tomorrow(10))!
        let tool = CalendarEventTool(writer: FakeWriter([Self.event("Dentist", at: Self.tomorrow(15)), Self.event("Dentist", at: later)]))
        let result = try await run("delete my dentist appointment", tool)
        #expect(result.followUp?.hasPrefix("Which one: Dentist") == true)
    }

    @Test func aTimeWithoutADayFindsTheAfternoonEvent() async throws {
        let writer = FakeWriter([Self.event("Review", at: Self.tomorrow(15))])
        let result = try await run("cancel my 3 o'clock", CalendarEventTool(writer: writer))
        #expect(result.text.hasPrefix("Delete “Review”"))
    }

    @Test(arguments: [
        ("add lunch with Sam tomorrow at 1", "calendarEvent"),
        ("schedule a meeting on Friday at 3 for 30 minutes", "calendarEvent"),
        ("move my dentist appointment to Monday", "calendarEvent"),
        ("cancel my 3 o'clock", "calendarEvent"),
        ("make standup 30 minutes", "calendarEvent"),
        ("cancel the timer", "timer"),
        ("add 5 minutes to the timer", "timer"),
        ("add eggs to my notes", "takeNote"),
        ("move my latest screenshot to documents", "organiseFiles"),
        ("put Safari on the left half", "arrangeWindow"),
        ("what's on my calendar tomorrow", "calendar"),
        ("set an alarm for 7 am", "alarm"),
    ])
    func routes(said: String, tool: String) {
        #expect(DirectMatcher.plan(for: said, tools: ToolRegistry.standard.tools)?.steps.first?.tool.name == tool)
    }

    @Test(arguments: ["change brightness to 5", "change the volume to 30", "move this window to the other display"])
    func leavesOtherCommands(said: String) {
        #expect(DirectCommand(said).flatMap { CalendarEventTool().directArguments(for: $0) } == nil)
    }
}
