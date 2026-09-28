import Foundation
import Synchronization

/// Talking over Alfred: while it speaks, the wake-word recognizer treats
/// words that aren't Alfred's own as the user interrupting, so it stops and
/// listens without "Alfred" first. Only with the microphone's echo
/// cancellation on; without it, Alfred would hear itself.
public enum BargeIn {
    /// The words Alfred is saying now, or nil when it is quiet.
    private static let speaking = Mutex<Set<String>?>(nil)
    /// Said over Alfred to just make it stop.
    static let stopWords: Set<String> = ["stop", "wait", "quiet", "enough", "shut up", "stop talking", "be quiet", "okay stop", "ok stop", "thanks", "thank you"]

    public static func began(_ text: String) {
        let words = Set(AppNameMatcher.normalize(SpeechText.forNeuralVoice(text)).split(separator: " ").map(String.init)
            + AppNameMatcher.normalize(text).split(separator: " ").map(String.init))
        speaking.withLock { $0 = words }
    }

    public static func ended() {
        speaking.withLock { $0 = nil }
    }

    static var isArmed: Bool { speaking.withLock { $0 != nil } && VoiceProcessing.isEnabled }

    /// True when what the recognizer heard is the user, not Alfred's echo:
    /// "stop", or at least two words, most of them not in Alfred's sentence.
    static func isInterruption(_ heard: String, armed: Bool = isArmed) -> Bool {
        guard armed, let spoken = speaking.withLock({ $0 }) else { return false }
        return isInterruption(heard, over: spoken)
    }

    static func isInterruption(_ heard: String, over spoken: Set<String>) -> Bool {
        let text = AppNameMatcher.normalize(heard)
        if stopWords.contains(text) { return true }
        let words = text.split(separator: " ").map(String.init)
        let foreign = words.filter { !spoken.contains($0) }
        return foreign.count >= 2 && foreign.count * 3 >= words.count * 2
    }

    /// "Stop" said over Alfred ends things; it isn't a command.
    static func isJustStop(_ transcript: String) -> Bool {
        stopWords.contains(AppNameMatcher.normalize(transcript))
    }
}

/// How long Alfred keeps listening, without the wake word, after it has
/// answered or done something: 0 turns it off.
public enum ListenAfterReply {
    public static let key = "listen.afterReply"
    public static let choices: [Double] = [0, 3, 4, 5]
    public static var seconds: Double { UserDefaults.standard.object(forKey: key) as? Double ?? 4 }

    /// Said into that window, these close it instead of being commands.
    static let closings: Set<String> = [
        "thanks", "thank you", "thanks alfred", "thank you alfred", "okay", "ok", "cool", "great", "nice", "got it", "no", "nope",
        "that s all", "that s it", "nothing", "never mind", "no thanks", "all good", "perfect", "alright", "all right",
    ]
}
