/// Short replies to greetings and chit-chat, without the model. Given
/// "Hi how are you", the model picked tools anyway (turned the volume down
/// and searched Google). The notch is not a chat window (spec §1), so these
/// stay a handful of fixed lines.
enum SmallTalk {
    static func reply(to transcript: String) -> String? {
        var text = AppNameMatcher.normalize(transcript)
        for name in ["alfred"] {
            if text.hasPrefix(name + " ") { text.removeFirst(name.count + 1) }
            if text.hasSuffix(" " + name) { text.removeLast(name.count + 1) }
            if text == name { return "Yes? What can I do for you?" }
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
            table[greeting] = "Hello. What can I do for you?"
        }
        table["good morning"] = "Good morning. What can I do for you?"
        table["good afternoon"] = "Good afternoon. What can I do for you?"
        table["good evening"] = "Good evening. What can I do for you?"
        table["good night"] = "Good night."
        for sendIt in ["send it", "send", "send it now", "send that", "send the message", "send the email"] {
            table[sendIt] = "There's nothing waiting to be sent."
        }
        for question in ["how are you", "how are you doing", "how s it going", "how are things", "you ok", "are you ok"] {
            table[question] = "All running smoothly. What can I do for you?"
        }
        for thanks in ["thanks", "thank you", "thanks a lot", "thank you so much", "cheers", "much appreciated"] {
            table[thanks] = "You're welcome."
        }
        for identity in ["who are you", "what s your name", "what is your name"] {
            table[identity] = "I'm Alfred, the assistant in your notch."
        }
        for help in ["what can you do", "help", "what can i ask you", "what do you do"] {
            table[help] = "I can open apps, websites and files, search the web and YouTube, control Spotify, and change the volume."
        }
        return table
    }()
}
