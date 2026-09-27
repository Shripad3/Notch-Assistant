@preconcurrency import AVFoundation
import CoreMedia
@preconcurrency import ScreenCaptureKit
import Speech
import Synchronization

/// Long-running on-device transcription of one audio source (the
/// microphone, or the Mac's own audio for the other side of a call), with
/// Apple's DictationTranscriber. Finished stretches of speech arrive through
/// `onSegment`; drafts through `onDraft`. Audio is never sent anywhere.
final class LiveTranscriber: @unchecked Sendable {
    enum Source: Sendable { case microphone(saveAudioTo: URL?), systemAudio }

    // Touched only on `queue`, apart from start/stop bookkeeping in `state`.
    private let queue = DispatchQueue(label: "dev.shripad.NotchAssistant.capture", qos: .userInitiated)
    private var converter: AVAudioConverter?
    private var audioFile: AVAudioFile?
    private let state = Mutex<Running?>(nil)
    private let onSegment: @Sendable (String, TimeInterval) -> Void
    private let onDraft: @Sendable (String) -> Void
    private let punctuate: Bool

    private struct Running {
        var analyzer: SpeechAnalyzer
        var input: AsyncStream<AnalyzerInput>.Continuation
        var results: Task<Void, Never>
        var engine: AVAudioEngine?
        var system: SystemAudioCapture?
    }

    /// `punctuate`: automatic punctuation, for transcripts. Dictation leaves
    /// it off so spoken "comma" and "full stop" decide.
    init(punctuate: Bool, onSegment: @escaping @Sendable (String, TimeInterval) -> Void, onDraft: @escaping @Sendable (String) -> Void) {
        self.punctuate = punctuate
        self.onSegment = onSegment
        self.onDraft = onDraft
    }

    func start(_ source: Source) async throws {
        let locale = await SpeechWakeListener.locale()
        let transcriber = DictationTranscriber(
            locale: locale,
            contentHints: [],
            transcriptionOptions: punctuate ? [.punctuation] : [],
            reportingOptions: [.volatileResults, .frequentFinalization],
            attributeOptions: [.audioTimeRange]
        )
        if await AssetInventory.status(forModules: [transcriber]) != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AssistantFailure("Speech recognition isn't available for this language")
        }
        let context = AnalysisContext()
        context.contextualStrings[.general] = ["Alfred"] + ContactBook.shared.namesForRecognition(limit: 100)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.setContext(context)
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(256))
        try await analyzer.start(inputSequence: stream)

        let onSegment = onSegment, onDraft = onDraft
        let results = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    if result.isFinal {
                        onSegment(text, result.range.start.seconds.isFinite ? result.range.start.seconds : 0)
                    } else {
                        onDraft(text)
                    }
                }
            } catch {
                Log.speech.error("capture: recognizer stopped: \(error.localizedDescription, privacy: .public)")
            }
        }

        var running = Running(analyzer: analyzer, input: input, results: results)
        switch source {
        case .microphone(let saveTo):
            let engine = AVAudioEngine()
            let node = engine.inputNode
            let micFormat = node.outputFormat(forBus: 0)
            guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else { throw AssistantFailure("No microphone input is available") }
            if let saveTo {
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: micFormat.sampleRate,
                    AVNumberOfChannelsKey: micFormat.channelCount, AVEncoderBitRateKey: 64_000,
                ]
                audioFile = try AVAudioFile(forWriting: saveTo, settings: settings, commonFormat: micFormat.commonFormat, interleaved: micFormat.isInterleaved)
            }
            node.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { [weak self] buffer, _ in
                guard let self, let copy = buffer.copied() else { return }
                self.queue.async { self.ingest(copy, to: format, input: input, save: true) }
            }
            engine.prepare()
            try engine.start()
            running.engine = engine
        case .systemAudio:
            let system = SystemAudioCapture { [weak self] buffer in
                guard let self else { return }
                self.queue.async { self.ingest(buffer, to: format, input: input, save: false) }
            }
            try await system.start()
            running.system = system
        }
        state.withLock { $0 = running }
    }

    /// Stops listening and waits (up to 5 s) for the last words.
    func stop() async {
        guard let running = state.withLock({ current -> Running? in
            defer { current = nil }
            return current
        }) else { return }
        running.engine?.stop()
        running.engine?.inputNode.removeTap(onBus: 0)
        await running.system?.stop()
        running.input.finish()
        try? await running.analyzer.finalizeAndFinishThroughEndOfInput()
        _ = await withTaskGroup(of: Void.self) { group in
            group.addTask { await running.results.value }
            group.addTask { try? await Task.sleep(for: .seconds(5)) }
            await group.next()
            group.cancelAll()
        }
        running.results.cancel()
        queue.sync { audioFile = nil }
    }

    private func ingest(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat, input: AsyncStream<AnalyzerInput>.Continuation, save: Bool) {
        if save { try? audioFile?.write(from: buffer) }
        guard let converted = convert(buffer, to: format) else { return }
        input.yield(AnalyzerInput(buffer: converted))
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter?.inputFormat != buffer.format || converter?.outputFormat != format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
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

/// The Mac's own audio output (the other side of a call), through
/// ScreenCaptureKit. Needs the Screen & System Audio Recording permission.
final class SystemAudioCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    private let queue = DispatchQueue(label: "dev.shripad.NotchAssistant.systemaudio", qos: .userInitiated)
    private var stream: SCStream?

    init(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.onBuffer = onBuffer
    }

    func start() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw AssistantFailure("To hear the other side of calls, allow Notch Assistant in Screen & System Audio Recording", link: .screenRecording)
        }
        guard let display = content.displays.first else { throw ToolError("There's no display to capture audio from") }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        // Audio only: the smallest, slowest video the API allows.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let buffer = Self.pcm(sampleBuffer) else { return }
        onBuffer(buffer)
    }

    private static func pcm(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: basic) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
