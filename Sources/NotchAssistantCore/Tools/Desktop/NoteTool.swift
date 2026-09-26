import Foundation
import FoundationModels

@Generable
struct NoteArguments: Sendable {
    @Guide(description: "The note's text, in the user's words, e.g. \"the Wi-Fi password is on the router\"")
    var text: String
}

/// Quick notes into the Notes app: "note that the Wi-Fi password is on the
/// router". Creates a new note; never edits or deletes existing ones.
struct NoteTool: AssistantTool {
    let name = "takeNote"
    let title = "Note"
    let symbol = "note.text"
    let keywords: Set<String> = ["note", "notes", "jot", "write"]
    let description = """
        Save a new note in the Notes app. "note that the Wi-Fi password is on the router" → text "the Wi-Fi password is on the router".
        """
    let requiresNetwork = false
    let permission = ToolPermission.automation
    let reversibility = Reversibility.notApplicable

    func target(of arguments: NoteArguments) -> String {
        arguments.text
    }

    func execute(_ arguments: NoteArguments) async throws -> ToolResult {
        let text = arguments.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let transcript = CommandContext.transcript, text.isEmpty || !Set(SpokenWords(text).lower).isSubset(of: SpokenWords(transcript).lower) {
            throw ToolError("What should the note say?")
        }
        let body = "<div>\(Self.html(text.prefix(1).uppercased() + text.dropFirst()))</div>"
        try await AppleScript.run("""
            tell application "Notes"
                tell default account
                    make new note at default folder with properties {body:\(AppleScript.quoted(body))}
                end tell
            end tell
            """, controlling: "Notes")
        return ToolResult("Noted: \(text)")
    }

    static func html(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static let opening = try! NSRegularExpression(
        pattern: #"^\s*(?:please\s+)?(?:(?:take|make|add|create|write|start)\s+(?:a\s+)?(?:new\s+|quick\s+)?note|note\s+down|note|jot\s+down|write\s+down|note\s+to\s+self)(?:\s+(?:that|saying|to\s+self))?\s*[:,.-]?\s*"#,
        options: [.caseInsensitive]
    )

    /// "note that …", "take a note: …", "jot down …", "write down …".
    func directArguments(for command: DirectCommand) -> NoteArguments? {
        let original = command.original
        let range = NSRange(original.startIndex..., in: original)
        guard let match = Self.opening.firstMatch(in: original, range: range), match.range.length > 0,
              let end = Range(match.range, in: original)?.upperBound else { return nil }
        // "note" alone must be followed by "that" etc., or "notes" questions would match.
        let lead = original[..<end].lowercased()
        if lead.trimmingCharacters(in: .whitespaces).hasPrefix("note"), !lead.contains("that"), !lead.contains("down"),
           !lead.contains("self"), !lead.contains(":") { return nil }
        let text = original[end...].trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        guard !text.isEmpty else { return nil }
        return NoteArguments(text: text)
    }
}
