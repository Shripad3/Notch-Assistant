import AppKit
import NotchAssistantCore
import SwiftUI

@main
struct NotchAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            StatusMenu(status: delegate.status, delegate: delegate)
        } label: {
            // A running timer counts down beside the icon.
            if let countdown = delegate.status.menuBarCountdown {
                Text("\(Image(systemName: delegate.status.menuBarSymbol)) \(countdown)")
                    .monospacedDigit()
            } else {
                Image(systemName: delegate.status.menuBarSymbol)
            }
        }
    }
}

private struct StatusMenu: View {
    @Bindable var status: StatusModel
    let delegate: AppDelegate

    var body: some View {
        Text(status.menuDetail)
        if case .error(let failure) = status.state, let link = failure.settingsLink {
            Button("Open System Settings…") { NSWorkspace.shared.open(link.url) }
        }
        ClockMenu(status: status)
        Divider()
        Text("Hold ⌥Space and speak")
        // Kill switch (spec §10): suspends all activation immediately.
        Toggle("Pause Listening", isOn: $status.isPaused)
        #if DEBUG
        Button("Preview Notch States") { delegate.previewStates() }
        #endif
        Divider()
        Button("Settings…") { delegate.showSettings() }
        .keyboardShortcut(",")
        Button("Quit Notch Assistant") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Running timers, alarms and the stopwatch, each with its controls.
private struct ClockMenu: View {
    let status: StatusModel
    private let store = ClockStore.shared

    var body: some View {
        let clock = status.clock
        if !clock.isEmpty {
            Divider()
            ForEach(clock.timers) { timer in
                Menu("\(Self.capitalized(timer.name)): \(ClockFormat.clock(timer.remaining(at: status.now)))\(timer.isPaused ? " (paused)" : "")") {
                    Button(timer.isPaused ? "Resume" : "Pause") {
                        timer.isPaused ? store.resume(timer.id) : store.pause(timer.id)
                    }
                    Button("Cancel Timer") { store.remove([timer.id]) }
                }
            }
            ForEach(clock.alarms.sorted { $0.fireDate < $1.fireDate }) { alarm in
                Menu("Alarm \(ClockFormat.when(alarm.fireDate))\(alarm.label.map { ": \($0)" } ?? "")") {
                    Button("Cancel Alarm") { store.remove([alarm.id]) }
                }
            }
            if !clock.stopwatch.isIdle {
                Menu("Stopwatch: \(ClockFormat.clock(clock.stopwatch.elapsed(at: status.now)))") {
                    Button(clock.stopwatch.isRunning ? "Stop" : "Resume") { store.toggleStopwatch() }
                    Button("Reset") { store.resetStopwatch() }
                }
            }
        }
    }

    private static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}
