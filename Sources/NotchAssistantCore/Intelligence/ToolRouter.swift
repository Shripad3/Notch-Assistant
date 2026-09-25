/// Chooses which tools the model sees for one command (spec §8: "Keep the
/// tool set small"). With every tool's schema in the prompt, ten tools took
/// 5,070 tokens against a 4,096-token context and every model call failed.
/// Showing only the few tools whose keywords were said keeps the prompt
/// small however many tools exist, and fewer choices also means better
/// choices for a 3B model. Direct matching still sees every tool.
public enum ToolRouter {
    public static let maximum = 4
    /// When nothing matches: the general-purpose tools.
    static let fallback = ["openApp", "openURL", "webSearch"]

    public static func relevant(for transcript: String, among tools: [AnyAssistantTool]) -> [AnyAssistantTool] {
        let words = Set(AppNameMatcher.normalize(transcript).split(separator: " ").map(String.init))
        let scored = tools.enumerated()
            .map { index, tool in (tool, tool.keywords.intersection(words).count, index) }
            .filter { $0.1 > 0 }
            .sorted { ($0.1, -$0.2) > ($1.1, -$1.2) }
            .prefix(maximum)
            .map(\.0)
        guard scored.isEmpty else { return Array(scored) }
        return tools.filter { fallback.contains($0.name) }
    }
}
