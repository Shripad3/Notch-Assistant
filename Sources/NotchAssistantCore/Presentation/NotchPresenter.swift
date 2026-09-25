/// Renders state; never decides it (spec §3).
@MainActor
public protocol NotchPresenter: AnyObject, Sendable {
    func render(_ state: AssistantState)
    /// Microphone level while listening, 0...1, for the audio-reactive bars.
    /// Not part of the state machine: it changes many times a second.
    func audioLevel(_ level: Float)
}

extension NotchPresenter {
    public func audioLevel(_ level: Float) {}
}
