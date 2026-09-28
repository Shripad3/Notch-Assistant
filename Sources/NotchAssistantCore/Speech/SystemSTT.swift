import AVFoundation
import Speech

/// The system Speech framework, forced on-device (spec §7).
public actor SystemSTT: TranscriptionService {
    /// How long `finish()` waits for the recognizer's final result before
    /// settling for the last partial.
    private static let finalResultGrace: Duration = .milliseconds(700)

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latest = ""
    private var finalText: String?
    private var finalWaiter: CheckedContinuation<String, Never>?
    private var capturing = false

    public init() {}

    public func prepare() async {
        AudioDucker.recoverIfNeeded()
        do {
            try await Self.authorize()
        } catch {
            Log.speech.error("permissions not granted: \(AssistantFailure(error).message, privacy: .public)")
        }
    }

    public func start(wake: WakeContext?, onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void) async throws {
        try await Self.authorize()
        let recognizer = try makeRecognizer()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = false
        // Contact names help with names the recogniser doesn't know,
        // including Indian names ("Shripad", "Aditya").
        request.contextualStrings = ["Alfred", "Hey Alfred"] + ContactBook.shared.namesForRecognition()
        self.request = request
        latest = ""
        finalText = nil

        let input = engine.inputNode
        let processed = VoiceProcessing.prepare(input)
        let format = input.outputFormat(forBus: 0)
        // With voice processing, one channel of processed voice, as the wake
        // listener hands over its pre-roll in.
        let heard = processed ? VoiceProcessing.voiceFormat(for: format) : format
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AssistantFailure("No microphone input is available")
        }
        // The wake word and anything said just after it, recorded before
        // this engine started. Same device, so the same format; skipped if not.
        for buffer in wake?.preroll ?? [] where buffer.format == heard {
            request.append(buffer)
        }
        AudioDucker.duck()
        let sink = BufferSink(request, endpointer: wake.map { Endpointer(ambientFloor: $0.ambientFloor.isNaN ? nil : $0.ambientFloor, patience: $0.patience) })
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { tapped, _ in
            guard let buffer = processed ? VoiceProcessing.voice(of: tapped) : tapped else { return }
            let decibels = Self.decibels(of: buffer)
            onUpdate(.level(Self.level(fromDecibels: decibels)))
            switch sink.append(buffer, decibels: decibels) {
            case .endOfSpeech: onUpdate(.endOfSpeech)
            case .noSpeech: onUpdate(.noSpeech)
            case .listening, nil: break
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            AudioDucker.restore()
            throw AssistantFailure("Couldn't start the microphone: \(error.localizedDescription)")
        }
        capturing = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = (result?.isFinal ?? false) || error != nil
            if let text { onUpdate(.partial(text)) }
            Task { await self?.received(text: text, isFinal: isFinal) }
        }
        Log.speech.info("capture started (\(recognizer.locale.identifier, privacy: .public))")
    }

    public func finish() async -> String {
        guard capturing else { return "" }
        stopAudio()
        request?.endAudio()

        let text: String
        if let finalText {
            text = finalText
        } else {
            let grace = Task { [weak self] in
                try? await Task.sleep(for: Self.finalResultGrace)
                await self?.settle(nil)
            }
            text = await withCheckedContinuation { finalWaiter = $0 }
            grace.cancel()
        }
        reset()
        Log.speech.notice("transcript: \"\(text, privacy: .public)\"")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func cancel() async {
        stopAudio()
        task?.cancel()
        settle("")
        reset()
    }

    private func received(text: String?, isFinal: Bool) {
        if let text { latest = text }
        if isFinal { settle(text ?? latest) }
    }

    /// Delivers the final transcript exactly once, whether `finish()` is
    /// already waiting or not. Nil means "use the latest partial".
    private func settle(_ text: String?) {
        let value = text ?? latest
        if let waiter = finalWaiter {
            finalWaiter = nil
            waiter.resume(returning: value)
        } else if finalText == nil {
            finalText = value
        }
    }

    /// Releases the input device immediately, so the orange microphone
    /// indicator goes out as soon as the utterance ends (spec §7).
    private func stopAudio() {
        guard capturing else { return }
        capturing = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        AudioDucker.restore()
    }

    private func reset() {
        task = nil
        request = nil
        finalText = nil
    }

    /// RMS level of the first channel in dBFS.
    nonisolated static func decibels(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -100 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        return 20 * log10(max((sum / Float(count)).squareRoot(), 1e-7))
    }

    /// -50…0 dBFS mapped onto 0…1, for the level bars.
    private nonisolated static func level(fromDecibels decibels: Float) -> Float {
        min(max((decibels + 50) / 50, 0), 1)
    }

    private func makeRecognizer() throws -> SFSpeechRecognizer {
        // The accent chosen in Settings (e.g. English (India)) applies to
        // commands as well as the wake word.
        let accent = UserDefaults.standard.string(forKey: SpeechWakeListener.localeKey).flatMap { $0.isEmpty ? nil : Locale(identifier: $0) }
        if let recognizer, accent == nil || recognizer.locale.identifier == accent?.identifier { return recognizer }
        for locale in [accent, Locale.current, Locale(identifier: "en-US")].compactMap({ $0 }) {
            if let candidate = SFSpeechRecognizer(locale: locale), candidate.supportsOnDeviceRecognition {
                recognizer = candidate
                return candidate
            }
        }
        throw AssistantFailure("On-device speech recognition isn't available. Enable Dictation in System Settings › Keyboard.")
    }

    private static func authorize() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw microphoneDenied }
        default:
            throw microphoneDenied
        }

        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        guard status == .authorized else {
            throw AssistantFailure("Speech recognition is off for Notch Assistant", link: .speechRecognition)
        }
    }

    private static let microphoneDenied = AssistantFailure("Microphone access is off for Notch Assistant", link: .microphone)
}

/// The audio tap runs on a realtime thread. Appending buffers to the request
/// from there is the documented usage, so the request crosses threads here.
/// The endpointer is only ever touched from the tap's single thread.
private final class BufferSink: @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest
    private var endpointer: Endpointer?
    private var decided = false

    init(_ request: SFSpeechAudioBufferRecognitionRequest, endpointer: Endpointer?) {
        self.request = request
        self.endpointer = endpointer
    }

    /// Returns the endpointer's decision once, when it first stops listening.
    func append(_ buffer: AVAudioPCMBuffer, decibels: Float) -> Endpointer.Decision? {
        request.append(buffer)
        guard !decided, endpointer != nil else { return nil }
        let decision = endpointer!.feed(level: decibels, duration: Double(buffer.frameLength) / buffer.format.sampleRate)
        if decision != .listening { decided = true }
        return decision
    }
}
