import AppKit
import NotchAssistantCore
import SwiftUI

// What each state shows (spec §4):
//
// | State     | Collapsed pill        | Expanded                        |
// | Listening | mic + live level bars | partial transcript              |
// | Thinking  | shimmer               | final transcript                |
// | Acting    | tool icon             | tool name and target            |
// | Result    | checkmark             | one-line outcome                |
// | Error     | amber glyph           | reason + settings button        |

/// Left of the notch in the compact pill.
struct NotchLeadingView: View {
    let status: StatusModel

    var body: some View {
        if status.state == .idle, let pill = status.idlePill {
            Image(systemName: pill.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(pill.tint)
                .symbolEffect(.pulse, options: .repeating, isActive: status.capture != nil)
                .contentShape(.rect)
                .onTapGesture { if status.capture != nil { status.onStopCapture?() } }
        } else {
            StateGlyph(state: status.state)
                .font(.system(size: 13, weight: .semibold))
        }
    }
}

/// Right of the notch in the compact pill.
struct NotchTrailingView: View {
    let status: StatusModel

    var body: some View {
        Group {
            switch status.state {
            case .listening:
                AudioBars(level: status.level)
            case .thinking, .acting:
                Shimmer()
            case .idle:
                if let pill = status.idlePill {
                    Text(pill.text)
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: status.capture == nil))
                        .animation(.default, value: pill.text)
                        .contentShape(.rect)
                        .onTapGesture { if status.capture != nil { status.onStopCapture?() } }
                }
            default:
                EmptyView()
            }
        }
        .foregroundStyle(.white)
    }
}

/// Below the notch when expanded, and the whole panel in floating style.
struct NotchExpandedView: View {
    let status: StatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if status.state == .idle {
                if let capture = status.capture {
                    CaptureRow(capture: capture, now: status.now) { status.onStopCapture?() }
                }
                ClockList(status: status)
            } else {
                row
            }
            if case .list(_, let items) = status.state {
                ResultList(items: items) { status.onSelect?($0) }
            }
            if case .alert(let alert) = status.state {
                HStack {
                    Text("Or say “Alfred, stop”\(alert.canSnooze ? " / “snooze”" : "")")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if alert.canSnooze {
                        Button("Snooze \(ClockStore.snoozeMinutes) min") { status.onAlert?(true) }
                    }
                    Button("Stop") { status.onAlert?(false) }
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.small)
            }
            if case .confirm(_, let items) = status.state {
                ResultList(items: items, select: nil)
                HStack {
                    Text("Or say “Alfred, yes” / “no”")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { status.onConfirm?(false) }
                    Button("Confirm") { status.onConfirm?(true) }
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.small)
            }
        }
        .frame(width: 380)
        .foregroundStyle(.primary)
        .environment(\.colorScheme, .dark)
    }

    private var row: some View {
        HStack(spacing: 12) {
            StateGlyph(state: status.state)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(heading)
                    .font(.system(size: 13, weight: .semibold))
                    // Answers (summaries, readings) get room; states stay short.
                    .lineLimit(isAnswer ? 8 : 2)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
    }

    @ViewBuilder private var trailing: some View {
        switch status.state {
        case .listening:
            AudioBars(level: status.level)
        case .thinking, .acting:
            Shimmer()
        case .error(let failure):
            if let link = failure.settingsLink {
                Button("Open Settings") { NSWorkspace.shared.open(link.url) }
                    .controlSize(.small)
            }
        default:
            EmptyView()
        }
    }

    private var isAnswer: Bool {
        if case .reply = status.state { true } else { false }
    }

    private var heading: String {
        switch status.state {
        case .idle: ""
        case .listening: "Listening"
        case .thinking: "Thinking"
        case .acting(let tool, _): tool.title
        case .result(let outcome), .reply(let outcome), .list(let outcome, _), .confirm(let outcome, _): outcome
        case .alert(let alert): alert.title
        case .question(let question): question
        case .error(let failure): failure.message
        }
    }

    private var detail: String? {
        switch status.state {
        case .alert(let alert): alert.message
        case .listening(let partial): partial.isEmpty ? status.previousOutcome : partial
        case .thinking(let transcript): "“\(transcript)”"
        case .acting(_, let target): target.isEmpty ? nil : target
        default: nil
        }
    }
}

