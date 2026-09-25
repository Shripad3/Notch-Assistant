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
        StateGlyph(state: status.state)
            .font(.system(size: 13, weight: .semibold))
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
            row
            if case .list(_, let items) = status.state {
                ResultList(items: items) { status.onSelect?($0) }
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
                    .lineLimit(2)
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

    private var heading: String {
        switch status.state {
        case .idle: ""
        case .listening: "Listening"
        case .thinking: "Thinking"
        case .acting(let tool, _): tool.title
        case .result(let outcome), .reply(let outcome), .list(let outcome, _): outcome
        case .error(let failure): failure.message
        }
    }

    private var detail: String? {
        switch status.state {
        case .listening(let partial): partial.isEmpty ? nil : partial
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
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

/// Found files, one per row. Clicking a row sends its opaque id to the
/// coordinator, which opens it through the executor.
struct ResultList: View {
    let items: [ResultItem]
    let select: (String) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(items) { item in
                ResultRow(item: item) { select(item.id) }
            }
        }
    }
}

private struct ResultRow: View {
    let item: ResultItem
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
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
            .background(isHovered ? Color.white.opacity(0.12) : .clear, in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
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
