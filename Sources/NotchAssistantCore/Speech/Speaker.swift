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
    private var neuralSpeaking = false
    /// Counts interruptible utterances, so a finished one can't disarm the next.
    private var utterance = 0

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
        case .reply(let answer) where mode != .never, .chat(let answer) where mode != .never:
            text = answer
        case .question(let question) where mode != .never:
            text = question
        case .confirm(let question, _) where mode != .never:
            // "Send to Sam: …?" is answered by voice, so it's said aloud.
            text = question
        default:
            return
        }
        say(text, interruptible: true)
    }

    /// Speaks regardless of the Speak responses setting (voice preview).
    /// `interruptible`: the user can talk over it to stop it and be heard.
    public func say(_ text: String, interruptible: Bool = false) {
        stop()
        if interruptible {
            utterance += 1
            let id = utterance
            BargeIn.began(text)
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                while let self, self.utterance == id, self.neuralSpeaking || self.synthesizer.isSpeaking {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                // The echo's tail.
                try? await Task.sleep(for: .milliseconds(300))
                if self?.utterance == id { BargeIn.ended() }
            }
        }
        if let neural = Self.neural, neural.isActive {
            neuralSpeaking = true
            neuralTask = Task { [weak self] in
                let spoke = await neural.speak(text)
                if !spoke, !Task.isCancelled { self?.sayWithSystemVoice(text) }
                self?.neuralSpeaking = false
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

    /// Waits (at most 10 s) until nothing is being said, plus a moment for
    /// the echo to fade.
    public func waitUntilDone() async {
        let deadline = ContinuousClock.now + .seconds(40)
        try? await Task.sleep(for: .milliseconds(150))
        while neuralSpeaking || synthesizer.isSpeaking, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(250))
    }

    public func stop() {
        utterance += 1
        BargeIn.ended()
        neuralSpeaking = false
        neuralTask?.cancel()
        neuralTask = nil
        Self.neural?.stop()
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }
}
