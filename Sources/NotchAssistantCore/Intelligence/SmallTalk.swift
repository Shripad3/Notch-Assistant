/// Short replies to greetings and chit-chat, without the model. Given
/// "Hi how are you", the model picked tools anyway (turned the volume down
/// and searched Google). The notch is not a chat window (spec §1), so these
/// stay a handful of fixed lines.
enum SmallTalk {
    static func reply(to transcript: String) -> String? {
        var text = AppNameMatcher.normalize(transcript)
        let name = AppNameMatcher.normalize(WakePhrase.displayName)
        if text.hasPrefix(name + " ") { text.removeFirst(name.count + 1) }
        if text.hasSuffix(" " + name) { text.removeLast(name.count + 1) }
        if text == name { return "Yeah? What's up?" }
        if ["who are you", "what s your name", "what is your name"].contains(text) {
            return "I'm \(WakePhrase.displayName). I live in your notch."
        }
        for prefix in ["hey ", "hi ", "hello ", "okay ", "ok "] where text.hasPrefix(prefix) && text.count > prefix.count {
            let rest = String(text.dropFirst(prefix.count))
            if replies[rest] != nil { text = rest }
        }
        return replies[text]
    }

    private static let replies: [String: String] = {
        var table: [String: String] = [:]
        for greeting in ["hi", "hello", "hey", "hey there", "hello there", "yo"] {
            table[greeting] = "Hey! What's up?"
        }
        table["good morning"] = "Morning! What's up?"
        table["good afternoon"] = "Hey, good afternoon! What's up?"
        table["good evening"] = "Evening! What's up?"
        table["good night"] = "Night! Sleep well."
        for sendIt in ["send it", "send", "send it now", "send that", "send the message", "send the email"] {
            table[sendIt] = "There's nothing waiting to be sent."
        }
        // A yes or no with nothing asked (e.g. the question timed out).
        for answer in ["yes", "yeah", "yep", "no", "nope", "yes please", "no thanks", "do it", "go ahead", "confirm", "cancel"] {
            table[answer] = "There's nothing waiting for an answer."
        }
        for thanks in ["thanks", "thank you", "thanks a lot", "thank you so much", "cheers", "much appreciated"] {
            table[thanks] = "Anytime!"
        }
        for help in ["what can you do", "help", "what can i ask you", "what do you do"] {
            table[help] = "Loads: apps, websites and files; music; timers, alarms and reminders; your calendar; calls, texts and email; notes, dictation and meeting transcripts; the weather; or just a chat."
        }
        return table
    }()
}
