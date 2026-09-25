import AppKit
import NotchAssistantCore
import SwiftUI

/// Opens the Settings window directly. SwiftUI's `openSettings` is unreliable
/// from a menu-bar-only (LSUIElement) app: it can do nothing at all, or open
/// the window behind other apps.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let status: StatusModel

    init(status: StatusModel) {
        self.status = status
    }

    func show() {
        Log.app.notice("settings: show requested")
        // Called from a menu item: let the menu finish closing first, or the
        // activation and ordering below are lost to menu tracking.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            present()
        }
    }

    private func present() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.contentViewController = NSHostingController(rootView: SettingsView(status: status))
            window.title = "Notch Assistant Settings"
            // Sidebar runs to the top edge, as in System Settings.
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        guard let window else { return }
        // An accessory app is not active, and a plain activate() may be
        // declined by cooperative activation; ordering front regardless
        // guarantees the window is at least visible.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        Log.app.notice("settings: window on screen \(window.isVisible, privacy: .public) at \(NSStringFromRect(window.frame), privacy: .public)")
    }
}
