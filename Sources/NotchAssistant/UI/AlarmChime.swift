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
        let sound = NSSound(named: AlarmSounds.chosen(for: alert.kind))
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

/// The system sounds offered for timers and alarms.
enum AlarmSounds {
    static func key(for kind: Countdown.Kind) -> String {
        kind == .timer ? "clock.sound.timer" : "clock.sound.alarm"
    }

    static func defaultSound(for kind: Countdown.Kind) -> String {
        kind == .timer ? "Glass" : "Hero"
    }

    static func chosen(for kind: Countdown.Kind) -> String {
        let name = UserDefaults.standard.string(forKey: key(for: kind)) ?? ""
        return all.contains(name) ? name : defaultSound(for: kind)
    }

    /// "Basso", "Glass", "Hero"… from /System/Library/Sounds.
    static let all: [String] = {
        let folder = URL(filePath: "/System/Library/Sounds")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }()
}
