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
        // Recording during a call starts here or with ⌥Space: the wake word
        // is paused while another app uses the microphone.
        if status.capture != nil {
            Button("Stop Recording") { status.onStopCapture?() }
        } else {
            Button("Transcribe This Meeting or Call") { Task { _ = try? await LiveCapture.shared.startTranscript() } }
            Button("Dictate into Notes") { Task { try? await LiveCapture.shared.startDictation(toNotes: true) } }
        }
        if let call = status.callApp {
            Text("\(call) is using the microphone: not listening for “\(WakePhrase.displayName)”")
        }
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
                let days = alarm.repeatDays.map { " " + AlarmRepeat.describe($0) } ?? ""
                let when = alarm.repeatDays == nil ? ClockFormat.when(alarm.fireDate) : alarm.fireDate.formatted(date: .omitted, time: .shortened)
                Menu("Alarm \(when)\(days)\(alarm.label.map { ": \($0)" } ?? "")\(alarm.isEnabled ? "" : " (off)")") {
                    Button(alarm.isEnabled ? "Turn Off" : "Turn On") { store.setEnabled(alarm.id, !alarm.isEnabled) }
                    Button("Delete Alarm") { store.remove([alarm.id]) }
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
