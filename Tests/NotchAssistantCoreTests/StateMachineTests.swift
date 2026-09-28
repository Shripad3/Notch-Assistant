@testable import NotchAssistantCore
import Testing

struct StateMachineTests {
    let failure = AssistantFailure("boom")
    static let openApp = ToolLabel(name: "openApp", title: "Open app", symbol: "app.badge")
    static let openURL = ToolLabel(name: "openURL", title: "Open website", symbol: "globe")

    @Test func happyPath() {
        var state = AssistantState.idle
        let events: [AssistantEvent] = [
            .activation, .partial("open"), .endpoint("open spotify"),
            .toolCall(Self.openApp, target: "Spotify"), .done("Opened Spotify"), .dismiss,
        ]
        let expected: [AssistantState] = [
            .listening(partial: ""), .listening(partial: "open"), .thinking(transcript: "open spotify"),
            .acting(tool: Self.openApp, target: "Spotify"), .result("Opened Spotify"), .idle,
        ]
        for (event, next) in zip(events, expected) {
            state = StateMachine.transition(from: state, on: event)!
            #expect(state == next)
        }
    }

    @Test func actingChainsToolCalls() {
        let next = StateMachine.transition(from: .acting(tool: Self.openApp, target: "Arc"), on: .toolCall(Self.openURL, target: "youtube.com"))
        #expect(next == .acting(tool: Self.openURL, target: "youtube.com"))
    }

    @Test func textOnlyGoesToReply() {
        #expect(StateMachine.transition(from: .thinking(transcript: "x"), on: .textOnly("hi")) == .reply("hi"))
    }

    @Test(arguments: [
        AssistantState.listening(partial: ""), .thinking(transcript: "x"),
        .acting(tool: openApp, target: "x"), .result("done"), .error(AssistantFailure("e")),
    ])
    func cancelFromAnyNonIdleState(state: AssistantState) {
        #expect(StateMachine.transition(from: state, on: .cancel) == .idle)
    }

    @Test func cancelWhenIdleIsIgnored() {
        #expect(StateMachine.transition(from: .idle, on: .cancel) == nil)
    }

    @Test(arguments: [AssistantState.idle, .listening(partial: ""), .thinking(transcript: "x"), .acting(tool: openApp, target: "x")])
    func failureShowsError(state: AssistantState) {
        #expect(StateMachine.transition(from: state, on: .failure(failure)) == .error(failure))
    }

    @Test func silenceReturnsToIdleWithoutThinking() {
        #expect(StateMachine.transition(from: .listening(partial: ""), on: .silence) == .idle)
    }

    @Test func dismissOnlyFromResultOrError() {
        #expect(StateMachine.transition(from: .result("x"), on: .dismiss) == .idle)
        #expect(StateMachine.transition(from: .error(failure), on: .dismiss) == .idle)
        #expect(StateMachine.transition(from: .thinking(transcript: "x"), on: .dismiss) == nil)
    }

    @Test func activationNotWhileWorking() {
        #expect(StateMachine.transition(from: .thinking(transcript: "x"), on: .activation) == nil)
        #expect(StateMachine.transition(from: .acting(tool: ToolLabel(name: "t", title: "T", symbol: "x"), target: ""), on: .activation) == nil)
    }

    @Test func speakingOverAnOutcomeListens() {
        for state: AssistantState in [.result("x"), .reply("x"), .list("x", []), .error(failure)] {
            #expect(StateMachine.transition(from: state, on: .activation) == .listening(partial: ""))
        }
    }

    @Test func latePartialAfterEndpointIsIgnored() {
        #expect(StateMachine.transition(from: .thinking(transcript: "x"), on: .partial("x y")) == nil)
    }
}

struct ListStateTests {
    let item = ResultItem(id: "file_1", title: "a.png", detail: "", symbol: "photo")

    @Test func doneWithItemsShowsList() {
        let next = StateMachine.transition(from: .acting(tool: StateMachineTests.openApp, target: ""), on: .done("Found 1", items: [item]))
        #expect(next == .list("Found 1", [item]))
    }

    @Test func doneWithoutItemsIsPlainResult() {
        #expect(StateMachine.transition(from: .acting(tool: StateMachineTests.openApp, target: ""), on: .done("ok")) == .result("ok"))
    }

    @Test func selectingOpensAndShowsResult() {
        #expect(StateMachine.transition(from: .list("Found 1", [item]), on: .selected("Opened a.png")) == .result("Opened a.png"))
        #expect(StateMachine.transition(from: .result("x"), on: .selected("y")) == nil)
    }

    @Test func listCanBeCancelledOrDismissed() {
        #expect(StateMachine.transition(from: .list("x", [item]), on: .cancel) == .idle)
        #expect(StateMachine.transition(from: .list("x", [item]), on: .dismiss) == .idle)
    }
}

struct FollowUpStateTests {
    @Test func askingThenListening() {
        #expect(StateMachine.transition(from: .acting(tool: ToolLabel(name: "a", title: "A", symbol: "a"), target: ""), on: .ask("For when?")) == .question("For when?"))
        #expect(StateMachine.transition(from: .question("For when?"), on: .activation) == .listening(partial: ""))
        #expect(StateMachine.transition(from: .question("For when?"), on: .dismiss) == .idle)
        #expect(StateMachine.transition(from: .question("For when?"), on: .cancel) == .idle)
    }

    @Test func patienceIsLongerForAnswers() {
        var endpointer = Endpointer(ambientFloor: -50, patience: 6)
        var decision = Endpointer.Decision.listening
        for _ in 0..<50 { decision = endpointer.feed(level: -70, duration: 0.1) } // 5 s of silence
        #expect(decision == .listening)
        for _ in 0..<11 { decision = endpointer.feed(level: -70, duration: 0.1) }
        #expect(decision == .noSpeech)
    }
}
