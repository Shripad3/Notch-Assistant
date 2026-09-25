import Foundation

/// Resolves a spoken app name against installed app names. Pure, so the
/// spoken-name table in the tests covers it without touching the disk.
/// When no match is confident, returns nil rather than guessing (spec §9).
enum AppNameMatcher {
    /// Keys are compact keys (see `key(_:)`).
    static let defaultAliases: [String: String] = [
        "vscode": "Visual Studio Code",
        "code": "Visual Studio Code",
        "settings": "System Settings",
        "systempreferences": "System Settings",
        "preferences": "System Settings",
        "ark": "Arc",
        "appstore": "App Store",
        "facetime": "FaceTime",
    ]

    static let genericBrowserKeys: Set<String> = ["browser", "mybrowser", "webbrowser", "defaultbrowser", "thebrowser"]

    static func isGenericBrowser(_ spoken: String) -> Bool {
        genericBrowserKeys.contains(key(spoken))
    }

    static func match(_ spoken: String, candidates: [String], aliases: [String: String] = defaultAliases) -> String? {
        var query = normalize(spoken)
        guard !query.isEmpty else { return nil }
        if let alias = aliases[query.replacingOccurrences(of: " ", with: "")] {
            query = normalize(alias)
        }
        let queryKey = query.replacingOccurrences(of: " ", with: "")

        // 1. Exact, ignoring case, punctuation and spacing.
        if let exact = candidates.first(where: { key($0) == queryKey }) {
            return exact
        }

        // 2. Every spoken word appears as a whole word in the app name
        //    ("chrome" → "Google Chrome"). Among several, the one with the
        //    fewest extra words wins, but only if it is strictly shortest.
        let queryWords = query.split(separator: " ").map(String.init)
        let wordMatches = candidates.filter { candidate in
            let words = Set(normalize(candidate).split(separator: " ").map(String.init))
            return queryWords.allSatisfy(words.contains)
        }
        if let best = uniqueShortest(wordMatches) {
            return best
        }

        // 3. Close spelling, for mis-transcriptions ("spotfy"). Requires a
        //    clear winner so near-ties fail instead of launching the wrong app.
        guard queryKey.count >= 4 else { return nil }
        let scored = candidates
            .map { ($0, similarity(queryKey, key($0))) }
            .sorted { $0.1 > $1.1 }
        guard let first = scored.first, first.1 >= 0.8 else { return nil }
        if scored.count > 1, first.1 - scored[1].1 < 0.1 { return nil }
        return first.0
    }

    /// Lowercased, diacritics folded, ".app" and filler words dropped,
    /// punctuation removed, single-spaced.
    static func normalize(_ text: String) -> String {
        let folded = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
            .replacingOccurrences(of: ".app", with: "")
        let spaced = String(folded.map { (c: Character) -> Character in c.isLetter || c.isNumber ? c : " " })
        var words = spaced.split(separator: " ").map(String.init)
        if words.first == "the" { words.removeFirst() }
        if words.count > 1, ["app", "application"].contains(words.last) { words.removeLast() }
        return words.joined(separator: " ")
    }

    static func key(_ text: String) -> String {
        normalize(text).replacingOccurrences(of: " ", with: "")
    }

    private static func uniqueShortest(_ names: [String]) -> String? {
        let counted = names.map { ($0, normalize($0).split(separator: " ").count) }.sorted { $0.1 < $1.1 }
        guard let first = counted.first else { return nil }
        if counted.count > 1, counted[1].1 == first.1 { return nil }
        return first.0
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 1 }
        return 1 - Double(levenshtein(Array(a), Array(b))) / Double(longest)
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return previous[b.count]
    }
}
