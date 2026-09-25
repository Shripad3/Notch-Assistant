import AppKit
import FoundationModels

@Generable
struct WebSearchArguments: Sendable {
    @Guide(description: "What to search for, in the user's words")
    var query: String
}

/// Builds a search URL and opens it. Deliberately not an API call: no key,
/// no cost, no rate limit (spec §9).
///
/// The engine comes from Settings, not from the model: given an optional
/// engine argument, the 3B model filled it in unasked ("Google", "Apple
/// Weather"), overriding the user's choice.
struct WebSearchTool: AssistantTool {
    let name = "webSearch"
    let title = "Search the web"
    let symbol = "magnifyingglass"
    let description = """
        Search the web for information or a question. "search for banana bread recipes" → query "banana bread recipes". \
        Not for opening a website by name.
        """
    let requiresNetwork = true
    let permission = ToolPermission.none
    let reversibility = Reversibility.notApplicable

    func target(of arguments: WebSearchArguments) -> String {
        arguments.query
    }

    func execute(_ arguments: WebSearchArguments) async throws -> ToolResult {
        let engine = SearchEngine.preferred
        guard let url = engine.url(for: arguments.query) else {
            throw ToolError("There's nothing to search for")
        }
        try Task.checkCancellation()
        Log.tools.notice("webSearch → \(url.absoluteString, privacy: .public)")
        _ = try await NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
        return "Searched \(engine.title) for “\(arguments.query)”"
    }
}

extension WebSearchTool {
    func directArguments(for command: DirectCommand) -> WebSearchArguments? {
        guard ["search for", "search", "google", "look up"].contains(command.verb) else { return nil }
        return WebSearchArguments(query: command.rest)
    }
}

public enum SearchEngine: String, CaseIterable, Sendable {
    case google, duckDuckGo, bing

    public static let defaultsKey = "webSearch.engine"

    /// The user's default engine; Google until changed.
    public static var preferred: SearchEngine {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(SearchEngine.init(rawValue:)) ?? .google
    }

    public var title: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .bing: "Bing"
        }
    }

    func url(for query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components: URLComponents
        switch self {
        case .google: components = URLComponents(string: "https://www.google.com/search")!
        case .duckDuckGo: components = URLComponents(string: "https://duckduckgo.com/")!
        case .bing: components = URLComponents(string: "https://www.bing.com/search")!
        }
        components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components.url
    }
}
