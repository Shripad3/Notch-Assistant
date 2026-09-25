import AVFoundation
import CoreMedia
import Speech
import Synchronization
@testable import NotchAssistantCore
import Testing

/// The real models on real audio: clips made with macOS `say`
/// (Tests/Fixtures/audio). openWakeWord models are trained on synthetic
/// speech, so synthetic voices are a fair first check.
@Suite(.serialized)
struct WakeWordDetectorTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let models = root.appending(path: "Resources/WakeWord")
    static let audio = root.appending(path: "Tests/Fixtures/audio")

    static func detector() throws -> WakeWordDetector {
        try WakeWordDetector(
            melspectrogram: models.appending(path: "melspectrogram.onnx"),
            embedding: models.appending(path: "embedding_model.onnx"),
            wakeWord: models.appending(path: "alfred.onnx")
        )
    }

    /// Peak score over a clip padded with a second of silence each side.
    static func peak(_ name: String) throws -> Float {
        let file = try AVAudioFile(forReading: audio.appending(path: name + ".wav"), commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength)))
        let silence = [Int16](repeating: 0, count: WakeWordDetector.sampleRate)
        let detector = try detector()
        var best: Float = 0
        let all = silence + samples + silence
        for start in stride(from: 0, to: all.count, by: WakeWordDetector.chunkSize) {
            if let score = try detector.process(Array(all[start..<min(start + WakeWordDetector.chunkSize, all.count)])) {
                best = max(best, score)
            }
        }
        print("wake score \(name): \(String(format: "%.3f", best))")
        return best
    }

    /// Default detection threshold (Settings › Activation adjusts it).
    static let threshold: Float = 0.4

    @Test(arguments: [
        "pos_alfred_samantha", "pos_alfred_daniel", "pos_alfred_rishi", "pos_alfred_moira",
        "pos_hey_alfred_karen", "pos_good_morning_pause_alfred", "pos_alfred_pause_command", "pos_alfred_command",
    ])
    func firesOnAlfred(clip: String) throws {
        #expect(try Self.peak(clip) >= Self.threshold)
    }

    @Test(arguments: ["neg_open_spotify", "neg_office", "neg_all_friends", "neg_offered"])
    func quietOnOtherSpeech(clip: String) throws {
        #expect(try Self.peak(clip) < 0.1)
    }

    /// The community "Alfred" model was trained on the bare word: greetings
    /// that run straight into it score near zero. Custom-trained models for
    /// these phrases are expected to fix this, at which point these tests
    /// report that the known issue no longer occurs.
    @Test(arguments: ["prefix_okay_alfred", "prefix_hello_alfred", "prefix_hey_alfred_command", "prefix_hey_alfred_daniel", "prefix_good_morning_alfred_command"])
    func greetingRunningIntoAlfred(clip: String) throws {
        let score = try Self.peak(clip)
        withKnownIssue("community model misses greetings run into \"Alfred\"") {
            #expect(score >= Self.threshold)
        }
    }

    @Test func silenceScoresZero() throws {
        let detector = try Self.detector()
        let score = try detector.process([Int16](repeating: 0, count: WakeWordDetector.sampleRate * 2))
        #expect((score ?? 1) < 0.1)
    }
}

/// The listener's microphone path (format conversion, detection, pre-roll,
/// refractory period) fed with 48 kHz float audio, as a Mac mic delivers.
@Suite(.serialized)
struct WakeWordListenerTests {
    private func detections(in clip: String) throws -> [WakeContext] {
        let models = WakeWordDetectorTests.models
        let found = Mutex<[WakeContext]>([])
        let listener = try WakeWordListener(models: (
            models.appending(path: "melspectrogram.onnx"),
            models.appending(path: "embedding_model.onnx"),
            [models.appending(path: "alfred.onnx")]
        )) { context in found.withLock { $0.append(context) } }

        let file = try AVAudioFile(forReading: WakeWordDetectorTests.audio.appending(path: clip + ".wav"))
        let format = file.processingFormat
        let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        silence.frameLength = 4096 // zero-filled
        for _ in 0..<12 { listener.ingest(silence.copied()!) }
        while file.framePosition < file.length {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
            try file.read(into: buffer, frameCount: 4096)
            listener.ingest(buffer)
        }
        for _ in 0..<12 { listener.ingest(silence.copied()!) }
        return found.withLock { $0 }
    }

