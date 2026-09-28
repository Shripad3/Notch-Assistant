// AVAudioPCMBuffer isn't Sendable. Buffers here are deep copies, handed from
// the audio thread to one serial queue and never mutated afterwards.
@preconcurrency import AVFoundation
import Synchronization

/// Audio from just before a wake-word detection, handed to speech
/// recognition so the command's first words aren't clipped, and so the
/// recognizer can confirm the wake word was really said.
public final class WakeContext: @unchecked Sendable, Equatable {
    /// Copies of the listener's input buffers, oldest first. Never mutated.
    public let preroll: [AVAudioPCMBuffer]
    /// The room's noise floor in dBFS before the detection, for endpointing.
    public let ambientFloor: Float
    public let score: Float
    /// True when the detector was itself a speech recognizer that
    /// transcribed the wake word: no second confirmation is needed.
    public let confirmed: Bool
    /// Seconds to wait for speech to start (see `Endpointer`).
    public private(set) var patience = Endpointer.noSpeechTimeout
    /// An answer to Alfred (a question or a conversation), not a command
    /// after the wake word: kept exactly as said.
    public private(set) var isFollowUp = false
    /// Started by talking over Alfred rather than by the wake word.
    public private(set) var isInterruption = false
    /// The quiet listen after an answer: filler ("thanks") closes it.
    public private(set) var isLingering = false

    /// A hands-free start with no wake word (an open-palm gesture): no
    /// pre-roll, and the endpointer measures the room itself.
    public static func gesture() -> WakeContext {
        WakeContext(preroll: [], ambientFloor: .nan, score: 1, confirmed: true)
    }

    /// Listening for the answer to Alfred's own question ("For when?").
    public static func followUp(patience: Double = 6, lingering: Bool = false) -> WakeContext {
        let context = WakeContext(preroll: [], ambientFloor: .nan, score: 1, confirmed: true)
        context.patience = patience
        context.isFollowUp = true
        context.isLingering = lingering
        return context
    }

    /// The user talking over Alfred: their first words are in the pre-roll.
    static func interruption(preroll: [AVAudioPCMBuffer], ambientFloor: Float) -> WakeContext {
        let context = WakeContext(preroll: preroll, ambientFloor: ambientFloor, score: 1, confirmed: true)
        context.isFollowUp = true
        context.isInterruption = true
        return context
    }

    init(preroll: [AVAudioPCMBuffer], ambientFloor: Float, score: Float, confirmed: Bool = false) {
        self.preroll = preroll
        self.ambientFloor = ambientFloor
        self.score = score
        self.confirmed = confirmed
    }

    public static func == (a: WakeContext, b: WakeContext) -> Bool { a === b }
}

/// Where the wake-word models live: the three bundled with the app, plus any
/// custom-trained `.onnx` files the user drops into Application Support.
public enum WakeWordModels {
    public static var customFolder: URL {
        URL.applicationSupportDirectory.appending(path: "NotchAssistant/WakeWords", directoryHint: .isDirectory)
    }

    /// (melspectrogram, embedding, wake models), or nil if the bundle lacks them.
    public static func locate(bundle: Bundle = .main) -> (URL, URL, [URL])? {
        guard let folder = bundle.resourceURL?.appending(path: "WakeWord") else { return nil }
        let mel = folder.appending(path: "melspectrogram.onnx")
        let embedding = folder.appending(path: "embedding_model.onnx")
        let feature = Set(["melspectrogram.onnx", "embedding_model.onnx"])
        let onnx = { (dir: URL) in
            ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "onnx" && !feature.contains($0.lastPathComponent) }
        }
        let wake = onnx(folder) + onnx(customFolder)
        guard FileManager.default.fileExists(atPath: mel.path), FileManager.default.fileExists(atPath: embedding.path), !wake.isEmpty
        else { return nil }
        return (mel, embedding, wake.sorted { $0.lastPathComponent < $1.lastPathComponent })
    }
}

/// Listens continuously for the wake word. Audio arrives on the audio
/// thread, and all processing happens on one serial queue, never the main
/// thread.
public final class WakeWordListener: WakeListening, @unchecked Sendable {
    public static let thresholdKey = "wake.threshold"
    public static let defaultThreshold: Float = 0.4
    static let prerollSeconds = 1.5
    static let ambientSeconds = 3.0
    /// After a detection, ignore further ones for this long.
    static let refractory = 2.0

    private let queue = DispatchQueue(label: "dev.shripad.NotchAssistant.wakeword", qos: .userInitiated)
    private let engine = AVAudioEngine()
    private let detector: WakeWordDetector
    private let onDetect: @Sendable (WakeContext) -> Void

