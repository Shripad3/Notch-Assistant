import Testing
@testable import NotchAssistantCore

struct BargeInTests {
    let spoken = Set("the lease runs for twelve months and the rent is due on the first".split(separator: " ").map(String.init))

    @Test func alfredsOwnEchoIsNotAnInterruption() {
        #expect(!BargeIn.isInterruption("the rent is due", over: spoken))
        #expect(!BargeIn.isInterruption("twelve months", over: spoken))
    }

    @Test func theUserTalkingOverIsAnInterruption() {
        #expect(BargeIn.isInterruption("open my calendar", over: spoken))
        #expect(BargeIn.isInterruption("stop", over: spoken))
        #expect(BargeIn.isInterruption("wait what about the deposit", over: spoken))
    }

    @Test func oneStrayWordIsNot() {
        #expect(!BargeIn.isInterruption("hmm", over: spoken))
    }

    @Test func notArmedWhenAlfredIsQuiet() {
        BargeIn.ended()
        #expect(!BargeIn.isInterruption("open my calendar", armed: true))
    }

    @Test func stopJustStops() {
        #expect(BargeIn.isJustStop("Stop."))
        #expect(!BargeIn.isJustStop("stop the music"))
    }
}
