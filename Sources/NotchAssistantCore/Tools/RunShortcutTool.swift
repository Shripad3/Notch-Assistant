import Foundation
import FoundationModels

@Generable
struct RunShortcutArguments: Sendable {
    @Guide(description: "The shortcut's name as the user said it, e.g. \"Lights On\"")
    var name: String
}

/// Runs one of the user's own shortcuts by name, silently, through Shortcuts
/// Events. This is how lights and other HomeKit scenes are reached: native
/// apps can't use HomeKit directly. The shortcut must be one the user named
/// (grounded); the model can't pick one on its own.
struct RunShortcutTool: AssistantTool {
    let name = "runShortcut"
    let title = "Shortcut"
    let symbol = "square.stack.3d.up"
    let keywords: Set<String> = ["shortcut", "shortcuts", "lights", "light", "lamp", "lamps", "scene"]
    let description = """
        Run one of the user's shortcuts from the Shortcuts app by name. "run my Lights On shortcut" → name "Lights On".
        """
    let requiresNetwork = false
    let permission = ToolPermission.automation
    let reversibility = Reversibility.notApplicable

    func target(of arguments: RunShortcutArguments) -> String {
        arguments.name
    }

    func execute(_ arguments: RunShortcutArguments) async throws -> ToolResult {
        if let transcript = CommandContext.transcript, !Grounding.mentions(arguments.name, in: transcript) {
            throw ToolError("Which shortcut? Say its name")
        }
        let ran = try await Shortcuts.run(named: arguments.name)
        return ToolResult("Ran “\(ran)”")
    }

    /// "run my lights on shortcut", "run shortcut lights on", "run the X shortcut".
    func directArguments(for command: DirectCommand) -> RunShortcutArguments? {
        var text = command.text
        guard text.hasPrefix("run ") else { return nil }
        text.removeFirst("run ".count)
        for prefix in ["the shortcut ", "shortcut ", "my ", "the "] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        if text.hasSuffix(" shortcut") { text.removeLast(" shortcut".count) }
        guard command.text.contains("shortcut"), !text.isEmpty else { return nil }
        return RunShortcutArguments(name: text)
    }
}
