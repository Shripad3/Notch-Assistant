import Foundation
/// A normalised command for tools' direct matching: "Please open YouTube in
/// Arc" → text "open youtube in arc", verb "open", rest "youtube in arc".
/// Commands without a known leading verb ("mute") have an empty verb and the
/// whole text as rest.
public struct DirectCommand: Sendable, Equatable {
    public let text: String
    public let verb: String
    public let rest: String
    /// The transcript as said, for tools that parse "7:30" or "1.5 hours",
    /// which `text` splits apart.
    public let original: String

    static let verbs = ["go to", "look up", "search for", "open", "launch", "start", "search", "google", "play", "watch"]
    private static let fillers = ["please ", "can you ", "could you ", "would you ", "will you ", "hey ", "alfred ", "okay ", "ok "]

    init?(_ transcript: String) {
        var text = AppNameMatcher.normalize(transcript)
        var original = transcript.trimmingCharacters(in: .whitespaces)
        // "Can you please summarise …" → "summarise …", in both forms, so
        // tools anchored on the start of the sentence still recognise it.
        var stripped = true
        while stripped {
            stripped = false
            for filler in Self.fillers where text.hasPrefix(filler) {
                text.removeFirst(filler.count)
                original = Self.dropping(filler, from: original)
                stripped = true
            }
        }
        if text.hasSuffix(" please") { text.removeLast(" please".count) }
        guard !text.isEmpty else { return nil }
        self.original = original
        self.text = text
        if let verb = Self.verbs.first(where: { text.hasPrefix($0 + " ") }) {
            self.verb = verb
            self.rest = String(text.dropFirst(verb.count + 1)).trimmingCharacters(in: .whitespaces)
        } else {
            self.verb = ""
            self.rest = text
        }
    }

    /// The original with a spoken filler removed from its start, ignoring
    /// case and the punctuation after it ("Alfred, open …").
    private static func dropping(_ filler: String, from original: String) -> String {
        let word = filler.trimmingCharacters(in: .whitespaces)
        guard original.lowercased().hasPrefix(word) else { return original }
        return String(original.dropFirst(word.count)).trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ",")))
    }

    /// Splits "youtube in arc" into ("youtube", "arc").
    var target: (thing: String, browser: String?) {
        if let range = rest.range(of: " in ", options: .backwards) {
            return (String(rest[..<range.lowerBound]), String(rest[range.upperBound...]))
        }
        return (rest, nil)
    }
}

/// Recognises simple single-action commands without the model. The on-device
/// model is not deterministic: "Open YouTube" gave openURL once and
/// webSearch twice in a row. The common cases have to be reliable, so they
/// never reach it. Anything not matched goes to the model as before.
enum DirectMatcher {
    static func plan(for transcript: String, tools: [AnyAssistantTool]) -> Plan? {
        guard let command = DirectCommand(transcript) else { return nil }
        // Compound commands are several steps; only the model plans those.
        // Without this, "open Arc and play the … video" matched as a file.
        guard !isCompound(command.text) else { return nil }
        // Registry order decides ties: an installed app beats a website of
        // the same name, as with "open Spotify".
        for tool in tools {
            if let arguments = tool.directArguments(for: command) {
                return Plan(steps: [PlannedStep(tool: tool, arguments: arguments, transcript: transcript)], isDirect: true)
            }
        }
        return nil
    }

    /// "and" that joins two commands, not "an hour and a half", "1 hour
    /// and 30 minutes" or a reminder's "bread and milk".
    static func isCompound(_ text: String) -> Bool {
        // Their "and" is part of what's said: "remind me to buy bread and
        // milk", "note that I need eggs and flour", "open Notes and type …".
        let whole = ["remind me ", "set a reminder ", "add a reminder ", "note that ", "note down ", "take a note ", "make a note ",
                     "jot down ", "write down ", "note to self "]
        if whole.contains(where: text.hasPrefix) { return false }
        if text.range(of: #"^open (my |the )?notes( app)? and (type|write|add|put|note|jot) "#, options: .regularExpression) != nil { return false }
        var padded = " \(text) "
        for joined in [" and a half ", " and half "] {
            padded = padded.replacingOccurrences(of: joined, with: " ")
        }
        // "1 hour and 30 minutes".
        padded = padded.replacingOccurrences(
            of: #" (hours?|minutes?) and (\w+ ){1,2}(minutes?|seconds?) "#, with: " $1 $3 ", options: .regularExpression)
        // "every Monday and Wednesday".
        padded = padded.replacingOccurrences(
            of: #" ((mon|tues|wednes|thurs|fri|satur|sun)days?) and (?=(mon|tues|wednes|thurs|fri|satur|sun)days?\b)"#,
            with: " $1 ", options: .regularExpression)
        return padded.contains(" and ") || padded.contains(" then ")
    }
}