struct StateGlyph: View {
    let state: AssistantState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .listening:
            Image(systemName: "mic.fill").foregroundStyle(.white)
        case .thinking:
            Image(systemName: "sparkles").foregroundStyle(.white)
        case .acting(let tool, _):
            Image(systemName: tool.symbol).foregroundStyle(.white)
        case .result:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .reply:
            Image(systemName: "text.bubble.fill").foregroundStyle(.white)
        case .list:
            Image(systemName: "list.bullet").foregroundStyle(.white)
        case .confirm:
            Image(systemName: "questionmark.circle.fill").foregroundStyle(.yellow)
        case .question:
            Image(systemName: "questionmark.bubble.fill").foregroundStyle(.white)
        case .alert(let alert):
            Image(systemName: alert.kind == .timer ? "timer" : "alarm.fill")
                .foregroundStyle(.orange)
                .symbolEffect(.wiggle, options: .repeating)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

/// Found files, one per row. Clicking a row sends its opaque id to the
/// coordinator, which opens it through the executor.
struct ResultList: View {
    let items: [ResultItem]
    /// Nil shows the rows without making them clickable (a confirmation).
    let select: ((String) -> Void)?

    var body: some View {
        VStack(spacing: 2) {
            ForEach(items) { item in
                ResultRow(item: item, action: select.map { select in { select(item.id) } })
            }
        }
    }
}

private struct ResultRow: View {
    let item: ResultItem
    let action: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        Button(action: action ?? {}) {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(item.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(item.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isHovered && action != nil ? Color.white.opacity(0.12) : .clear, in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .onHover { isHovered = $0 }
    }
}

/// Five bars driven by the microphone level.
struct AudioBars: View {
    let level: Float
    private let weights: [CGFloat] = [0.5, 0.8, 1, 0.8, 0.5]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(weights.indices, id: \.self) { index in
                Capsule()
                    .fill(.white)
                    .frame(width: 3, height: 3 + 11 * weights[index] * CGFloat(level))
            }
        }
        .frame(height: 14)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

/// Indeterminate activity for Thinking and Acting.
struct Shimmer: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .symbolEffect(.variableColor.iterative, options: .repeating)
    }
}

/// The expanded countdown pill: every running timer and the stopwatch,
/// each with a way to stop it.
private struct ClockList: View {
    let status: StatusModel
    private let store = ClockStore.shared

    var body: some View {
        VStack(spacing: 2) {
            ForEach(status.clock.timers) { timer in
                row(symbol: "timer", title: timer.name.prefix(1).uppercased() + timer.name.dropFirst(),
                    detail: ClockFormat.clock(timer.remaining(at: status.now)) + (timer.isPaused ? " · paused" : ""),
                    pause: { timer.isPaused ? store.resume(timer.id) : store.pause(timer.id) },
                    paused: timer.isPaused,
                    remove: { store.remove([timer.id]) })
            }
            if !status.clock.stopwatch.isIdle {
                let watch = status.clock.stopwatch
                row(symbol: "stopwatch", title: "Stopwatch",
                    detail: ClockFormat.stopwatch(watch.elapsed(at: status.now)) + (watch.isRunning ? "" : " · stopped"),
                    pause: { store.toggleStopwatch() },
                    paused: !watch.isRunning,
                    remove: { store.resetStopwatch() })
            }
        }
    }

    private func row(symbol: String, title: String, detail: String, pause: @escaping () -> Void, paused: Bool, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 22)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(detail)
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button(action: pause) { Image(systemName: paused ? "play.fill" : "pause.fill") }
                .buttonStyle(.borderless)
                .help(paused ? "Resume" : "Pause")
            Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Cancel")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
    }
}

/// Recording or dictation, with the latest words and a Stop button.
private struct CaptureRow: View {
    let capture: CaptureStatus
    let now: Date
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: capture.kind == .transcript ? "record.circle.fill" : "text.bubble.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.red)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(capture.lastLine.isEmpty ? "Listening…" : "…" + capture.lastLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            Button("Stop", action: stop)
                .controlSize(.small)
        }
        .padding(.horizontal, 4)
    }

    private var title: String {
        let elapsed = ClockFormat.clock(now.timeIntervalSince(capture.started))
        switch capture.kind {
        case .transcript: return "Recording · \(elapsed)"
        case .dictation(let toNotes): return (toNotes ? "Dictating into Notes · " : "Dictating · ") + elapsed
        case .screen: return "Recording the screen · \(elapsed)"
        }
    }
}
