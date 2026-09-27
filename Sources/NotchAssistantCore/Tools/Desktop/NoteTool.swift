import AppKit
import FoundationModels

@Generable
struct NoteArguments: Sendable {
    @Guide(description: "The note's text, in the user's words, e.g. \"the Wi-Fi password is on the router\"")
    var text: String
}

/// Quick notes into the Notes app: "note that the Wi-Fi password is on the
/// router". Creates a new note and shows it; never edits or deletes
/// existing ones.
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
        let started = ContinuousClock.now
        // Launch Notes straight away, in front: a cold start (with iCloud
        // syncing) is most of the wait, and scripting a closed app has no
        // time limit on the launch.
        await Self.openNotes()
        let launched = ContinuousClock.now
        let body = "<div>\(Self.html(text.prefix(1).uppercased() + text.dropFirst()))</div>"
        try await AppleScript.run("""
            tell application "Notes"
                tell default account
                    set newNote to make new note at default folder with properties {body:\(AppleScript.quoted(body))}
                end tell
                show newNote
                activate
            end tell
            """, controlling: "Notes")
        Log.tools.notice("note: Notes ready in \(launched - started, privacy: .public), note made in \(ContinuousClock.now - launched, privacy: .public)")
        return ToolResult("Noted: \(text)")
    }

    /// Opens Notes and returns once it has finished launching (at most 15 s).
    private static func openNotes() async {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Notes") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        guard let app = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration) else { return }
        let deadline = ContinuousClock.now + .seconds(15)
        while !app.isFinishedLaunching, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    static func html(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static let opening = try! NSRegularExpression(
        pattern: #"^\s*(?:please\s+)?(?:open\s+(?:the\s+|my\s+)?notes(?:\s+app)?\s+and\s+(?:type|write|add|put|note|jot)(?:\s+down)?(?:\s+that)?|(?:take|make|add|create|write|start)\s+(?:a\s+)?(?:new\s+|quick\s+)?note|note\s+down|note|jot\s+down|write\s+down|note\s+to\s+self)(?:\s+(?:that|saying|to\s+self))?\s*[:,.-]?\s*"#,
        options: [.caseInsensitive]
    )

    /// "add eggs to my notes", "type hello world in Notes".
    private static let trailing = try! NSRegularExpression(
        pattern: #"^\s*(?:please\s+)?(?:add|put|type|write)\s+(.+?)\s+(?:to|in|into)\s+(?:my\s+|the\s+)?notes(?:\s+app)?\s*[.!]?\s*$"#,
        options: [.caseInsensitive]
    )

    /// "note that …", "take a note: …", "jot down …", "write down …".
    func directArguments(for command: DirectCommand) -> NoteArguments? {
        let original = command.original
        let range = NSRange(original.startIndex..., in: original)
        if let match = Self.trailing.firstMatch(in: original, range: range), let text = Range(match.range(at: 1), in: original) {
            return NoteArguments(text: String(original[text]))
        }
        guard let match = Self.opening.firstMatch(in: original, range: range), match.range.length > 0,
              let end = Range(match.range, in: original)?.upperBound else { return nil }
        // "note" alone must be followed by "that" etc., or "notes" questions would match.
        let lead = original[..<end].lowercased()
        if lead.trimmingCharacters(in: .whitespaces).hasPrefix("note"), !lead.hasPrefix("notes"), !lead.contains("that"), !lead.contains("down"),
           !lead.contains("self"), !lead.contains(":") { return nil }
        let text = original[end...].trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        guard !text.isEmpty else { return nil }
        return NoteArguments(text: text)
    }
}
