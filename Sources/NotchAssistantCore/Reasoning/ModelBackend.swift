import FoundationModels
import Synchronization

/// What a model call is for. The router picks a backend per task, so a
/// larger local model can later take summaries and analysis while Apple's
/// on-device model keeps the fast paths.
public enum ModelTask: String, CaseIterable, Sendable {
    /// A spoken command into a plan of tool calls.
    case intent
    /// Talking with Alfred.
    case conversation
    /// Transcripts, conversation memory, documents.
    case summarize
    /// Reading content and answering about it; tolerates latency.
    case analysis
}

/// Why a model call failed, in terms the app can act on.
public enum ModelError: Error, Sendable, Equatable {
    case contextOverflow
    case refused
    case unavailable(AssistantFailure)
    case unsupportedLanguage
    case other(String)

    /// What to tell the user.
    public var failure: AssistantFailure {
        switch self {
        case .contextOverflow: AssistantFailure("That was too long for the on-device model")
        case .refused: AssistantFailure("The model declined that request")
        case .unavailable(let failure): failure
        case .unsupportedLanguage: AssistantFailure("The on-device model doesn't support this language")
        case .other(let message): AssistantFailure(message)
        }
    }
}

/// One model, behind which prompts and schemas stay the same. Structured
/// output is described with FoundationModels' `@Generable` types and
/// `GenerationSchema`, which every tool already uses to declare its
/// arguments; a backend that isn't Apple's translates from those.
public protocol ModelBackend: Sendable {
    var identifier: String { get }
    /// Nil when usable; otherwise why not, with a Settings link.
    var unavailableReason: AssistantFailure? { get }
    /// Tokens, shared between input and output.
    var contextWindow: Int { get }

    func respond(system: String, prompt: String, temperature: Double?) async throws(ModelError) -> String
    func respond<T: Generable & Sendable>(system: String, prompt: String, generating type: T.Type) async throws(ModelError) -> T
    /// Output constrained to a schema built at run time (the command plan).
    func respond(system: String, prompt: String, schema: GenerationSchema, deterministic: Bool) async throws(ModelError) -> GeneratedContent
    /// A multi-turn conversation that remembers what was said.
    func chat(system: String) -> any ChatSession
}

public protocol ChatSession: Sendable {
    func send(_ text: String, temperature: Double?) async throws(ModelError) -> String
}

/// Which backend each task uses. Today every task uses Apple's on-device
/// model; this is where a larger local model would be plugged in.
public enum ModelRouter {
    private static let override = Mutex<(any ModelBackend)?>(nil)

    public static func backend(for task: ModelTask) -> any ModelBackend {
        override.withLock { $0 } ?? AppleFoundationBackend.shared
    }

    /// Tests and previews: one backend for every task (nil restores).
    static func use(_ backend: (any ModelBackend)?) {
        override.withLock { $0 = backend }
    }
}
