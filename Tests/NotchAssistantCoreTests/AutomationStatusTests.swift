@testable import NotchAssistantCore
import Testing

struct AutomationStatusTests {
    /// The real macOS check, against an app that is always running. It must
    /// come back within the time limit whatever macOS does.
    @Test func neverBlocksForARunningTarget() async {
        let started = ContinuousClock.now
        _ = await AutomationStatus.check(bundleIdentifier: "com.apple.finder")
        #expect(started.duration(to: .now) < .seconds(3))
    }

    @Test func notRunningTargetAnswersImmediately() async {
        let started = ContinuousClock.now
        let status = await AutomationStatus.check(bundleIdentifier: "dev.shripad.not-a-real-app")
        #expect(status == .targetNotRunning)
        #expect(started.duration(to: .now) < .milliseconds(200))
    }
}
