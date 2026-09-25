import Foundation

/// A failure the user can read. Every error that reaches the UI is converted
/// to one of these so the error state always has a legible reason (goal 5).
public struct AssistantFailure: Error, LocalizedError, Sendable, Equatable {
    public let message: String
    public let settingsLink: SystemSettingsPane?

    public init(_ message: String, link: SystemSettingsPane? = nil) {
        self.message = message
        self.settingsLink = link
    }

    public init(_ error: any Error) {
        switch error {
        case let failure as AssistantFailure:
            self = failure
        case let error as LocalizedError:
            self.init(error.errorDescription ?? String(describing: error))
        default:
            self.init(String(describing: error))
        }
    }

    public var errorDescription: String? { message }
}
