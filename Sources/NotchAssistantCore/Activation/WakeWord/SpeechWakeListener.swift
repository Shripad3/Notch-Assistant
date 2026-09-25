// AVAudioPCMBuffer isn't Sendable. Buffers here are deep copies, handed from
// the audio thread to one serial queue and never mutated afterwards.
@preconcurrency import AVFoundation
import CoreMedia
@preconcurrency import Speech
import Synchronization

/// Something that listens for the wake word.
public protocol WakeListening: AnyObject, Sendable {
    func start() async throws
    func stop() async
}

/// Which detector listens for "Alfred".
public enum WakeEngine: String, CaseIterable, Sendable {
    /// Apple's on-device speech recognizer, watching for the word. Works
    /// with any voice and any greeting in front, with no training.
    case speech
    /// openWakeWord models (the bundled one plus any custom-trained ones).
    case model

    public static let defaultsKey = "wake.engine"

    public static var current: WakeEngine {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(WakeEngine.init(rawValue:)) ?? .speech
    }

    public var title: String {
        switch self {
        case .speech: "Speech recognition (recommended)"
        case .model: "Wake-word models"
        }
    }
}

/// Decides whether a recognizer result covers audio not yet acted on.
enum WakeDeduplicator {
    /// New only if it starts after everything already handled; a revision of
    /// handled text starts at or before that point.
    static func isNew(_ range: CMTimeRange, handledThrough: CMTime) -> Bool {
        handledThrough == .zero || CMTimeCompare(range.start, handledThrough) >= 0
    }
}

/// Recent audio and room level, kept by a listener so that a detection can
/// hand over the lead-in audio and the noise floor.
struct AudioHistory {
    let prerollSeconds: Double
    let ambientSeconds = 3.0
    private(set) var preroll: [AVAudioPCMBuffer] = []
    private var prerollDuration = 0.0
    private var levels: [(level: Float, duration: Double)] = []

    init(prerollSeconds: Double) {
        self.prerollSeconds = prerollSeconds
    }

    var lastLevel: Float { levels.last?.level ?? -100 }

    mutating func add(_ buffer: AVAudioPCMBuffer) {
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        preroll.append(buffer)
        prerollDuration += duration
        while prerollDuration > prerollSeconds, let first = preroll.first {
            preroll.removeFirst()
            prerollDuration -= Double(first.frameLength) / first.format.sampleRate
        }
        levels.append((SystemSTT.decibels(of: buffer), duration))
        var total = levels.reduce(0) { $0 + $1.duration }
        while total > ambientSeconds, let first = levels.first {
            levels.removeFirst()
            total -= first.duration
        }
    }

    mutating func clear() {
        preroll = []
        prerollDuration = 0
        levels = []
    }

    /// The 20th-percentile level over the last few seconds: the room without
    /// the loudest moments.
    func ambientFloor() -> Float {
        let sorted = levels.map(\.level).sorted()
        guard !sorted.isEmpty else { return -50 }
        return sorted[Int(Double(sorted.count - 1) * 0.2)]
    }
}

/// Listens for "Alfred" with Apple's on-device speech recognition
/// (SpeechAnalyzer, macOS 26), biased towards the word. A deviation from
/// spec §6's openWakeWord: the community "Alfred" model scored the user's
/// real voice at 0.001–0.007, and missed every greeting run into the word
/// ("Hey Alfred", "Okay Alfred"), all of which the recognizer transcribed.
/// Nothing leaves the Mac.
public final class SpeechWakeListener: WakeListening, @unchecked Sendable {
    public static let localeKey = "wake.locale"
    /// Longer than the model listener's: the recognizer reports the word a
    /// moment after it is said, and the command's start must still be kept.
    static let prerollSeconds = 2.5
    static let refractory = 2.5
    /// The analyzer is restarted periodically so a session never grows without bound.
    static let sessionLength: Duration = .seconds(600)

    private let queue = DispatchQueue(label: "dev.shripad.NotchAssistant.speechwake", qos: .userInitiated)
    private let onDetect: @Sendable (WakeContext) -> Void
    private let state = Mutex(State())

    private struct State {
        var engine: AVAudioEngine?
        var analyzer: SpeechAnalyzer?
        var input: AsyncStream<AnalyzerInput>.Continuation?
        var tasks: [Task<Void, Never>] = []
    }

