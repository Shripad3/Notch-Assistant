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
    case appleIntelligence

    public var url: URL {
        switch self {
        case .appleIntelligence:
            URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!
        default:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")!
        }
    }
}
