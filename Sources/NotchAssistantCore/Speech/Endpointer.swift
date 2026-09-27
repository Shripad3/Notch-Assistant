/// Decides when a hands-free utterance has ended (spec §7). Hold-to-talk
/// needs none of this: releasing the key is the endpoint.
///
/// - 0.8 s below the speech threshold after speech ends the utterance.
/// - 2 s with no speech at all cancels, without invoking the model.
/// - 10 s is a hard cap.
///
/// The threshold sits a margin above the room's noise floor, so a fan or
/// music can't hold the microphone open. The floor comes from the wake-word
/// listener, which has been hearing the room; failing that, it is sampled
/// from the first 200 ms.
public struct Endpointer: Sendable {
    public enum Decision: Sendable, Equatable {
        case listening
        case endOfSpeech
        case noSpeech
    }

    public static let trailingSilence = 0.8
    public static let noSpeechTimeout = 2.0
    public static let hardCap = 10.0
    static let calibration = 0.2
    /// Speech is this many dB above the noise floor.
    static let speechMargin: Float = 10
    /// Floors below this are treated as this, so a near-silent room doesn't
    /// make breathing count as speech.
    static let minimumFloor: Float = -60

    /// Seconds without any speech before giving up: longer when answering
    /// one of Alfred's questions, since people think first.
    private let patience: Double
    private var floor: Float?
    private var calibrationLevels: [Float] = []
    private var elapsed = 0.0
    private var heardSpeech = false
    private var silence = 0.0

    public init(ambientFloor: Float? = nil, patience: Double = Endpointer.noSpeechTimeout) {
        floor = ambientFloor.map { max($0, Self.minimumFloor) }
        self.patience = patience
    }

    /// Feed each audio buffer's level (dBFS) and duration in seconds.
    public mutating func feed(level: Float, duration: Double) -> Decision {
        elapsed += duration
        if elapsed >= Self.hardCap { return heardSpeech ? .endOfSpeech : .noSpeech }

        guard let floor else {
            calibrationLevels.append(level)
            if elapsed >= Self.calibration {
                let average = calibrationLevels.reduce(0, +) / Float(calibrationLevels.count)
                self.floor = max(average, Self.minimumFloor)
            }
            return .listening
        }

        if level >= floor + Self.speechMargin {
            heardSpeech = true
            silence = 0
        } else {
            silence += duration
        }

        if heardSpeech, silence >= Self.trailingSilence { return .endOfSpeech }
        if !heardSpeech, elapsed >= patience { return .noSpeech }
        return .listening
    }
}
