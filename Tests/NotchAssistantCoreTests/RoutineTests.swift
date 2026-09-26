import Foundation
import FoundationModels
@testable import NotchAssistantCore
import Testing

struct RoutineTests {
    let routines = Routines.examples

    @Test(arguments: [
        ("I'm home", "I'm home"),
        ("i'm home.", "I'm home"),
        ("I am home", "I'm home"),
        ("hey I'm home now", "I'm home"),
        ("good night", "Good night"),
        ("Goodnight.", "Good night"),
        ("I'm going to bed", "Good night"),
        ("time to focus", "Focus"),
    ])
    func matchesTriggers(said: String, routine: String) {
        #expect(Routines.match(said, in: routines)?.name == routine)
    }

    @Test(arguments: [
        "open Spotify",
        "what time do I usually get home from work on a Friday",
        "say good night to my friends on WhatsApp for me please",
        "home",
    ])
    func ignoresOtherCommands(said: String) {
        #expect(Routines.match(said, in: routines) == nil)
    }

    @Test func disabledRoutinesDontMatch() {
        var routine = routines[0]
        routine.enabled = false
        #expect(Routines.match("I'm home", in: [routine]) == nil)
    }

    @Test func stepsBecomeToolCalls() throws {
        let tools = ToolRegistry.standard.tools
        let plan = Routines.plan(for: routines[0], tools: tools)
        #expect(plan.steps.map(\.tool.name) == ["runShortcut", "controlSpotify", "openApp"])
        #expect(plan.steps.allSatisfy { $0.transcript == nil })
        #expect(plan.routine == RoutineRun(name: "I'm home", closing: "Welcome home.", skipped: []))
        let spotify = try plan.steps[1].arguments.value(ControlSpotifyArguments.self)
        #expect(spotify.action == "playPlaylist")
        #expect(spotify.query == "Liked Songs")
    }

    @Test func percentStepsAreClamped() throws {
        let routine = Routine(name: "Loud", triggers: ["loud"], steps: [RoutineStep(.setVolume, percent: 140)])
        let plan = Routines.plan(for: routine, tools: ToolRegistry.standard.tools)
        #expect(try plan.steps[0].arguments.value(SystemControlArguments.self).value == 100)
    }

    @Test func missingToolsAndEmptyStepsAreSkipped() {
        let routine = Routine(name: "R", triggers: ["r"], steps: [RoutineStep(.openApp, text: ""), RoutineStep(.lockScreen), RoutineStep(.runShortcut, text: "Lights On")])
        let tools = ToolRegistry.standard.tools.filter { $0.name != "runShortcut" }
        let plan = Routines.plan(for: routine, tools: tools)
        #expect(plan.steps.map(\.tool.name) == ["systemControl"])
        #expect(plan.routine?.skipped == ["Open app: ", "Run shortcut: Lights On"])
    }

    @Test func routinesRoundTripThroughJSON() throws {
        let data = try JSONEncoder().encode(routines)
        #expect(try JSONDecoder().decode([Routine].self, from: data) == routines)
    }

    @Test(arguments: [
        ("run my lights on shortcut", "lights on"),
        ("run shortcut lights off", "lights off"),
        ("run the movie night shortcut", "movie night"),
    ])
    func runShortcutDirect(said: String, name: String) throws {
        let command = try #require(DirectCommand(said))
        #expect(RunShortcutTool().directArguments(for: command)?.name == name)
    }
}
