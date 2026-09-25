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
            Image(systemName: delegate.status.menuBarSymbol)
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
