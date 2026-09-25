import Foundation
import OnnxRuntimeBindings

/// openWakeWord's streaming pipeline, ported from openwakeword/utils.py and
/// model.py (v0.6). Three ONNX models run on every 80 ms chunk:
///
/// 1. melspectrogram: the last 1760 samples → mel frames, scaled `/10 + 2`
/// 2. embedding: the last 76 mel frames → one 96-value embedding
/// 3. wake word: the last 16 embeddings → a score from 0 to 1
///
/// Several wake models can run at once ("alfred", "hey alfred", …): the
/// first two stages are shared, each extra phrase costs one small model,
/// and the score is the highest of them. Not thread-safe: feed it from one
/// serial queue.
public final class WakeWordDetector {
    public static let sampleRate = 16_000
    /// 80 ms at 16 kHz.
    public static let chunkSize = 1280

    private static let melContext = 160 * 3
    private static let melBins = 32
    private static let embeddingWindow = 76
    private static let embeddingSize = 96
    private static let maxMelFrames = 10 * 97
    private static let maxEmbeddings = 120
    /// Predictions ignored while the buffers still hold start-up values.
    private static let warmupChunks = 5

    private let env: ORTEnv
    private let melSession: ORTSession
    private let embeddingSession: ORTSession
    private let wakeSessions: [(session: ORTSession, input: String)]
    private let wakeFrames = 16

    private var raw: [Int16] = []
    private var pending: [Int16] = []
    private var mel: [[Float]]
    private var embeddings: [[Float]] = []
    private var chunksSeen = 0

    public convenience init(melspectrogram: URL, embedding: URL, wakeWord: URL) throws {
        try self.init(melspectrogram: melspectrogram, embedding: embedding, wakeWords: [wakeWord])
    }

    public init(melspectrogram: URL, embedding: URL, wakeWords: [URL]) throws {
        guard !wakeWords.isEmpty else { throw ToolError("No wake-word model found") }
        let env = try ORTEnv(loggingLevel: .warning)
        self.env = env
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(1)
        melSession = try ORTSession(env: env, modelPath: melspectrogram.path, sessionOptions: options)
        embeddingSession = try ORTSession(env: env, modelPath: embedding.path, sessionOptions: options)
        // Each wake model's input is [1, 16, 96] for models from the standard
        // training notebooks.
        wakeSessions = try wakeWords.map { url in
            let session = try ORTSession(env: env, modelPath: url.path, sessionOptions: options)
            return (session, try session.inputNames().first ?? "input")
        }
        mel = Array(repeating: Array(repeating: 1, count: Self.melBins), count: Self.embeddingWindow)
        try seedEmbeddings()
    }

    /// Clears all history, as after a detection, so one utterance of the
    /// wake word can't fire twice.
    public func reset() throws {
        raw = []
        pending = []
        mel = Array(repeating: Array(repeating: 1, count: Self.melBins), count: Self.embeddingWindow)
        chunksSeen = 0
        try seedEmbeddings()
    }

    /// Feeds 16 kHz mono samples of any length. Returns the highest score
    /// among the 80 ms chunks completed by this call, or nil if none were.
    public func process(_ samples: [Int16]) throws -> Float? {
        pending += samples
        var best: Float?
        while pending.count >= Self.chunkSize {
            let chunk = Array(pending.prefix(Self.chunkSize))
            pending.removeFirst(Self.chunkSize)
            let score = try processChunk(chunk)
            best = max(best ?? 0, score)
        }
        return best
    }

    private func processChunk(_ chunk: [Int16]) throws -> Float {
        raw += chunk
        let keep = Self.chunkSize + Self.melContext
        if raw.count > keep { raw.removeFirst(raw.count - keep) }

        mel += try melspectrogram(raw)
        if mel.count > Self.maxMelFrames { mel.removeFirst(mel.count - Self.maxMelFrames) }

        if mel.count >= Self.embeddingWindow {
            embeddings.append(try embed(Array(mel.suffix(Self.embeddingWindow))))
            if embeddings.count > Self.maxEmbeddings { embeddings.removeFirst(embeddings.count - Self.maxEmbeddings) }
        }

        chunksSeen += 1
        let score = try wakeScore(Array(embeddings.suffix(wakeFrames)))
        return chunksSeen <= Self.warmupChunks ? 0 : score
    }

    /// Raw int16 values as float32 (not normalised), as openWakeWord does.
    private func melspectrogram(_ samples: [Int16]) throws -> [[Float]] {
        let input = samples.map(Float.init)
        let output = try run(melSession, input: "input", data: input, shape: [1, input.count])
        return stride(from: 0, to: output.count - Self.melBins + 1, by: Self.melBins).map { start in
            output[start..<start + Self.melBins].map { $0 / 10 + 2 }
        }
    }

    private func embed(_ window: [[Float]]) throws -> [Float] {
        try run(embeddingSession, input: "input_1", data: window.flatMap { $0 }, shape: [1, Self.embeddingWindow, Self.melBins, 1])
    }

    private func wakeScore(_ features: [[Float]]) throws -> Float {
        guard features.count == wakeFrames else { return 0 }
        let data = features.flatMap { $0 }
        return try wakeSessions.map { model in
            try run(model.session, input: model.input, data: data, shape: [1, wakeFrames, Self.embeddingSize]).first ?? 0
        }.max() ?? 0
    }

    /// openWakeWord starts from the embeddings of 4 s of quiet random noise,
    /// so the first real predictions have 16 frames of context.
    private func seedEmbeddings() throws {
        var generator = SystemRandomNumberGenerator()
        let noise = (0..<(Self.sampleRate * 4)).map { _ in Int16.random(in: -1000..<1000, using: &generator) }
        let frames = try melspectrogram(noise)
        embeddings = try stride(from: 0, through: frames.count - Self.embeddingWindow, by: 8).map { start in
            try embed(Array(frames[start..<start + Self.embeddingWindow]))
        }
    }

    private func run(_ session: ORTSession, input: String, data: [Float], shape: [Int]) throws -> [Float] {
        let bytes = NSMutableData(bytes: data, length: data.count * MemoryLayout<Float>.size)
        let value = try ORTValue(tensorData: bytes, elementType: .float, shape: shape.map { NSNumber(value: $0) })
        guard let outputName = try session.outputNames().first,
              let output = try session.run(withInputs: [input: value], outputNames: [outputName], runOptions: nil)[outputName]
        else { throw ToolError("Wake-word model produced no output") }
        let result = try output.tensorData() as Data
        return result.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