    // Touched only on `queue`.
    private var converter: AVAudioConverter?
    private var preroll: [AVAudioPCMBuffer] = []
    private var prerollDuration = 0.0
    private var levels: [(level: Float, duration: Double)] = []
    private var quietUntil = Date.distantPast
    // Diagnostics, logged every couple of seconds while listening.
    private var reportBuffers = 0
    private var reportPeakScore: Float = 0
    private var reportPeakLevel: Float = -100
    private var reportDuration = 0.0
    private let running = Mutex(false)

    public init(models: (URL, URL, [URL]), onDetect: @escaping @Sendable (WakeContext) -> Void) throws {
        detector = try WakeWordDetector(melspectrogram: models.0, embedding: models.1, wakeWords: models.2)
        self.onDetect = onDetect
    }

    public static var threshold: Float {
        (UserDefaults.standard.object(forKey: thresholdKey) as? NSNumber)?.floatValue ?? defaultThreshold
    }

    public func start() throws {
        guard running.withLock({ let was = $0; $0 = true; return !was }) else { return }
        let input = engine.inputNode
        let processed = VoiceProcessing.prepare(input)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            running.withLock { $0 = false }
            throw AssistantFailure("No microphone input is available")
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let copy = processed ? VoiceProcessing.voice(of: buffer) : buffer.copied() else { return }
            self.queue.async { self.ingest(copy) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            running.withLock { $0 = false }
            throw AssistantFailure("Couldn't start listening for the wake word: \(error.localizedDescription)")
        }
        Log.speech.notice("wake word: listening")
    }

    public func stop() async {
        stopListening()
    }

    public func stopListening() {
        guard running.withLock({ let was = $0; $0 = false; return was }) else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        queue.async { [self] in
            preroll = []
            prerollDuration = 0
            levels = []
            try? detector.reset()
        }
        Log.speech.notice("wake word: stopped")
    }

    /// One input buffer, in the device's native format. Internal so tests
    /// can feed recorded audio through the same path as the microphone.
    func ingest(_ buffer: AVAudioPCMBuffer) {
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        keep(buffer, duration: duration)
        levels.append((SystemSTT.decibels(of: buffer), duration))
        var total = levels.reduce(0) { $0 + $1.duration }
        while total > Self.ambientSeconds, let first = levels.first {
            levels.removeFirst()
            total -= first.duration
        }

        let samples = convert(buffer)
        let score = samples.flatMap { try? detector.process($0) }
        report(buffer: buffer, duration: duration, samples: samples?.count, score: score)
        guard let score, score >= Self.threshold, Date() >= quietUntil else { return }
        quietUntil = Date().addingTimeInterval(Self.refractory)
        try? detector.reset()
        let context = WakeContext(preroll: preroll, ambientFloor: ambientFloor(), score: score)
        Log.speech.notice("wake word: detected (score \(String(format: "%.2f", score), privacy: .public))")
        onDetect(context)
    }

    private func report(buffer: AVAudioPCMBuffer, duration: Double, samples: Int?, score: Float?) {
        reportBuffers += 1
        reportDuration += duration
        reportPeakScore = max(reportPeakScore, score ?? 0)
        reportPeakLevel = max(reportPeakLevel, levels.last?.level ?? -100)
        guard reportDuration >= 2 else { return }
        let format = "\(buffer.format.sampleRate) Hz \(buffer.format.channelCount) ch \(buffer.format.commonFormat.rawValue)"
        let line = "wake word: \(reportBuffers) buffers, \(format), converted \(samples ?? -1) samples, "
            + "peak level \(String(format: "%.1f", reportPeakLevel)) dB, "
            + "peak score \(String(format: "%.3f", reportPeakScore)) (threshold \(Self.threshold))"
        Log.speech.debug("\(line, privacy: .public)")
        reportBuffers = 0
        reportDuration = 0
        reportPeakScore = 0
        reportPeakLevel = -100
    }

    private func keep(_ buffer: AVAudioPCMBuffer, duration: Double) {
        preroll.append(buffer)
        prerollDuration += duration
        while prerollDuration > Self.prerollSeconds, let first = preroll.first {
            preroll.removeFirst()
            prerollDuration -= Double(first.frameLength) / first.format.sampleRate
        }
    }

    /// The 20th-percentile level over the last few seconds: the room without
    /// the loudest moments.
    private func ambientFloor() -> Float {
        let sorted = levels.map(\.level).sorted()
        guard !sorted.isEmpty else { return -50 }
        return sorted[Int(Double(sorted.count - 1) * 0.2)]
    }

    /// To 16 kHz mono 16-bit, the format the models were trained on.
    private func convert(_ buffer: AVAudioPCMBuffer) -> [Int16]? {
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(WakeWordDetector.sampleRate), channels: 1, interleaved: true)!
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
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
        guard error == nil, let data = output.int16ChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }
}

extension AVAudioPCMBuffer {
    /// A deep copy: tap buffers may be reused by the engine after the callback.
    func copied() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            guard let src = from.mData, let dst = to.mData else { continue }
            memcpy(dst, src, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }
}
