import Foundation
@testable import NotchAssistantCore
import Testing

/// Spec §6 budgets the wake word at ~1–3% of one core. Measures the detector
/// alone on 30 s of audio (conversion and capture add a little on top).
struct WakeWordCostTests {
    @Test func realTimeFactor() throws {
        let detector = try WakeWordDetectorTests.detector()
        let seconds = 30
        let audio = (0..<(WakeWordDetector.sampleRate * seconds)).map { _ in Int16.random(in: -800...800) }
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            for start in stride(from: 0, to: audio.count, by: WakeWordDetector.chunkSize) {
                _ = try detector.process(Array(audio[start..<start + WakeWordDetector.chunkSize]))
            }
        }
        let share = elapsed / .seconds(seconds)
        print("wake word cost: \(elapsed) for \(seconds) s of audio = \(String(format: "%.2f", share * 100))% of one core")
        #expect(share < 0.05)
    }
}
