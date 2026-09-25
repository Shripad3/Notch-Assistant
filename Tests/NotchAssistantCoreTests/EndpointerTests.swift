@testable import NotchAssistantCore
import Testing

struct EndpointerTests {
    /// Feeds `seconds` of audio at `level` dBFS in 20 ms buffers; returns the
    /// first non-listening decision and when it happened.
    private func run(_ endpointer: inout Endpointer, _ segments: [(level: Float, seconds: Double)]) -> (Endpointer.Decision, Double)? {
        var time = 0.0
        for segment in segments {
            for _ in 0..<Int((segment.seconds / 0.02).rounded()) {
                time += 0.02
                let decision = endpointer.feed(level: segment.level, duration: 0.02)
                if decision != .listening { return (decision, time) }
            }
        }
        return nil
    }

    @Test func endsAfterTrailingSilence() {
        var endpointer = Endpointer(ambientFloor: -50)
        let result = run(&endpointer, [(-20, 1.5), (-50, 2)])
        #expect(result?.0 == .endOfSpeech)
        #expect(abs((result?.1 ?? 0) - 2.3) < 0.05)
    }

    @Test func shortPauseInsideSpeechDoesNotEnd() {
        var endpointer = Endpointer(ambientFloor: -50)
        #expect(run(&endpointer, [(-20, 1), (-50, 0.5), (-20, 1)]) == nil)
    }

    @Test func noSpeechCancelsAfterTwoSeconds() {
        var endpointer = Endpointer(ambientFloor: -50)
        let result = run(&endpointer, [(-50, 3)])
        #expect(result?.0 == .noSpeech)
        #expect(abs((result?.1 ?? 0) - 2.0) < 0.05)
    }

    @Test func hardCapAtTenSeconds() {
        var endpointer = Endpointer(ambientFloor: -50)
        let result = run(&endpointer, [(-20, 12)])
        #expect(result?.0 == .endOfSpeech)
        #expect(abs((result?.1 ?? 0) - 10) < 0.05)
    }

    /// With music at -30 dB, the same -30 dB must count as quiet, or the
    /// microphone would never close.
    @Test func loudRoomStillEnds() {
        var endpointer = Endpointer(ambientFloor: -30)
        #expect(run(&endpointer, [(-12, 1.5), (-30, 2)])?.0 == .endOfSpeech)
    }

    @Test func calibratesFromFirst200msWithoutAmbient() {
        var endpointer = Endpointer()
        #expect(run(&endpointer, [(-35, 0.2), (-15, 1), (-35, 1)])?.0 == .endOfSpeech)
    }

    @Test func nearSilentRoomIgnoresBreathing() {
        var endpointer = Endpointer(ambientFloor: -90)
        // -55 dB is under the -60 floor clamp + 10 dB margin: not speech.
        #expect(run(&endpointer, [(-55, 3)])?.0 == .noSpeech)
    }
}
