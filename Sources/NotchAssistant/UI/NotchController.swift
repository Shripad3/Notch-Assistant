import AppKit
import Combine
import DynamicNotchKit
import NotchAssistantCore

/// Presents coordinator state in the notch. Decides only *how* to show a
/// state (hidden, compact pill, expanded), never the state itself.
///
/// - Idle: hidden, so no window exists to intercept clicks on the menu bar.
/// - Listening, Thinking, Acting: compact pill; expands while hovered.
/// - Result, Reply, List, Error: expanded, so the outcome can be read and
///   buttons clicked. They hide on the coordinator's timer, never held open
///   by hover.
@MainActor
final class NotchController: NotchPresenter {
    private enum Mode: Equatable { case hidden, compact, expanded }

    private struct Presentation: Equatable {
        var mode: Mode
        /// Nil with a visible mode means "on a screen that is gone": the
        /// next change must hide before showing again.
        var displayID: CGDirectDisplayID?

        static let hidden = Presentation(mode: .hidden, displayID: nil)
    }

    let status: StatusModel
    /// Called after every state change, for wiring outside the UI (Escape).
    var onChange: ((AssistantState) -> Void)?

    private let display: DisplayResolver
    private let speaker = Speaker()
    private lazy var chime = AlarmChime(speaker: speaker)
    private let notch: DynamicNotch<NotchExpandedView, NotchLeadingView, NotchTrailingView>
    private var desired = Presentation.hidden
    private var applied = Presentation.hidden
    private var pump: Task<Void, Never>?
    private var hoverWatch: AnyCancellable?

    init(status: StatusModel, display: DisplayResolver) {
        self.status = status
        self.display = display
        // No .keepVisible: with it, hide() waits until the pointer leaves,
        // and when a click opened a file in another app the "left" event
        // never came, leaving an empty notch on screen indefinitely.
        notch = DynamicNotch(hoverBehavior: [], style: .auto) {
            NotchExpandedView(status: status)
        } compactLeading: {
            NotchLeadingView(status: status)
        } compactTrailing: {
            NotchTrailingView(status: status)
        }
        notch.transitionConfiguration = .init(skipIntermediateHides: true)
        // @Sendable, so Swift inserts no main-actor check at entry: that
        // check crashed when SwiftUI delivered hover changes from inside a
        // nested event loop. The work itself hops to the main actor.
        hoverWatch = notch.$isHovering.removeDuplicates().dropFirst().sink { @Sendable [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func render(_ state: AssistantState) {
        if case .listening = state {} else { status.resetLevel() }
        status.state = state
        onChange?(state)
        refresh()
        if case .alert(let alert) = state {
            chime.start(alert)
        } else {
            chime.stop()
            speaker.speak(state, visible: desired.mode != .hidden)
        }
    }

    func audioLevel(_ level: Float) {
        status.receive(level: level)
    }

    /// Screens or display settings changed. Moves a visible notch in place
    /// when it can, and otherwise re-presents it (spec §5).
    func environmentChanged() {
        if applied.mode != .hidden {
            if let id = applied.displayID, let screen = Self.screen(id), notch.reposition(on: screen) {
                // Moved in place.
            } else {
                applied.displayID = nil
            }
        }
        refresh()
    }

    private func refresh() {
        desired = desiredPresentation()
        guard pump == nil, desired != applied else { return }
        // One transition at a time: DynamicNotch animations are async, and
        // interleaving them leaves the window in the wrong state.
        pump = Task { [weak self] in
            while let self, self.desired != self.applied {
                let target = self.desired
                await self.transition(to: target)
                self.applied = target
            }
            self?.pump = nil
        }
    }

    private func desiredPresentation() -> Presentation {
        guard status.state != .idle else { return .hidden }

        if let screen = display.targetScreen {
            let mode: Mode = switch status.state {
            case .result, .reply, .list, .confirm, .alert, .error: .expanded
            default: notch.isHovering ? .expanded : .compact
            }
            return Presentation(mode: mode, displayID: screen.displayID)
        }
        // No notched screen. The floating style has no compact form, so it
        // is always expanded.
        guard DisplayFallback.current == .floating, let screen = display.fallbackScreen else { return .hidden }
        return Presentation(mode: .expanded, displayID: screen.displayID)
    }

    private func transition(to target: Presentation) async {
        guard target.mode != .hidden, let id = target.displayID, let screen = Self.screen(id) else {
            await notch.hide()
            return
        }
        if applied.mode != .hidden, applied.displayID != id {
            await notch.hide()
        }
        switch target.mode {
        case .compact: await notch.compact(on: screen)
        case .expanded: await notch.expand(on: screen)
        case .hidden: break
        }
    }

    private static func screen(_ id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == id }
    }
}
