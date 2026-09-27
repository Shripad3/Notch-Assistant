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
        // First: their phrasings are specific, and "stop the timer" or
        // "start a stopwatch" must not reach Spotify or app launching.
        AnyAssistantTool(TimerTool()),
        AnyAssistantTool(AlarmTool()),
        AnyAssistantTool(StopwatchTool()),
        AnyAssistantTool(ReminderTool()),
        AnyAssistantTool(TasksTool()),
        AnyAssistantTool(CallTool()),
        AnyAssistantTool(MessageTool()),
        AnyAssistantTool(EmailTool()),
        AnyAssistantTool(CurrentTimeTool()),
        AnyAssistantTool(CalendarTool()),
        AnyAssistantTool(OpenAppTool()),
        AnyAssistantTool(OpenURLTool()),
        // Before Spotify and files: "play … on YouTube" and "… video" are its.
        AnyAssistantTool(PlayYouTubeTool()),
        // Before webSearch: "how's the weather" is answered, not searched.
        AnyAssistantTool(WeatherTool()),
        AnyAssistantTool(WebSearchTool()),
        AnyAssistantTool(ControlSpotifyTool()),
        AnyAssistantTool(SystemControlTool()),
        AnyAssistantTool(RunShortcutTool()),
        AnyAssistantTool(WindowTool()),
        AnyAssistantTool(ClipboardTool()),
        AnyAssistantTool(NoteTool()),
        // After windows, clipboard and notes, which have their own "add",
        // "move" and "put"; before files, whose "move" needs a folder.
        AnyAssistantTool(CalendarEventTool()),
        // After openApp and openURL: "open spotify" must stay an app.
        AnyAssistantTool(OpenFileTool()),
        AnyAssistantTool(FindFilesTool()),
        AnyAssistantTool(OrganiseFilesTool()),
        AnyAssistantTool(UndoFileChangeTool()),
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
