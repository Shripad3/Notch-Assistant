import Foundation

/// Rewrites display text into words a neural voice reads correctly. Kokoro's
/// phonemiser reads "07:00" and "18:30" as "ex: ex", "AM" as the word "am",
/// and silently drops "°", "%" and the minus sign. The system voices don't
/// need this.
public enum SpeechText {
    public static func forNeuralVoice(_ text: String) -> String {
        var text = text
            // Formatters put narrow and ordinary no-break spaces in "7:00 AM".
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        text = replace(#"(\d+):(\d{2})\.(\d)\b"#, in: text) { groups in
            // A stopwatch reading, "1:23.4".
            let minutes = Int(groups[1]) ?? 0
            return "\(minutes) minute\(minutes == 1 ? "" : "s") \(Int(groups[2]) ?? 0).\(groups[3]) seconds"
        }
        text = replace(#"\b(\d{1,2}):(\d{2})(?::\d{2})?(?:\s*"# + meridiem + ")?", in: text) { groups in
            clockTime(hour: Int(groups[1]) ?? 0, minute: Int(groups[2]) ?? 0, meridiem: (groups[3] + groups[4]).lowercased())
        }
        // "7 AM" / "7 a.m." without minutes.
        text = replace(#"\b(\d{1,2})\s*"# + meridiem, in: text) { groups in
            "\(groups[1]) \((groups[2] + groups[3]).lowercased() == "a" ? "A M" : "PM")"
        }
        text = replace(#"[−–-](\d)"#, in: text, onlyAfterSpaceOrStart: true) { groups in "minus \(groups[1])" }
        text = replace(#"(\d)\s?°[CF]?"#, in: text) { groups in "\(groups[1]) degrees" }
        text = replace(#"(\d)\s?%"#, in: text) { groups in "\(groups[1]) percent" }
        return text
    }

    /// "a.m." (its full stops belong to it) or "am"/"AM"/"A M" (a full stop
    /// after it ends the sentence). Two groups: the letter, either way.
    private static let meridiem = #"(?:([AaPp])\.\s?[Mm]\.|([AaPp])\s?[Mm])(?![A-Za-z])"#

    /// Short pieces for a neural voice, at sentence ends, then commas, then
    /// words: Kokoro takes at most about 500 phonemes at once, and speaking
    /// the first piece while the next is made starts the reply sooner.
    public static func pieces(_ text: String, maximum: Int = 180) -> [String] {
        var sentences: [String] = []
        var current = ""
        for char in text {
            current.append(char)
            if ".?!;\n".contains(char) {
                sentences.append(current)
                current = ""
            }
        }
        sentences.append(current)
        var pieces: [String] = []
        for sentence in sentences.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !sentence.isEmpty {
            if sentence.count <= maximum {
                pieces.append(sentence)
                continue
            }
            // Too long: at commas, then by words.
            var part = ""
            for word in sentence.split(separator: " ") {
                let candidate = part.isEmpty ? String(word) : part + " " + word
                if candidate.count > maximum || (part.hasSuffix(",") && part.count > maximum / 2) {
                    pieces.append(part)
                    part = String(word)
                } else {
                    part = candidate
                }
            }
            if !part.isEmpty { pieces.append(part) }
        }
        return pieces
    }

    /// "7 A M", "6 30 PM", "7 oh 5 A M", "12 noon", "midnight". Without am/pm
    /// the time is 24-hour (as on a Mac set to 24-hour time).
    static func clockTime(hour: Int, minute: Int, meridiem: String) -> String {
        var hour12 = hour
        var suffix: String
        switch meridiem {
        case "a": suffix = "A M"
        case "p": suffix = "PM"
        default:
            suffix = hour < 12 ? "A M" : "PM"
            hour12 = hour % 12 == 0 ? 12 : hour % 12
        }
        if meridiem.isEmpty, minute == 0, hour == 0 { return "midnight" }
        if minute == 0, hour12 == 12, suffix == "PM" { return "12 noon" }
        if hour12 > 12 { hour12 -= 12; suffix = "PM" }
        let minutes = minute == 0 ? "" : minute < 10 ? " oh \(minute)" : " \(minute)"
        return "\(hour12)\(minutes) \(suffix)"
    }

    private static func replace(_ pattern: String, in text: String, onlyAfterSpaceOrStart: Bool = false, _ transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let source = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            if onlyAfterSpaceOrStart, match.range.location > 0 {
                let before = source.substring(with: NSRange(location: match.range.location - 1, length: 1))
                // "10-20" is a range, not a negative number.
                guard before == " " || before == "(" else { continue }
            }
            result += source.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
            result += transform(groups)
            last = match.range.location + match.range.length
        }
        return result + source.substring(from: last)
    }
}
