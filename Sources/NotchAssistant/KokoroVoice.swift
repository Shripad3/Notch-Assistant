import AVFoundation
import FluidAudio
import NotchAssistantCore
import Observation

/// Kokoro-82M, a natural-sounding neural voice, on the Neural Engine
/// (FluidAudio). The model (about 80 MB) is downloaded once from Hugging Face
/// into Application Support; after that it runs offline. It is loaded while
/// the user speaks and unloaded after a few idle minutes, since it holds
/// about 500 MB while loaded.
@MainActor
@Observable
final class KokoroVoice: NeuralVoice {
    static let shared = KokoroVoice()

    enum State: Equatable {
        case notDownloaded
        case downloading
        case ready
        case failed(String)
    }

    /// English voices: a = American, b = British; f = female, m = male.
    static let voices: [(id: String, name: String)] = [
        ("bm_george", "George — British"), ("bm_daniel", "Daniel — British"), ("bm_lewis", "Lewis — British"),
        ("bm_fable", "Fable — British"), ("bf_emma", "Emma — British"), ("bf_isabella", "Isabella — British"),
        ("bf_alice", "Alice — British"), ("bf_lily", "Lily — British"),
        ("am_michael", "Michael — American"), ("am_adam", "Adam — American"), ("am_eric", "Eric — American"),
        ("am_liam", "Liam — American"), ("am_onyx", "Onyx — American"), ("am_fenrir", "Fenrir — American"),
        ("am_echo", "Echo — American"), ("am_puck", "Puck — American"),
        ("af_heart", "Heart — American"), ("af_bella", "Bella — American"), ("af_nicole", "Nicole — American"),
        ("af_sarah", "Sarah — American"), ("af_sky", "Sky — American"), ("af_nova", "Nova — American"),
        ("af_river", "River — American"), ("af_jessica", "Jessica — American"), ("af_kore", "Kore — American"),
        ("af_alloy", "Alloy — American"), ("af_aoede", "Aoede — American"),
    ]

    private(set) var state: State
    private let directory = URL.applicationSupportDirectory.appending(path: "NotchAssistant/Kokoro")
    private var marker: URL { directory.appending(path: ".downloaded") }
    @ObservationIgnored private var manager: KokoroAneManager?
    @ObservationIgnored private var loading: Task<KokoroAneManager?, Never>?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var unload: Task<Void, Never>?
    @ObservationIgnored private var speaking: CheckedContinuation<Void, Never>?
    @ObservationIgnored private lazy var delegate = PlayerDelegate { [weak self] in self?.finished() }

    init() {
        state = FileManager.default.fileExists(atPath: URL.applicationSupportDirectory.appending(path: "NotchAssistant/Kokoro/.downloaded").path)
            ? .ready : .notDownloaded
    }

    /// The Kokoro voice chosen in Settings, if any.
    var chosenVoice: String? {
        let id = UserDefaults.standard.string(forKey: VoiceOption.defaultsKey) ?? ""
        guard id.hasPrefix(Speaker.neuralPrefix) else { return nil }
        return String(id.dropFirst(Speaker.neuralPrefix.count))
    }

    var isActive: Bool { state == .ready && chosenVoice != nil }

    /// Downloads the model (once) and checks that it loads.
    func download() async {
        guard state != .downloading else { return }
        state = .downloading
        if await load() != nil {
            try? Data().write(to: marker)
            state = .ready
            scheduleUnload()
        } else if case .downloading = state {
            state = .failed("The download didn't finish. Check the internet connection and try again.")
        }
    }

    /// Deletes the downloaded model.
    func remove() async {
        stop()
        await manager?.cleanup()
        manager = nil
        try? FileManager.default.removeItem(at: directory)
        state = .notDownloaded
    }

    func warmUp() {
        guard isActive else { return }
        Task { _ = await load() }
    }

    /// Speaks sentence by sentence: each piece is made while the one before
    /// plays, so speech starts sooner and long replies stay within
    /// Kokoro's limit (a long summary once fell back to a system voice).
    func speak(_ text: String) async -> Bool {
        guard isActive, let voice = chosenVoice, let manager = await load() else { return false }
        let pieces = SpeechText.pieces(SpeechText.forNeuralVoice(text))
        guard !pieces.isEmpty else { return true }
        func make(_ piece: String) -> Task<Data?, Never> {
            Task {
                do { return try await manager.synthesize(text: piece, voice: voice) } catch {
                    Log.app.error("kokoro: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }
        }
        var next: Task<Data?, Never>? = make(pieces[0])
        var spokeAny = false
        for index in pieces.indices {
            guard let current = next else { break }
            let wav = await current.value
            next = index + 1 < pieces.count ? make(pieces[index + 1]) : nil
            if Task.isCancelled {
                next?.cancel()
                return true
            }
            // The first piece failing means the system voice should speak
            // instead; a later one is skipped rather than switch voices.
            guard let wav, let player = try? AVAudioPlayer(data: wav) else {
                if !spokeAny { next?.cancel(); return false }
                continue
            }
            player.delegate = delegate
            self.player = player
            spokeAny = true
            await withCheckedContinuation { continuation in
                speaking = continuation
                if !player.play() { finished() }
            }
        }
        scheduleUnload()
        return true
    }

    func stop() {
        player?.stop()
        finished()
    }

    private func finished() {
        player = nil
        speaking?.resume()
        speaking = nil
    }

    /// The loaded model, loading (and on first use downloading) it if needed.
    private func load() async -> KokoroAneManager? {
        unload?.cancel()
        if let manager { return manager }
        if let loading { return await loading.value }
        let directory = directory
        let voice = chosenVoice
        let task = Task { () -> KokoroAneManager? in
            let manager = KokoroAneManager(defaultVoice: voice, directory: directory)
            do {
                try await manager.initialize(preloadVoices: voice.map { [$0] })
                return manager
            } catch {
                Log.app.error("kokoro: load failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        loading = task
        let loaded = await task.value
        loading = nil
        manager = loaded
        if loaded == nil, state == .ready { state = .failed("The natural voice couldn't load. Try downloading it again.") }
        return loaded
    }

    /// Frees the model's memory after a few quiet minutes.
    private func scheduleUnload() {
        unload?.cancel()
        unload = Task { [weak self] in
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled, let self, self.player == nil else { return }
            await self.manager?.cleanup()
            self.manager = nil
        }
    }
}

/// @unchecked: `done` is immutable and only ever run on the main actor.
private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    let done: @MainActor @Sendable () -> Void
    init(done: @escaping @MainActor @Sendable () -> Void) { self.done = done }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let done = done
        Task { @MainActor in done() }
    }
}
