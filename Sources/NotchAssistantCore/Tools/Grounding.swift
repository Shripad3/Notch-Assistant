import Foundation

/// The transcript of the command being executed, available to tools while
/// they run.
enum CommandContext {
    @TaskLocal static var transcript: String?
    /// False for steps followed by others: a step with a side effect only
    /// suitable at the end (opening a single found file) skips it.
    @TaskLocal static var isFinalStep = true
}

/// Checks that a model-supplied value actually came from what the user said.
/// The 3B model borrows names from tool-description examples and invents
/// details (a browser, a video ID); tools use this to drop what the user
/// never said instead of acting on it.
enum Grounding {
    /// True when every word of `phrase` appears, in order and contiguous, in
    /// the transcript. Word-level, so "arc" does not match inside "search".
    static func mentions(_ phrase: String, in transcript: String) -> Bool {
        let needle = words(phrase)
        let haystack = words(transcript)
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        return (0...(haystack.count - needle.count)).contains { start in
            Array(haystack[start..<start + needle.count]) == needle
        }
    }

    /// True when the user said "my browser", "the browser" and so on.
    static func mentionsGenericBrowser(in transcript: String) -> Bool {
        words(transcript).contains("browser")
    }

    /// When the model expanded an alias ("vs code" → "Visual Studio Code"),
    /// returns the alias the user actually said.
    /// Matched against runs of whole spoken words, so the alias "code" is
    /// not found inside "xcode".
    static func spokenAlias(for appName: String, in transcript: String) -> String? {
        let spoken = words(transcript)
        let runs = Set(spoken.indices.flatMap { start in
            (start..<min(start + 3, spoken.count)).map { end in spoken[start...end].joined() }
        })
        let target = AppNameMatcher.key(appName)
        return AppNameMatcher.defaultAliases
            .filter { alias, name in AppNameMatcher.key(name) == target && runs.contains(alias) }
            .map(\.key)
            .max { $0.count < $1.count }
    }

    /// True when the URL's path and query were spoken ("github.com/apple").
    /// A bare host is always acceptable: it is just the site's home page.
    static func isSpoken(_ url: URL, in transcript: String) -> Bool {
        let path = url.path()
        guard (path.isEmpty || path == "/"), url.query() == nil else {
            let spoken = compact(transcript)
            let host = (url.host() ?? "").replacingOccurrences(of: "www.", with: "")
            return spoken.contains(compact(host + path))
        }
        return true
    }

    private static func words(_ text: String) -> [String] {
        AppNameMatcher.normalize(text).split(separator: " ").map(String.init)
    }

    private static func compact(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: " ", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
