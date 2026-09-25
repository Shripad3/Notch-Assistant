import Foundation

/// The set of tools the model may see. Read at session construction, every
/// time: a disabled capability is never registered, so the model cannot call
/// it (spec §10 gating principle).
public struct ToolRegistry: Sendable {
    public let tools: [AnyAssistantTool]
    private let isEnabled: @Sendable (String) -> Bool

    public init(tools: [AnyAssistantTool], isEnabled: @escaping @Sendable (String) -> Bool = ToolRegistry.userDefaultsGate) {
        self.tools = tools
        self.isEnabled = isEnabled
    }

    public static let standard = ToolRegistry(tools: [
        AnyAssistantTool(OpenAppTool()),
        AnyAssistantTool(OpenURLTool()),
        // Before Spotify and files: "play … on YouTube" and "… video" are its.
        AnyAssistantTool(PlayYouTubeTool()),
        AnyAssistantTool(WebSearchTool()),
        AnyAssistantTool(ControlSpotifyTool()),
        AnyAssistantTool(SystemControlTool()),
        // After openApp and openURL: "open spotify" must stay an app.
        AnyAssistantTool(OpenFileTool()),
        AnyAssistantTool(FindFilesTool()),
    ])

    public func enabledTools() -> [AnyAssistantTool] {
        tools.filter { $0.reversibility != .refused && isEnabled($0.name) }
    }

    /// Tools default to enabled. The v1 Capabilities pane writes these keys.
    public static func userDefaultsGate(_ name: String) -> Bool {
        UserDefaults.standard.object(forKey: enabledKey(for: name)) as? Bool ?? true
    }

    /// The key the Capabilities pane binds each tool's toggle to.
    public static func enabledKey(for name: String) -> String {
        "tool.\(name).enabled"
    }
}
