import AppKit
import FoundationModels

@Generable
struct ClipboardArguments: Sendable {
    @Guide(description: "What to do", .anyOf(["read", "clear", "plainText", "pastePlainText"]))
    var action: String
}

/// The clipboard: say what's on it, clear it, or strip its formatting (and
/// paste that). Never reads out anything a password manager marked private.
struct ClipboardTool: AssistantTool {
    let name = "clipboard"
    let title = "Clipboard"
    let symbol = "doc.on.clipboard"
    let keywords: Set<String> = ["clipboard", "copied", "copy", "paste", "formatting", "plain"]
    let description = """
        The clipboard. "what's on my clipboard" → read. "clear the clipboard" → clear. \
        "paste as plain text" → pastePlainText.
        """
    let requiresNetwork = false
    let permission = ToolPermission.varies
    let reversibility = Reversibility.notApplicable

    func target(of arguments: ClipboardArguments) -> String {
        switch arguments.action {
        case "clear": "Clear"
        case "plainText", "pastePlainText": "Plain text"
        default: "Read"
        }
    }

    /// Types password managers set on secrets (nspasteboard.org).
    static let privateTypes: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.agilebits.onepassword"]

    func execute(_ arguments: ClipboardArguments) async throws -> ToolResult {
        if arguments.action == "pastePlainText" { try SystemKeys.ensureTrusted() }
        return try await MainActor.run {
            let board = NSPasteboard.general
            let types = Set((board.types ?? []).map(\.rawValue))
            let isPrivate = !types.isDisjoint(with: Self.privateTypes)
            switch arguments.action {
            case "clear":
                board.clearContents()
                return ToolResult("Clipboard cleared")
            case "plainText", "pastePlainText":
                guard let text = board.string(forType: .string) else { throw ToolError("There's no text on the clipboard") }
                board.clearContents()
                board.setString(text, forType: .string)
                if isPrivate { board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) }
                if arguments.action == "pastePlainText" {
                    SystemKeys.pasteShortcut()
                    return ToolResult("Pasted as plain text")
                }
                return ToolResult("The clipboard is now plain text")
            default:
                if isPrivate { return ToolResult("That's marked private by a password manager, so I won't read it out", isAnswer: true) }
                return ToolResult(Self.describe(board), isAnswer: true)
            }
        }
    }

    @MainActor
    static func describe(_ board: NSPasteboard) -> String {
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let names = urls.prefix(3).map(\.lastPathComponent).joined(separator: ", ")
            return urls.count == 1 ? "A file: \(names)" : "\(urls.count) files: \(names)\(urls.count > 3 ? "…" : "")"
        }
        if let text = board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let short = text.count > 200 ? String(text.prefix(200)) + "…" : text
            return "Your clipboard says: \(short)"
        }
        if board.canReadObject(forClasses: [NSImage.self], options: nil) { return "An image" }
        return "The clipboard is empty"
    }

    func directArguments(for command: DirectCommand) -> ClipboardArguments? {
        let text = command.text
        if ["paste as plain text", "paste without formatting", "paste plain text", "paste it as plain text", "paste and match style"].contains(text) {
            return ClipboardArguments(action: "pastePlainText")
        }
        if text.contains("clipboard") {
            if ["clear", "empty", "wipe", "delete"].contains(where: text.contains) { return ClipboardArguments(action: "clear") }
            if ["plain text", "formatting"].contains(where: text.contains) { return ClipboardArguments(action: "plainText") }
            if ["what", "read", "show", "tell"].contains(where: text.hasPrefix) { return ClipboardArguments(action: "read") }
            return nil
        }
        if ["what did i copy", "what have i copied", "what did i just copy", "what s copied"].contains(text) {
            return ClipboardArguments(action: "read")
        }
        return nil
    }
}