    // Touched only on `queue`.
    private var history = AudioHistory(prerollSeconds: SpeechWakeListener.prerollSeconds)
    private var converter: AVAudioConverter?
    private var quietUntil = Date.distantPast
    /// Audio up to here has already produced a detection. The recognizer
    /// revises text it has already reported ("Alfred" as a draft, then
    /// "Alfred, pause." as the final result) and each revision can carry a
    /// different range, so repeats are recognised by audio time, not identity.
    private var handledThrough = CMTime.zero

    public init(onDetect: @escaping @Sendable (WakeContext) -> Void) {
        self.onDetect = onDetect
    }

    /// The chosen accent, else the user's own if supported, else US English.
    public static func locale() async -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        if let id = UserDefaults.standard.string(forKey: localeKey), let chosen = supported.first(where: { $0.identifier == id }) {
            return chosen
        }
        return supported.first { $0.identifier == Locale.current.identifier } ?? Locale(identifier: "en_US")
    }

    public func start() async throws {
        guard state.withLock({ $0.engine == nil }) else { return }
        let locale = await Self.locale()
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
        if await AssetInventory.status(forModules: [transcriber]) != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            Log.speech.notice("wake word: downloading speech model")
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AssistantFailure("Speech recognition isn't available for this language")
        }

        let context = AnalysisContext()
        context.contextualStrings[.general] = ["Alfred", "Hey Alfred", "Okay Alfred"]
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.setContext(context)
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(64))
        try await analyzer.start(inputSequence: stream)

        let results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let listener = self else { return }
                    let text = String(result.text.characters)
                    let range = result.range
                    listener.queue.async { listener.received(text, range: range) }
                }
            } catch {
                Log.speech.error("wake word: recognizer stopped: \(error.localizedDescription, privacy: .public)")
            }
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let micFormat = inputNode.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else {
            throw AssistantFailure("No microphone input is available")
        }
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { [weak self] buffer, _ in
            guard let self, let copy = buffer.copied() else { return }
            self.queue.async { self.ingest(copy, to: format, input: input) }
        }
        engine.prepare()
        try engine.start()

        // Restart the analyzer periodically: a fresh session every ten minutes.
        let renew = Task { [weak self] in
            try? await Task.sleep(for: Self.sessionLength)
            guard !Task.isCancelled, let self else { return }
            await self.stop()
            try? await self.start()
        }
        state.withLock {
            $0.engine = engine
            $0.analyzer = analyzer
            $0.input = input
            $0.tasks = [results, renew]
        }
        Log.speech.notice("wake word: listening with speech recognition (\(locale.identifier, privacy: .public))")
    }

    public func stop() async {
        let current = state.withLock { state -> State in
            let current = state
            state = State()
            return current
        }
        guard let engine = current.engine else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        current.input?.finish()
        current.tasks.forEach { $0.cancel() }
        await current.analyzer?.cancelAndFinishNow()
        queue.async { [self] in
            history.clear()
            handledThrough = .zero
        }
        Log.speech.notice("wake word: stopped")
    }

    private func ingest(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat, input: AsyncStream<AnalyzerInput>.Continuation) {
        history.add(buffer)
        guard let converted = convert(buffer, to: format) else { return }
        input.yield(AnalyzerInput(buffer: converted))
    }

    /// One detection per stretch of audio, however many times the recognizer
    /// revises its text ("Hey Al…", "Hey Alfred", "Hey Alfred, open…").
    private func received(_ text: String, range: CMTimeRange) {
        guard WakeDeduplicator.isNew(range, handledThrough: handledThrough),
              Date() >= quietUntil, WakePhrase.contains(text) else { return }
        handledThrough = CMTimeMaximum(handledThrough, range.end)
        quietUntil = Date().addingTimeInterval(Self.refractory)
        Log.speech.notice("wake word: heard \"\(text, privacy: .public)\"")
        onDetect(WakeContext(preroll: history.preroll, ambientFloor: history.ambientFloor(), score: 1))
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter?.inputFormat != buffer.format || converter?.outputFormat != format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        // The converter calls back synchronously, on this thread.
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? output : nil
    }
}
