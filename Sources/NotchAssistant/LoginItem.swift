import NotchAssistantCore
import ServiceManagement

/// Open at login, through the system's login items (System Settings →
/// General → Login Items). On by default the first time the app runs, since
/// timers and alarms only ring while it's running; turned off in Settings.
@MainActor
enum LoginItem {
    private static let offeredKey = "loginItem.offered"

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// The user must allow it in System Settings before it takes effect.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.app.error("login item: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func enableOnFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: offeredKey) else { return }
        UserDefaults.standard.set(true, forKey: offeredKey)
        set(true)
    }
}
