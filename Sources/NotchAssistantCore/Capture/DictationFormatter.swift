import Foundation

/// Turns dictated speech into text: spoken punctuation and line breaks,
/// capitals after a sentence ends, spacing, and the two spoken commands
/// ("scratch that", "stop dictation").
public struct DictationFormatter: Sendable {
    public enum Edit: Sendable, Equatable {
        /// Insert this text at the cursor.
        case insert(String)
        /// Remove the last `count` characters inserted ("scratch that").
        case delete(count: Int)
        /// "stop dictation".
        case stop
    }

    /// Characters inserted per stretch of speech, newest last: "scratch
    /// that" removes the last stretch.
    private var stretches: [Int] = []
    private var current = 0
    /// Characters in this stretch since its last sentence end.
    private var sinceSentence = 0
    /// Everything inserted so far, to know whether the next word starts a
    /// sentence.
    private var text = ""
    private var lastCharacter: Character? { text.last }

    public init() {}

    private static let symbols: [(words: [String], text: String, attachesLeft: Bool)] = [
        (["⏎⏎"], "\n\n", true), (["⏎"], "\n", true),
        (["new", "paragraph"], "\n\n", true),
        (["go", "to", "a", "new", "line"], "\n", true), (["go", "to", "the", "next", "line"], "\n", true),
        (["go", "to", "next", "line"], "\n", true), (["new", "line"], "\n", true), (["next", "line"], "\n", true),
        (["full", "stop"], ".", true), (["period"], ".", true), (["comma"], ",", true),
        (["question", "mark"], "?", true), (["exclamation", "mark"], "!", true), (["exclamation", "point"], "!", true),
        (["colon"], ":", true), (["semicolon"], ";", true), (["dash"], " –", true), (["hyphen"], "-", true),
        (["open", "bracket"], "(", false), (["close", "bracket"], ")", true),
        (["open", "quote"], "“", false), (["close", "quote"], "”", true),
    ]
    private static let stopPhrases: [[String]] = [
        ["stop", "dictation"], ["stop", "dictating"], ["end", "dictation"], ["alfred", "stop"], ["alfred", "stop", "dictation"],
    ]
    private static let scratchPhrases: [[String]] = [["scratch", "that"], ["delete", "that"], ["undo", "that"]]

    /// The edits for one finished stretch of speech.
    public mutating func process(_ segment: String) -> [Edit] {
        current = 0
        sinceSentence = 0
        defer { if current > 0 { stretches.append(current) } }
        // Line breaks the recogniser made itself become words, like the
        // spoken ones.
        let marked = segment.replacingOccurrences(of: "\n\n", with: " ⏎⏎ ").replacingOccurrences(of: "\n", with: " ⏎ ")
        let words = marked.split(whereSeparator: \.isWhitespace).map(String.init)
        let keys = words.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        var edits: [Edit] = []
        var pending: [String] = []

        func flushWords() {
            guard !pending.isEmpty else { return }
            append(pending.joined(separator: " "), attachesLeft: false, into: &edits)
            pending = []
        }

        var index = 0
        while index < words.count {
            if let phrase = Self.stopPhrases.first(where: { Self.matches($0, keys, at: index) }) {
                _ = phrase
                flushWords()
                edits.append(.stop)
                return edits
            }
            if let phrase = Self.scratchPhrases.first(where: { Self.matches($0, keys, at: index) }) {
                flushWords()
                // What was said just before in this stretch, else the
                // previous stretch.
                let count = sinceSentence > 0 ? sinceSentence : current > 0 ? current : (stretches.popLast() ?? 0)
                if count > 0 {
                    edits.append(.delete(count: count))
                    text.removeLast(min(count, text.count))
                    current -= min(current, count)
                    sinceSentence = 0
                }
                index += phrase.count
                continue
            }
            if let symbol = Self.symbols.first(where: { Self.matches($0.words, keys, at: index) }) {
                flushWords()
                append(symbol.text, attachesLeft: symbol.attachesLeft, into: &edits)
                index += symbol.words.count
                continue
            }
            pending.append(words[index])
            index += 1
        }
        flushWords()
        return edits
    }

    private static func matches(_ phrase: [String], _ keys: [String], at index: Int) -> Bool {
        index + phrase.count <= keys.count && Array(keys[index..<index + phrase.count]) == phrase
    }

    /// Adds spacing and capitals, and records what was inserted.
    private mutating func append(_ raw: String, attachesLeft: Bool, into edits: inout [Edit]) {
        var text = raw
        let isSymbol = attachesLeft || text == "(" || text == "“"
        if !isSymbol {
            let startsSentence = lastCharacter == nil || ".?!\n".contains(lastCharacter!)
            if startsSentence, let first = text.first {
                text = first.uppercased() + text.dropFirst()
            }
            // A space before words, except at the start or after a break
            // or an opening bracket.
            if let last = lastCharacter, !"\n(“".contains(last) { text = " " + text }
        } else if !attachesLeft, let last = lastCharacter, !"\n(“".contains(last) {
            text = " " + text
        }
        self.text += text
        current += text.count
        sinceSentence = ".?!\n".contains(text.last ?? " ") ? 0 : sinceSentence + text.count
        edits.append(.insert(text))
    }

    /// Transcripts: the stop phrase ends recording ("Alfred, stop
    /// recording"). Returns the text before it, and whether to stop.
    public static func transcriptStop(in segment: String) -> (text: String, stop: Bool) {
        let lower = segment.lowercased()
        for phrase in ["alfred stop recording", "alfred, stop recording", "alfred stop transcribing", "alfred, stop transcribing",
                       "stop transcribing", "stop recording", "alfred stop", "alfred, stop"] {
            if let range = lower.range(of: phrase) {
                let before = String(segment[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                return (before, true)
            }
        }
        return (segment, false)
    }
}
