import FoundationModels

/// Apple's on-device model (Apple Intelligence), the only place in the app
/// that creates a `LanguageModelSession`.
public struct AppleFoundationBackend: ModelBackend {
    public static let shared = AppleFoundationBackend()

    public let identifier = "apple.foundation"
    /// The system model's context: 4,096 tokens for input and output
    /// together (macOS 26).
    public let contextWindow = 4_096

    public var unavailableReason: AssistantFailure? {
        switch SystemLanguageModel.default.availability {
        case .available:
            nil
        case .unavailable(.appleIntelligenceNotEnabled):
            AssistantFailure("Apple Intelligence is off, or the Mac and Siri languages don't match", link: .appleIntelligence)
        case .unavailable(.modelNotReady):
            AssistantFailure("The on-device model is still downloading", link: .appleIntelligence)
        case .unavailable(.deviceNotEligible):
            AssistantFailure("This Mac can't run Apple Intelligence")
        case .unavailable:
            AssistantFailure("The on-device model is unavailable", link: .appleIntelligence)
        }
    }

    /// For Settings: a short status, nil when ready.
    public static var statusProblem: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.appleIntelligenceNotEnabled): "Turned off, or the Mac and Siri languages don't match"
        case .unavailable(.modelNotReady): "Model still downloading"
        case .unavailable(.deviceNotEligible): "Not supported on this Mac"
        case .unavailable: "Unavailable"
        }
    }

    public func respond(system: String, prompt: String, temperature: Double?) async throws(ModelError) -> String {
        try await run {
            try await LanguageModelSession(instructions: system)
                .respond(to: prompt, options: GenerationOptions(temperature: temperature)).content
        }
    }

    public func respond<T: Generable & Sendable>(system: String, prompt: String, generating type: T.Type) async throws(ModelError) -> T {
        try await run {
            try await LanguageModelSession(instructions: system).respond(to: prompt, generating: type).content
        }
    }

    public func respond(system: String, prompt: String, schema: GenerationSchema, deterministic: Bool) async throws(ModelError) -> GeneratedContent {
        try await run {
            try await LanguageModelSession(instructions: system).respond(
                to: prompt,
                schema: schema,
                options: GenerationOptions(sampling: deterministic ? .greedy : nil)
            ).content
        }
    }

    public func chat(system: String) -> any ChatSession {
        AppleChat(session: LanguageModelSession(instructions: system))
    }

    /// Runs a call, turning the framework's errors into `ModelError`.
    fileprivate func run<T: Sendable>(_ call: @Sendable () async throws -> T) async throws(ModelError) -> T {
        if let unavailableReason { throw .unavailable(unavailableReason) }
        do {
            return try await call()
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.map(error)
        } catch let error as ModelError {
            throw error
        } catch {
            throw .other(error.localizedDescription)
        }
    }

    static func map(_ error: LanguageModelSession.GenerationError) -> ModelError {
        switch error {
        case .exceededContextWindowSize: .contextOverflow
        case .guardrailViolation, .refusal: .refused
        case .assetsUnavailable: .unavailable(AssistantFailure("The on-device model is unavailable", link: .appleIntelligence))
        case .unsupportedLanguageOrLocale: .unsupportedLanguage
        default: .other("The model couldn't make sense of that")
        }
    }
}

/// One conversation's session: it keeps the turns so far.
private final class AppleChat: ChatSession, @unchecked Sendable {
    // @unchecked: the session is only used by one conversation at a time,
    // awaited turn by turn (`Conversation` is an actor).
    private let session: LanguageModelSession

    init(session: LanguageModelSession) {
        self.session = session
    }

    func send(_ text: String, temperature: Double?) async throws(ModelError) -> String {
        let session = session
        return try await AppleFoundationBackend.shared.run {
            try await session.respond(to: text, options: GenerationOptions(temperature: temperature)).content
        }
    }
}