    @Test func detectsOnceWithPreroll() throws {
        let found = try detections(in: "mic48k_alfred")
        #expect(found.count == 1)
        let preroll = found.first?.preroll ?? []
        let seconds = preroll.reduce(0.0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
        #expect(seconds > 0.5 && seconds <= WakeWordListener.prerollSeconds + 0.1)
        #expect(preroll.first?.format.sampleRate == 48_000)
    }

    @Test func alfredThenCommand() throws {
        #expect(try detections(in: "mic48k_alfred_open_spotify").count == 1)
    }

    @Test func noDetectionOnOtherSpeech() throws {
        #expect(try detections(in: "mic48k_office").isEmpty)
    }
}

struct WakePhraseTests {
    @Test(arguments: [
        ("Alfred open Spotify", "open Spotify"),
        ("Hey Alfred, play some music", "play some music"),
        ("Okay Alfredo what's the weather", "what's the weather"),
        ("Al fred open YouTube", "open YouTube"),
        ("Good morning Alfred", "Good morning Alfred"),
        ("Alfred", "Alfred"),
    ])
    func stripsTheWakeWord(transcript: String, command: String) {
        #expect(WakePhrase.command(from: transcript) == command)
    }

    /// A detection whose transcript has no wake word was a false positive.
    @Test(arguments: ["open Spotify", "all friends are here", "he offered me coffee", ""])
    func rejectsFalseDetections(transcript: String) {
        #expect(WakePhrase.command(from: transcript) == nil)
    }

    @Test func wakeWordMustComeEarly() {
        #expect(WakePhrase.command(from: "one two three four five six seven eight nine ten eleven Alfred") == nil)
        #expect(WakePhrase.command(from: "one two three four five six Alfred open notes") == "open notes")
    }
}

struct WakePhraseContainsTests {
    @Test(arguments: ["Okay, Alfred.", "K. Alfred, play some music.", "Good morning, Alfred.", "so anyway hey alfred open spotify"])
    func finds(text: String) {
        #expect(WakePhrase.contains(text))
    }

    @Test(arguments: ["He offered me a coffee this afternoon.", "How are you?", "all friends are here", ""])
    func ignores(text: String) {
        #expect(!WakePhrase.contains(text))
    }
}

/// Apple's on-device recognizer (the default wake engine) on the clips the
/// community model missed.
@Suite(.serialized)
struct SpeechWakeRecognitionTests {
    private func transcript(_ clip: String) async throws -> String {
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en_US"), transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        let context = AnalysisContext()
        context.contextualStrings[.general] = ["Alfred", "Hey Alfred", "Okay Alfred"]
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.setContext(context)
        let file = try AVAudioFile(forReading: WakeWordDetectorTests.audio.appending(path: clip + ".wav"))
        async let texts: [String] = transcriber.results.reduce(into: []) { $0.append(String($1.text.characters)) }
        if let end = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await texts.joined(separator: " ")
    }

    @Test(arguments: ["prefix_okay_alfred", "prefix_hello_alfred", "prefix_hey_alfred_command", "prefix_good_morning_alfred_command", "pos_alfred_daniel"])
    func hearsAlfred(clip: String) async throws {
        let text = try await transcript(clip)
        #expect(WakePhrase.contains(text), "\(clip): \(text)")
    }

    @Test(arguments: ["neg_all_friends", "neg_offered", "neg_office"])
    func noFalseAlfred(clip: String) async throws {
        let text = try await transcript(clip)
        #expect(!WakePhrase.contains(text), "\(clip): \(text)")
    }
}

struct WakeDeduplicatorTests {
    private func range(_ start: Double, _ end: Double) -> CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 1000), end: CMTime(seconds: end, preferredTimescale: 1000))
    }

    /// From the log: "Alfred" (draft) then "Alfred, pause." (final) for one utterance.
    @Test func revisionOfHandledAudioIsIgnored() {
        let handled = range(10.0, 10.6).end
        #expect(!WakeDeduplicator.isNew(range(10.0, 11.4), handledThrough: handled))
        #expect(!WakeDeduplicator.isNew(range(10.2, 11.4), handledThrough: handled))
    }

    @Test func laterSpeechIsNew() {
        #expect(WakeDeduplicator.isNew(range(15.0, 15.8), handledThrough: range(10.0, 10.6).end))
        #expect(WakeDeduplicator.isNew(range(0.0, 1.0), handledThrough: .zero))
    }
}
