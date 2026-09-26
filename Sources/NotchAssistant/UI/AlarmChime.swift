import AppKit
import NotchAssistantCore

/// The sound of a ringing timer or alarm: a chime, the message spoken once,
/// then the chime repeating until stopped. The coordinator ends the alert
/// after a minute, which stops it.
@MainActor
final class AlarmChime {
    private let speaker: Speaker
    private var task: Task<Void, Never>?
    private var ringing: ClockAlert.ID?

    init(speaker: Speaker) {
        self.speaker = speaker
    }

    func start(_ alert: ClockAlert) {
        guard ringing != alert.id else { return }
        stop()
        ringing = alert.id
        let sound = NSSound(named: alert.kind == .timer ? "Glass" : "Hero")
        task = Task { [speaker] in
            sound?.play()
            try? await Task.sleep(for: .seconds(1))
            if SpokenResponses.current != .never { speaker.say(alert.message) }
            try? await Task.sleep(for: .seconds(4))
            while !Task.isCancelled {
                sound?.stop()
                sound?.play()
                try? await Task.sleep(for: .seconds(1.6))
            }
        }
    }

    func stop() {
        guard ringing != nil else { return }
        ringing = nil
        task?.cancel()
        task = nil
        speaker.stop()
    }
}
