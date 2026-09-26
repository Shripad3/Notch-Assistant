import NotchAssistantCore
import UserNotifications

/// Backup notifications for timers and alarms, for when the app isn't
/// running to ring them itself. Permission is asked the first time one is
/// scheduled.
final class SystemClockNotifier: NSObject, ClockNotifier, UNUserNotificationCenterDelegate, @unchecked Sendable {
    // @unchecked: UNUserNotificationCenter is thread-safe; no other state.
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    func schedule(_ items: [ClockNotification]) {
        let center = center
        Task {
            let pending = await center.pendingNotificationRequests().map(\.identifier)
            center.removePendingNotificationRequests(withIdentifiers: pending)
            guard !items.isEmpty, await authorized() else { return }
            for item in items {
                let seconds = max(1, item.date.timeIntervalSinceNow)
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
                try? await center.add(UNNotificationRequest(identifier: item.id, content: content(item), trigger: trigger))
            }
        }
    }

    func deliverNow(_ item: ClockNotification) {
        let center = center
        Task {
            guard await authorized() else { return }
            try? await center.add(UNNotificationRequest(identifier: item.id, content: content(item), trigger: nil))
        }
    }

    private func authorized() async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional: return true
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default: return false
        }
    }

    private func content(_ item: ClockNotification) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = item.title
        content.body = item.body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        return content
    }

    /// Show banners even while the app is active.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
