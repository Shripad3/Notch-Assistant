import Foundation
import Testing
@testable import NotchAssistantCore

struct WakeNameTests {
    @Test func namesAreChecked() {
        #expect(WakePhrase.problem(with: "Jarvis") == nil)
        #expect(WakePhrase.problem(with: "Hey Nova") == nil)
        #expect(WakePhrase.problem(with: "Al") != nil)
        #expect(WakePhrase.problem(with: "R2D2") != nil)
        #expect(WakePhrase.problem(with: "Siri") != nil)
        #expect(WakePhrase.problem(with: "one two three") != nil)
        #expect(WakePhrase.warning(for: "Max") != nil)
        #expect(WakePhrase.warning(for: "Jarvis") == nil)
    }

    @Test func aNewNameWakesAndIsStripped() {
        WakePhrase.$override.withValue("Jarvis") {
            #expect(WakePhrase.contains("hey Jarvis open notes"))
            #expect(!WakePhrase.contains("Alfred open notes"))
            #expect(WakePhrase.command(from: "Hey Jarvis, open Notes") == "open Notes")
            #expect(SmallTalk.reply(to: "what's your name") == "I'm Jarvis. I live in your notch.")
        }
    }

    @Test func shortNamesNeedAnExactMatch() {
        #expect(WakePhrase.isWakeWord("kai", name: "kai"))
        #expect(!WakePhrase.isWakeWord("kay", name: "kai"))
    }

    @Test func conversationIsItsOwnState() {
        #expect(StateMachine.transition(from: .thinking(transcript: "hi"), on: .chat("Hey!")) == .chat("Hey!"))
        #expect(StateMachine.transition(from: .chat("Hey!"), on: .activation) == .listening(partial: ""))
        #expect(StateMachine.transition(from: .chat("Hey!"), on: .dismiss) == .idle)
    }
}
