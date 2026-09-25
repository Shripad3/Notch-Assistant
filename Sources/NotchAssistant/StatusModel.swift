import NotchAssistantCore
import Observation

/// Observable state shared by the notch views and the menu bar. Written only
/// by `NotchController`; views never decide state.
enum WakeStatus: Equatable {
    case off
    case listening
    case paused(String)
    case unavailable(String)

    var description: String {
        switch self {
        case .off: "Off"
        case .listening: "Listening for “Alfred”"
        case .paused(let reason): "Paused: \(reason)"
        case .unavailable(let reason): "Unavailable: \(reason)"
        }
    }
}

@MainActor
@Observable
final class StatusModel {
    var state: AssistantState = .idle
    /// Smoothed microphone level, 0...1.
    private(set) var level: Float = 0
    /// Menu bar kill switch.
    var isPaused = false {
        didSet { if isPaused != oldValue { onPausedChange?() } }
    }
    @ObservationIgnored var onPausedChange: (() -> Void)?
    /// True while the "Disable" display fallback applies.
    var isSuspendedByDisplay = false
    /// Hands-free listening, for the menu bar and Settings.
    var wakeStatus: WakeStatus = .off
    /// A row of a result list was clicked; its opaque id goes to the coordinator.
    @ObservationIgnored var onSelect: ((String) -> Void)?

    func receive(level newLevel: Float) {
        // Rise instantly, fall gently, so the bars don't flicker.
        level = max(newLevel, level * 0.8)
    }

    func resetLevel() {
        level = 0
    }

    var menuBarSymbol: String {
        if isPaused || isSuspendedByDisplay { return "mic.slash" }
        return switch state {
        case .idle: wakeStatus == .listening ? "ear" : "waveform"
        case .listening: "mic.fill"
        case .thinking: "ellipsis.circle"
        case .acting: "bolt.fill"
        case .result: "checkmark.circle.fill"
        case .reply: "text.bubble.fill"
        case .list: "list.bullet"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    var menuDetail: String {
        if isPaused { return "Paused" }
        if isSuspendedByDisplay { return "Suspended until the built-in display is back" }
        return switch state {
        case .idle: wakeStatus == .listening ? "Listening for “Alfred”" : "Idle"
        case .listening(let partial): partial.isEmpty ? "Listening…" : "“\(partial)”"
        case .thinking(let transcript): "Thinking: “\(transcript)”"
        case .acting(let tool, let target): "\(tool.title): \(target)"
        case .result(let outcome), .reply(let outcome), .list(let outcome, _): outcome
        case .error(let failure): failure.message
        }
    }
}
