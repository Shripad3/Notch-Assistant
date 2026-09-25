public enum TranscriptionUpdate: Sendable, Equatable {
    /// The running transcript so far.
    case partial(String)
    /// Input level, 0...1.
    case level(Float)
    /// Hands-free only: the endpointer heard the user stop speaking.
    case endOfSpeech
    /// Hands-free only: nothing was said after the wake word.
    case noSpeech
}

/// Audio in, endpointed transcript out (spec §3).
public protocol TranscriptionService: Sendable {
    /// Requests microphone and speech permissions ahead of first use, so the
    /// first command is not lost to a permission dialog.
    func prepare() async
    /// Starts capture. `onUpdate` receives partial transcripts and levels.
    /// With a wake context, its audio is recognised first and the endpointer
    /// decides when the utterance ends; without one (hold-to-talk), the
    /// caller does, by calling `finish()`.
    func start(wake: WakeContext?, onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void) async throws
    /// Ends capture, releases the microphone, and returns the final
    /// transcript (empty if nothing was said).
    func finish() async -> String
    func cancel() async
}
