import Foundation
import NotchAssistantCore
import Observation
import SwiftUI

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
    /// The answer on screen before Alfred started listening again, kept in
    /// view underneath "Listening".
    var previousOutcome: String?
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
    /// Hand gestures, for Settings: "Off", "Watching for gestures", …
    var gestureStatus = "Off"
    /// A row of a result list was clicked; its opaque id goes to the coordinator.
    @ObservationIgnored var onSelect: ((String) -> Void)?
    /// The Confirm (true) or Cancel (false) button for a batch of changes.
    @ObservationIgnored var onConfirm: ((Bool) -> Void)?
    /// A ringing alert's Snooze (true) or Stop (false) button.
    @ObservationIgnored var onAlert: ((Bool) -> Void)?
    /// Settings' "Test" buttons for the alarm and timer sounds.
    @ObservationIgnored var onTestAlert: ((Countdown.Kind) -> Void)?

    /// Timers, alarms and the stopwatch, for the menu bar.
    var clock = ClockSnapshot() {
        didSet { updateTicker() }
    }
    /// Recording or dictation in progress.
    var capture: CaptureStatus? {
        didSet { updateTicker() }
    }
    /// The app on a call (using the microphone), while the wake word waits.
    var callApp: String?
    /// Clicking the notch (or Stop) while recording or dictating.
    @ObservationIgnored var onStopCapture: (() -> Void)?
    /// Advances every second while a timer or the stopwatch runs, so the
    /// menu bar counts down; no ticking otherwise.
    private(set) var now = Date()
    @ObservationIgnored private var ticker: Timer?

    private func updateTicker() {
        now = Date()
        guard clock.isTicking || capture != nil else {
            ticker?.invalidate()
            ticker = nil
            return
        }
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    static let notchCountdownKey = "clock.showInNotch"

    /// The small pill beside the notch while idle: recording first, else a
    /// running timer.
    var idlePill: (symbol: String, tint: Color, text: String)? {
        if let capture {
            let elapsed = ClockFormat.clock(now.timeIntervalSince(capture.started))
            return capture.kind == .transcript ? ("record.circle.fill", .red, elapsed) : ("text.bubble.fill", .red, elapsed)
        }
        return notchCountdown.map { ($0.symbol, .orange, $0.text) }
    }

    /// The countdown pill beside the notch while idle: the soonest running
    /// timer, else a running stopwatch.
    var notchCountdown: (symbol: String, text: String)? {
        guard UserDefaults.standard.object(forKey: Self.notchCountdownKey) as? Bool ?? true,
              let text = menuBarCountdown else { return nil }
        return (clock.timers.contains { !$0.isPaused } ? "timer" : "stopwatch", text)
    }

    /// Shown beside the menu bar icon: the soonest running timer, else a
    /// running stopwatch.
    var menuBarCountdown: String? {
        if let timer = clock.timers.filter({ !$0.isPaused }).min(by: { $0.fireDate < $1.fireDate }) {
            return ClockFormat.clock(timer.remaining(at: now))
        }
        if clock.stopwatch.isRunning {
            return ClockFormat.clock(clock.stopwatch.elapsed(at: now))
        }
        return nil
    }

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
        case .confirm: "questionmark.circle.fill"
        case .alert: "alarm.fill"
        case .question: "questionmark.bubble.fill"
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
        case .result(let outcome), .reply(let outcome), .list(let outcome, _), .confirm(let outcome, _): outcome
        case .alert(let alert): alert.title
        case .question(let question): question
        case .error(let failure): failure.message
        }
    }
}
