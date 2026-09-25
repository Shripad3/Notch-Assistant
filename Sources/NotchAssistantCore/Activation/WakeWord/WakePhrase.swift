/// Second-stage check on a wake-word detection (spec §6: false positives
/// are the main risk). The recognizer hears the audio from before the
/// detection, so a real "Alfred" shows up in the transcript; a detection
/// whose transcript has no such word is dropped silently.
public enum WakePhrase {
    public static let name = "alfred"
    /// How far into the transcript the wake word may appear: the recognizer
    /// gets ~1.5 s of audio from before the detection, so it comes early.
    static let searchWords = 10

    /// The command with the wake word removed, or nil when the transcript
    /// doesn't contain it (a false detection).
    ///
    /// "Hey Alfred, open Spotify" → "open Spotify".
    /// "Good morning Alfred" → "Good morning Alfred" (small talk answers it).
    public static func command(from transcript: String) -> String? {
        let words = transcript.split(separator: " ").map(String.init)
        let keys = words.map(AppNameMatcher.key)
        for index in keys.indices.prefix(searchWords) {
            var length = 0
            if isWakeWord(keys[index]) {
                length = 1
            } else if index + 1 < keys.count, isWakeWord(keys[index] + keys[index + 1]) {
                length = 2 // "Al fred"
            }
            guard length > 0 else { continue }
            let after = words[(index + length)...].joined(separator: " ")
            let command = after.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            return command.isEmpty ? transcript : command
        }
        return nil
    }

    /// True when the wake word appears anywhere in `text` (the recognizer
    /// listener's check; the coordinator confirms with `command(from:)`).
    public static func contains(_ text: String) -> Bool {
        let keys = text.split(separator: " ").map { AppNameMatcher.key(String($0)) }
        return keys.indices.contains { index in
            isWakeWord(keys[index]) || (index + 1 < keys.count && isWakeWord(keys[index] + keys[index + 1]))
        }
    }

    /// Exact, a known mis-hearing, or close in spelling.
    static func isWakeWord(_ key: String) -> Bool {
        key == name || ["alfreds", "alfredo", "alfie", "alford", "alfrid"].contains(key)
            || (key.count >= 5 && AppNameMatcher.similarity(key, name) >= 0.7)
    }
}
