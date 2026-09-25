public enum ActivationEvent: Sendable, Equatable {
    case triggered
    /// Hands-free: the wake word was heard. The endpointer, not a key
    /// release, ends the utterance.
    case wake(WakeContext)
    /// Hold-to-talk release: ends capture, which is the endpoint.
    case released
    /// Routed to the same path as Escape.
    case cancelled
}

@MainActor
public protocol ActivationSource: AnyObject {
    var events: AsyncStream<ActivationEvent> { get }
    func start() throws
    func stop()
}
