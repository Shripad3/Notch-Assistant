import AVFoundation

/// When to speak outcomes aloud (spec §7).
public enum SpokenResponses: String, CaseIterable, Sendable {
    case always, errorsOnly, never

    public static let defaultsKey = "speech.responses"

    public static var current: SpokenResponses {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(SpokenResponses.init(rawValue:)) ?? .errorsOnly
    }

    public var title: String {
        switch self {
        case .always: "Always"
        case .errorsOnly: "Errors only"
        case .never: "Never"
        }
    }
}

/// A system voice the user can choose. Premium and Enhanced voices sound far
/// less robotic than the default ones; they are free, on-device downloads in
/// System Settings › Accessibility › Spoken Content.
public struct VoiceOption: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let accent: String
    public let quality: String

    public static let defaultsKey = "speech.voice"

    /// English voices plus any in the user's own languages, best first.
    public static func available() -> [VoiceOption] {
        let languages = Set(Locale.preferredLanguages.map { String($0.prefix(2)) } + ["en"])
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { languages.contains(String($0.language.prefix(2))) }
            .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
            .map { voice in
                let quality = switch voice.quality {
                case .premium: "Premium"
                case .enhanced: "Enhanced"
                default: "Basic"
                }
                return VoiceOption(
                    id: voice.identifier,
                    name: voice.name,
                    accent: Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language,
                    quality: quality
                )
            }
    }

    /// The chosen voice, else the best-quality voice in the user's language.
    static func preferred() -> AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: defaultsKey), let voice = AVSpeechSynthesisVoice(identifier: id) {
            return voice
        }
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == language }
            .max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: language)
    }
}

/// A voice beyond the system's: Kokoro, run by the app. Chosen in Settings
/// as a voice id starting with `neuralPrefix`.
@MainActor
public protocol NeuralVoice: AnyObject {
    /// Chosen in Settings and downloaded.
    var isActive: Bool { get }
    /// Speaks and returns when done. False if it couldn't (the system voice
    /// is used instead).
    func speak(_ text: String) async -> Bool
    func stop()
    /// Loads the model ahead of speaking, e.g. while the user talks.
    func warmUp()
}

/// Text to speech with a system voice, or the natural voice when chosen.
/// Speaks only when the result is not self-evident: an app launching needs
/// no narration, a failure does.
@MainActor
public final class Speaker {
    /// Voice ids for the natural voice: "kokoro:bm_george".
    public static let neuralPrefix = "kokoro:"
    /// Set by the app at launch.
    public static var neural: (any NeuralVoice)?

    private let synthesizer = AVSpeechSynthesizer()
    private var neuralTask: Task<Void, Never>?

    public init() {}

    /// `visible` is false when there is no notch to show the outcome in
    /// (the Hide display fallback); feedback is then spoken instead.
    public func speak(_ state: AssistantState, visible: Bool) {
        let mode = SpokenResponses.current
        let text: String
        switch state {
        case .listening:
            stop()
            // The reply comes a few seconds from now: load the voice while
            // the user speaks.
            Self.neural?.warmUp()
            return
        case .result(let outcome) where mode == .always || (mode == .errorsOnly && !visible):
            text = outcome
        case .error(let failure) where mode != .never:
            text = failure.message
        case .reply(let answer) where mode != .never:
            text = answer
        default:
            return
        }
        say(text)
    }

    /// Speaks regardless of the Speak responses setting (voice preview).
    public func say(_ text: String) {
        stop()
        if let neural = Self.neural, neural.isActive {
            neuralTask = Task { [weak self] in
                let spoke = await neural.speak(text)
                if !spoke, !Task.isCancelled { self?.sayWithSystemVoice(text) }
            }
            return
        }
        sayWithSystemVoice(text)
    }

    private func sayWithSystemVoice(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = VoiceOption.preferred()
        synthesizer.speak(utterance)
    }

    public func stop() {
        neuralTask?.cancel()
        neuralTask = nil
        Self.neural?.stop()
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }
}
