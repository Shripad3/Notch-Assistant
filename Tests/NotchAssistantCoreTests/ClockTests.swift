import Foundation
@testable import NotchAssistantCore
import Synchronization
import Testing

struct SpokenDurationTests {
    @Test(arguments: [
        ("10 minutes", 600.0),
        ("an hour and a half", 5400),
        ("half an hour", 1800),
        ("1 hour and 30 minutes", 5400),
        ("1 hour 30 minutes", 5400),
        ("ninety seconds", 90),
        ("1.5 hours", 5400),
        ("twenty five minutes", 1500),
        ("twenty-five minutes", 1500),
        ("a minute", 60),
        ("one and a half hours", 5400),
        ("quarter of an hour", 900),
        ("2 mins", 120),
        ("set a timer for 3 minutes please", 180),
    ])
    func parses(said: String, seconds: Double) {
        #expect(SpokenDuration.parse(said) == seconds)
    }

    @Test(arguments: ["set a timer", "at 7", "the 10 commandments"])
    func rejects(said: String) {
        #expect(SpokenDuration.parse(said) == nil)
    }

    @Test func formats() {
        #expect(ClockFormat.spoken(5400) == "1 hour 30 minutes")
        #expect(ClockFormat.spoken(581) == "9 minutes 41 seconds")
        #expect(ClockFormat.spoken(1) == "1 second")
        #expect(ClockFormat.adjective(600) == "10 minute")
        #expect(ClockFormat.clock(581) == "9:41")
        #expect(ClockFormat.clock(3723) == "1:02:03")
    }
}

struct SpokenWhenTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// Saturday 26 September 2026, 10:00 UTC.
    static let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 10))!

    static func date(day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    @Test(arguments: [
        ("7 am", date(day: 27, 7)),
        ("7 a.m.", date(day: 27, 7)),
        ("7am", date(day: 27, 7)),
        ("for 7", date(day: 26, 19)),
        ("at 9", date(day: 26, 21)),
        ("tomorrow at 6:30", date(day: 27, 6, 30)),
        ("tonight at 8", date(day: 26, 20)),
        ("noon", date(day: 26, 12)),
        ("at midnight", date(day: 27, 0)),
        ("half past 5", date(day: 26, 17, 30)),
        ("quarter to 8", date(day: 26, 19, 45)),
        ("20 past 11", date(day: 26, 11, 20)),
        ("in 20 minutes", date(day: 26, 10, 20)),
        ("on Monday at 9 am", date(day: 28, 9)),
        ("7:30 pm", date(day: 26, 19, 30)),
        ("seven thirty am", date(day: 27, 7, 30)),
        ("730 am", date(day: 27, 7, 30)),
        ("tomorrow morning at 7", date(day: 27, 7)),
        ("at 6 in the evening", date(day: 26, 18)),
        ("at 7 o'clock", date(day: 26, 19)),
    ])
    func parses(said: String, expected: Date) throws {
        let when = try #require(SpokenWhen.parse(said, now: Self.now, calendar: Self.calendar))
        #expect(when.date == expected)
        #expect(when.hasTime)
    }

    @Test func dayWithoutTime() throws {
        let when = try #require(SpokenWhen.parse("tomorrow", now: Self.now, calendar: Self.calendar))
        #expect(!when.hasTime)
        #expect(when.date == Self.date(day: 27, 0))
    }

    @Test(arguments: ["buy 2 apples", "call Mum", "10 minutes"])
    func noTime(said: String) {
        #expect(SpokenWhen.parse(said, now: Self.now, calendar: Self.calendar) == nil)
    }

    @Test func prefersTheSpokenTimeOverOtherNumbers() throws {
        let when = try #require(SpokenWhen.parse("set the table for 4 at 6", now: Self.now, calendar: Self.calendar))
        #expect(when.date == Self.date(day: 26, 18))
    }
}

struct ClockDirectTests {
    func timer(_ said: String) -> TimerArguments? {
        DirectCommand(said).flatMap { TimerTool().directArguments(for: $0) }
    }

    func alarm(_ said: String) -> AlarmArguments? {
        DirectCommand(said).flatMap { AlarmTool().directArguments(for: $0) }
    }

    func stopwatch(_ said: String) -> String? {
        DirectCommand(said).flatMap { StopwatchTool().directArguments(for: $0) }?.action
    }

    func reminder(_ said: String) -> ReminderArguments? {
        DirectCommand(said).flatMap { ReminderTool().directArguments(for: $0) }
    }

