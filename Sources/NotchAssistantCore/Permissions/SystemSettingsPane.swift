import Foundation

/// Deep links into System Settings, used by error states and the
/// Permissions pane.
public enum SystemSettingsPane: String, Sendable, Equatable, CaseIterable {
    case microphone = "Privacy_Microphone"
    case speechRecognition = "Privacy_SpeechRecognition"
    case camera = "Privacy_Camera"
    case accessibility = "Privacy_Accessibility"
    case automation = "Privacy_Automation"
    case filesAndFolders = "Privacy_FilesAndFolders"
    case reminders = "Privacy_Reminders"
    case calendars = "Privacy_Calendars"
    case appleIntelligence
    case notifications

    public var url: URL {
        switch self {
        case .appleIntelligence:
            URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!
        case .notifications:
            URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        default:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")!
        }
    }
}
