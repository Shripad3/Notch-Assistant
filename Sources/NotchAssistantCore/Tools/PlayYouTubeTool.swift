import Foundation
import FoundationModels

@Generable
struct PlayYouTubeArguments: Sendable {
    @Guide(description: "What to find on YouTube, e.g. \"Mat Armstrong\" or \"lofi hip hop\"")
    var query: String
    @Guide(description: "True if the user asked for the latest, newest or most recent video")
    var latest: Bool?
    @Guide(description: "Browser name, only if the user named one, e.g. \"Arc\"")
    var browser: String?
}

/// spec §9's playYouTube. Tier 1 opens YouTube's search results, which is
/// deterministic and needs no permission. Tier 2 (`YouTubeAutoplay`) then
/// presses the first real video through Accessibility, and on any failure
/// leaves the results page as it is.
struct PlayYouTubeTool: AssistantTool {
    let name = "playYouTube"
    let title = "YouTube"
    let symbol = "play.rectangle"
    let description = """
        Find videos on YouTube. "play the Mat Armstrong video on YouTube" → query "Mat Armstrong". \
        "Mat Armstrong's latest video on YouTube in Arc" → query "Mat Armstrong", latest true, browser "Arc"; no openApp step. \
        Never use openURL with a made-up video link.
        """
    let requiresNetwork = true
    let permission = ToolPermission.none
    let reversibility = Reversibility.notApplicable

    func target(of arguments: PlayYouTubeArguments) -> String {
        arguments.query + (arguments.latest == true ? " · latest" : "")
    }

    func execute(_ arguments: PlayYouTubeArguments) async throws -> ToolResult {
        var latest = arguments.latest == true
        if latest, let transcript = CommandContext.transcript {
            latest = Self.latestWords.contains { Grounding.mentions($0, in: transcript) }
        }
        guard let url = Self.searchURL(for: arguments.query, latest: latest) else {
            throw ToolError("What should I look for on YouTube?")
        }
        try Task.checkCancellation()
        let spokenBrowser = Browser.grounded(arguments.browser)
        let what = latest ? "latest “\(arguments.query)” videos" : "“\(arguments.query)”"

        // Tier 2, preferred path: open the results in a tab created by
        // script, so that exact tab becomes the video (search and video in
        // one tab). Any failure keeps Tier 1.
        if YouTubeAutoplay.isEnabled, let app = Browser.runningApp(named: spokenBrowser),
           let tabID = await YouTubeAutoplay.openResultsTab(url, in: app) {
            let place = app.localizedName.map { " in \($0)" } ?? ""
            if let title = try await YouTubeAutoplay.playFirstResult(in: app, tab: .id(tabID)) {
                return ToolResult("Playing “\(title)”" + place)
            }
            return ToolResult("YouTube results for \(what)" + place)
        }

        let browser = try await Browser.open(url, in: spokenBrowser)
        let place = browser.map { " in \($0)" } ?? ""
        if YouTubeAutoplay.isEnabled, let app = Browser.runningApp(named: spokenBrowser),
           let title = try await YouTubeAutoplay.playFirstResult(in: app, tab: .search(YouTubeAutoplay.searchWord(for: arguments.query))) {
            return ToolResult("Playing “\(title)”" + place)
        }
        return ToolResult("YouTube results for \(what)" + place)
    }

    static let latestWords = ["latest", "newest", "most recent", "new", "recent", "last"]

    /// youtube.com/results, optionally sorted by upload date (sp=CAI%3D).
    static func searchURL(for query: String, latest: Bool) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents(string: "https://www.youtube.com/results")!
        components.queryItems = [URLQueryItem(name: "search_query", value: trimmed)]
        if latest { components.queryItems?.append(URLQueryItem(name: "sp", value: "CAI=")) }
        return components.url
    }

    private static let fillerWords: Set<String> = ["on", "youtube", "video", "videos", "the", "a", "s", "channel", "clip", "from", "by"]

    /// "play Matt Armstrong's latest video on YouTube in Arc browser".
    func directArguments(for command: DirectCommand) -> PlayYouTubeArguments? {
        guard ["play", "watch", "open", "search", "look up"].contains(command.verb) || command.text.hasPrefix("search youtube") else { return nil }
        var words = command.rest.split(separator: " ").map(String.init)
        guard words.contains("youtube") else { return nil }

        var browser: String?
        if let index = words.lastIndex(of: "in"), index + 1 < words.count {
            var name = Array(words[(index + 1)...])
            if name.last == "browser", name.count > 1 { name.removeLast() }
            let spoken = name.joined(separator: " ")
            if spoken == "browser" || AppNameMatcher.isGenericBrowser(spoken) || InstalledApps.resolve(spoken) != nil {
                browser = spoken == "browser" ? nil : spoken
                words.removeSubrange(index...)
            } else if let youtube = words.firstIndex(of: "youtube"), index > youtube {
                return nil // "in <something that isn't a browser>": not ours to guess.
            }
        }
        var latest = false
        if let index = words.firstIndex(where: { ["latest", "newest", "recent", "new"].contains($0) }) {
            latest = true
            words.remove(at: index)
            if index > 0, words[index - 1] == "most" { words.remove(at: index - 1) }
        }
        let query = words.filter { !Self.fillerWords.contains($0) }.joined(separator: " ")
        guard !query.isEmpty else { return nil }
        return PlayYouTubeArguments(query: query, latest: latest, browser: browser)
    }
}