    @Test func timers() throws {
        var args = try #require(timer("Set a timer for 10 minutes."))
        #expect(args.action == "start")
        #expect(args.duration == "10 minutes")
        #expect(args.label == nil)
        #expect(timer("set a pasta timer for 10 minutes")?.label == "pasta")
        #expect(timer("set a timer for 5 minutes for the eggs")?.label == "eggs")
        #expect(timer("set a 10 minute timer")?.label == nil)
        #expect(timer("cancel the timer")?.action == "cancel")
        #expect(timer("stop the pasta timer")?.label == "pasta")
        args = try #require(timer("cancel all timers"))
        #expect(args.action == "cancel")
        #expect(args.label == "all")
        #expect(timer("how much time is left")?.action == "status")
        #expect(timer("how long is left on my timer")?.action == "status")
        #expect(timer("pause the timer")?.action == "pause")
        #expect(timer("resume the timer")?.action == "resume")
        args = try #require(timer("add 5 minutes to the timer"))
        #expect(args.action == "add")
        #expect(args.duration == "5 minutes")
        args = try #require(timer("could you time 5 minutes for my tea"))
        #expect(args.action == "start")
        #expect(args.label == "tea")
        #expect(timer("open timer app") == nil)
        #expect(timer("start the stopwatch") == nil)
    }

    @Test func alarms() throws {
        var args = try #require(alarm("Set an alarm for 7 a.m."))
        #expect(args.action == "set")
        #expect(args.time.map { SpokenWhen.parse($0) != nil } == true)
        #expect(alarm("wake me up at 6:30 tomorrow")?.action == "set")
        #expect(alarm("what alarms do I have")?.action == "list")
        args = try #require(alarm("cancel my 7 am alarm"))
        #expect(args.action == "cancel")
        #expect(args.time != nil)
        #expect(alarm("set a gym alarm for 6")?.label == "gym")
        #expect(alarm("set an alarm for 7 called gym")?.label == "gym")
        #expect(alarm("turn off all alarms")?.label == "all")
    }

    @Test(arguments: [
        ("start a stopwatch", "start"),
        ("start the stop watch", "start"),
        ("stop the stopwatch", "stop"),
        ("pause the stopwatch", "stop"),
        ("lap", "lap"),
        ("reset the stopwatch", "reset"),
        ("restart the stopwatch", "restart"),
        ("how long has the stopwatch been running", "status"),
        ("resume the stopwatch", "resume"),
    ])
    func stopwatches(said: String, action: String) {
        #expect(stopwatch(said) == action)
    }

    @Test func reminders() throws {
        var args = try #require(reminder("Remind me to call Mum at 6."))
        #expect(args.task == "call Mum")
        #expect(args.when == "at 6")
        args = try #require(reminder("remind me tomorrow to buy milk"))
        #expect(args.task == "buy milk")
        #expect(args.when == "tomorrow")
        args = try #require(reminder("remind me in 20 minutes to check the oven"))
        #expect(args.task == "check the oven")
        #expect(args.when == "in 20 minutes")
        args = try #require(reminder("set a reminder to pay rent on Monday"))
        #expect(args.task == "pay rent")
        #expect(args.when == "on Monday")
        args = try #require(reminder("remind me that I need to email Sam"))
        #expect(args.task == "email Sam")
        #expect(args.when == nil)
    }

    @Test(arguments: [
        ("what time is it", "time", nil as String?),
        ("What's the time in Tokyo?", "time", "tokyo"),
        ("what's the date", "date", nil),
        ("what day is it", "date", nil),
    ])
    func time(said: String, what: String, place: String?) throws {
        let args = try #require(DirectCommand(said).flatMap { CurrentTimeTool().directArguments(for: $0) })
        #expect(args.what == what)
        #expect(args.place == place)
    }

    @Test(arguments: [
        ("set a timer for an hour and a half", "timer"),
        ("set a timer for 1 hour and 30 minutes", "timer"),
        ("remind me to buy bread and milk", "reminder"),
        ("start the stopwatch", "stopwatch"),
        ("stop the timer", "timer"),
        ("set an alarm for 7 am", "alarm"),
        ("what time is it", "currentTime"),
        ("stop", "controlSpotify"),
    ])
    func routesDirectly(said: String, tool: String) {
        #expect(DirectMatcher.plan(for: said, tools: ToolRegistry.standard.tools)?.steps.first?.tool.name == tool)
    }

    @Test func compoundCommandsStillGoToTheModel() {
        #expect(DirectMatcher.plan(for: "set a timer for 10 minutes and open Spotify", tools: ToolRegistry.standard.tools) == nil)
    }
}

