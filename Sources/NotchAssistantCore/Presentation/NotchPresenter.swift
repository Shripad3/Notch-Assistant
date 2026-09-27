/// Renders state; never decides it (spec §3).
@MainActor
public protocol NotchPresenter: AnyObject, Sendable {
    func render(_ state: AssistantState)
    /// Microphone level while listening, 0...1, for the audio-reactive bars.
    /// Not part of the state machine: it changes many times a second.
    func audioLevel(_ level: Float)
    /// Returns once anything being said has finished, so the microphone
    /// doesn't hear Alfred's own question.
    func finishedSpeaking() async
}

extension NotchPresenter {
    public func audioLevel(_ level: Float) {}
    public func finishedSpeaking() async {}
}
