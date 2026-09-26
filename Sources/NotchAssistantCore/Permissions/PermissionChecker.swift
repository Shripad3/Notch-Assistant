import ApplicationServices
import AVFoundation
import EventKit
import FoundationModels
import Speech
import UserNotifications

public enum PermissionStatus: Sendable, Equatable {
    case granted
    case denied
    case notRequested
    /// macOS offers no way to read this grant; it is asked for when a tool
    /// first needs it.
    case askedOnFirstUse
    /// The check didn't answer in time.
    case unknown
}

public struct PermissionItem: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let neededFor: String
    public let link: SystemSettingsPane
    public let status: PermissionStatus
}

/// Live status for every grant the app uses or will use (spec §10). Read
/// fresh on every call: grants can be revoked while the app runs. Async
/// because the Automation checks must never run on the main thread.
public enum PermissionChecker {
    public static func all() async -> [PermissionItem] {
        async let spotify = automation("com.spotify.client")
        async let systemEvents = automation("com.apple.systemevents")
        async let shortcuts = automation("com.apple.shortcuts.events")
        async let notes = automation("com.apple.Notes")
        let spotifyStatus = await spotify
        let systemEventsStatus = await systemEvents
        let shortcutsStatus = await shortcuts
        let notesStatus = await notes
        return [
            PermissionItem(id: "microphone", title: "Microphone", neededFor: "All voice input",
                           link: .microphone, status: capture(.audio)),
            PermissionItem(id: "speech", title: "Speech Recognition", neededFor: "Turning speech into text, on this Mac",
                           link: .speechRecognition, status: speech()),
            PermissionItem(id: "accessibility", title: "Accessibility", neededFor: "Brightness, locking the screen, arranging windows, pasting; YouTube auto-play",
                           link: .accessibility, status: AXIsProcessTrusted() ? .granted : .notRequested),
            PermissionItem(id: "automation.spotify", title: "Automation: Spotify", neededFor: "Playing and pausing music",
                           link: .automation, status: spotifyStatus),
            PermissionItem(id: "automation.systemevents", title: "Automation: System Events", neededFor: "Putting the Mac to sleep",
                           link: .automation, status: systemEventsStatus),
            PermissionItem(id: "automation.shortcuts", title: "Automation: Shortcuts", neededFor: "Do Not Disturb, routines",
                           link: .automation, status: shortcutsStatus),
            PermissionItem(id: "automation.notes", title: "Automation: Notes", neededFor: "Quick notes by voice",
                           link: .automation, status: notesStatus),
            PermissionItem(id: "calendars", title: "Calendars", neededFor: "Reading your calendar aloud (Apple Calendar)",
                           link: .calendars, status: calendars()),
            PermissionItem(id: "reminders", title: "Reminders", neededFor: "Adding reminders by voice",
                           link: .reminders, status: reminders()),
            PermissionItem(id: "notifications", title: "Notifications", neededFor: "Timers and alarms, if the app isn't running when they're due",
                           link: .notifications, status: await notifications()),
            PermissionItem(id: "files", title: "Files and Folders", neededFor: "File search and open (v2), metadata only",
                           link: .filesAndFolders, status: .askedOnFirstUse),
            PermissionItem(id: "camera", title: "Camera", neededFor: "Gestures only (v4)",
                           link: .camera, status: capture(.video)),
        ]
    }

    /// Nil when the on-device model is usable.
    public static func appleIntelligenceProblem() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.appleIntelligenceNotEnabled): "Turned off, or the Mac and Siri languages don't match"
        case .unavailable(.modelNotReady): "Model still downloading"
        case .unavailable(.deviceNotEligible): "Not supported on this Mac"
        case .unavailable: "Unavailable"
        }
    }

    private static func automation(_ bundleIdentifier: String) async -> PermissionStatus {
        switch await AutomationStatus.check(bundleIdentifier: bundleIdentifier) {
        case .granted: .granted
        case .denied: .denied
        case .notRequested: .notRequested
        case .targetNotRunning: .askedOnFirstUse
        case .unknown: .unknown
        }
    }

    private static func capture(_ type: AVMediaType) -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: .granted
        case .notDetermined: .notRequested
        default: .denied
        }
    }

    private static func calendars() -> PermissionStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .askedOnFirstUse
        default: .denied
        }
    }

    private static func reminders() -> PermissionStatus {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: .granted
        case .notDetermined: .askedOnFirstUse
        default: .denied
        }
    }

    /// Read only inside the app: UserNotifications needs a bundle.
    private static func notifications() async -> PermissionStatus {
        guard Bundle.main.bundleIdentifier != nil else { return .unknown }
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional: return .granted
        case .notDetermined: return .askedOnFirstUse
        default: return .denied
        }
    }

    private static func speech() -> PermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .granted
        case .notDetermined: .notRequested
        default: .denied
        }
    }
}