struct ClockStoreTests {
    @Test func timersStartReportAndCancel() async throws {
        let store = ClockStore(file: nil)
        let tool = TimerTool(store: store)
        let said = "set a pasta timer for 10 minutes"
        let args = try #require(DirectCommand(said).flatMap { tool.directArguments(for: $0) })
        let result = try await CommandContext.$transcript.withValue(said) { try await tool.execute(args) }
        #expect(result.text == "Pasta timer set for 10 minutes")
        #expect(store.snapshot.timers.count == 1)
        #expect(store.snapshot.timers[0].label == "pasta")

        let status = try await tool.execute(TimerArguments(action: "status", duration: nil, label: nil))
        #expect(status.isAnswer)
        #expect(status.text.hasSuffix("left on your pasta timer"))

        _ = try await tool.execute(TimerArguments(action: "cancel", duration: nil, label: nil))
        #expect(store.snapshot.timers.isEmpty)
    }

    @Test func ambiguousCancelAsksWhich() async throws {
        let store = ClockStore(file: nil)
        store.addTimer(60, label: "tea")
        store.addTimer(600, label: "pasta")
        let tool = TimerTool(store: store)
        await #expect(throws: ToolError.self) {
            try await tool.execute(TimerArguments(action: "cancel", duration: nil, label: nil))
        }
        _ = try await tool.execute(TimerArguments(action: "cancel", duration: nil, label: "tea"))
        #expect(store.snapshot.timers.map(\.label) == ["pasta"])
    }

    @Test func pauseKeepsTheRemainingTime() {
        let store = ClockStore(file: nil)
        let start = Date()
        let timer = store.addTimer(600, label: nil, now: start)
        store.pause(timer.id, now: start.addingTimeInterval(100))
        #expect(store.snapshot.timers[0].remaining() == 500)
        store.resume(timer.id, now: start.addingTimeInterval(1000))
        #expect(store.snapshot.timers[0].fireDate == start.addingTimeInterval(1500))
    }

    @Test func dueCountdownsRingOnce() {
        let store = ClockStore(file: nil)
        let rung = Mutex<[ClockAlert]>([])
        store.start(notifier: nil, onChange: { _ in }, onFire: { alert in rung.withLock { $0.append(alert) } })
        store.addTimer(1, label: "tea", now: Date().addingTimeInterval(-2))
        store.fireDue()
        store.fireDue()
        let alerts = rung.withLock { $0 }
        #expect(alerts.count == 1)
        #expect(alerts.first?.message == "Time's up. Your tea timer is done.")
        #expect(store.snapshot.countdowns.isEmpty)
    }

    @Test func snoozeMakesANewAlarm() {
        let store = ClockStore(file: nil)
        let alarm = store.addAlarm(at: Date().addingTimeInterval(-1), label: "gym")
        let now = Date()
        let date = store.snooze(ClockAlert(alarm), now: now)
        #expect(date == now.addingTimeInterval(9 * 60))
        #expect(store.snapshot.alarms.contains { $0.label == "gym" && $0.fireDate == date })
    }

    @Test func stopwatchStartsLapsAndStops() async throws {
        let store = ClockStore(file: nil)
        let tool = StopwatchTool(store: store)
        _ = try await tool.execute(StopwatchArguments(action: "start"))
        #expect(store.snapshot.stopwatch.isRunning)
        let lap = try await tool.execute(StopwatchArguments(action: "lap"))
        #expect(lap.text.hasPrefix("Lap 1:"))
        let stop = try await tool.execute(StopwatchArguments(action: "stop"))
        #expect(stop.text.hasPrefix("Stopwatch stopped at"))
        #expect(!store.snapshot.stopwatch.isRunning)
        _ = try await tool.execute(StopwatchArguments(action: "reset"))
        #expect(store.snapshot.stopwatch.isIdle)
    }

    @Test(arguments: [
        ("stop", AlertReply.stop as AlertReply?),
        ("okay thanks", .stop),
        ("I'm up", .stop),
        ("turn it off", .stop),
        ("snooze", .snooze),
        ("snooze for a bit", .snooze),
        ("turn off the lights", nil),
        ("open Spotify", nil),
    ])
    func alertReplies(said: String, reply: AlertReply?) {
        #expect(AlertReply.interpret(said) == reply)
    }
}

struct AlertStateTests {
    let alert = ClockAlert(Countdown(id: UUID(), kind: .alarm, label: nil, fireDate: Date(), duration: 0))

    @Test func ringsFromIdleOnly() {
        #expect(StateMachine.transition(from: .idle, on: .ring(alert)) == .alert(alert))
        #expect(StateMachine.transition(from: .thinking(transcript: "x"), on: .ring(alert)) == nil)
    }

    @Test func speakingOrDismissingEndsIt() {
        #expect(StateMachine.transition(from: .alert(alert), on: .activation) == .listening(partial: ""))
        #expect(StateMachine.transition(from: .alert(alert), on: .dismiss) == .idle)
        #expect(StateMachine.transition(from: .alert(alert), on: .cancel) == .idle)
    }
}
