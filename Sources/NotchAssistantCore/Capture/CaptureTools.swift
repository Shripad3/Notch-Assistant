import Foundation
import FoundationModels

@Generable
struct MeetingNotes: Sendable {
    @Guide(description: "The key points, each one short sentence", .count(0...6))
    var points: [String]
    @Guide(description: "Things someone agreed or needs to do, each one short sentence", .count(0...6))
    var actions: [String]
}

/// Summarises a transcript with the on-device model. Its context is small,
/// so a long meeting is summarised in parts, then the parts are merged.
enum TranscriptSummarizer {
    static let chunkCharacters = 5_000

    static func summarize(_ transcript: String) async throws -> MeetingNotes {
        let lines = transcript.components(separatedBy: "\n").filter { $0.hasPrefix("[") }
        guard !lines.isEmpty else { throw ToolError("That transcript is empty") }
        var chunks: [String] = [""]
        for line in lines {
            if chunks[chunks.count - 1].count + line.count > chunkCharacters { chunks.append("") }
            chunks[chunks.count - 1] += line + "\n"
        }
        var points: [String] = []
        var actions: [String] = []
        for chunk in chunks {
            let notes = try await ask("Summarise this part of a meeting transcript.", chunk)
            points += notes.points
            actions += notes.actions
        }
        guard chunks.count > 1 else { return MeetingNotes(points: points, actions: actions) }
        let merged = "Key points:\n" + points.map { "- " + $0 }.joined(separator: "\n") + "\nActions:\n" + actions.map { "- " + $0 }.joined(separator: "\n")
        return try await ask("Merge these notes from one meeting, removing repeats.", String(merged.prefix(chunkCharacters)))
    }

    private static func ask(_ task: String, _ text: String) async throws -> MeetingNotes {
        let session = LanguageModelSession(instructions: """
            You write short meeting notes from a transcript. Use only what the transcript says; never invent names, \
            numbers or decisions. Write plain sentences without markdown.
            """)
        return try await session.respond(to: "\(task)\n\n\(text)", generating: MeetingNotes.self).content
    }
}

@Generable
struct TranscribeArguments: Sendable {
    @Guide(description: "What to do", .anyOf(["start", "stop", "summarize"]))
    var action: String
}

/// "Start transcribing", "record this meeting", "stop recording",
/// "summarise the meeting". Transcripts go to Documents › Alfred
/// Transcripts; a summary goes to Notes.
struct TranscribeTool: AssistantTool {
    let name = "transcribe"
    let title = "Transcribe"
    let symbol = "waveform.badge.mic"
    let keywords: Set<String> = ["transcribe", "transcribing", "transcript", "record", "recording", "meeting", "summarise", "summarize", "minutes"]
    let description = """
        Record and transcribe a meeting or call. "start transcribing" → start. "stop recording" → stop. \
        "summarise the meeting" → summarize.
        """
    let requiresNetwork = false
    let permission = ToolPermission.varies
    let reversibility = Reversibility.notApplicable

    func target(of arguments: TranscribeArguments) -> String { arguments.action }

    func execute(_ arguments: TranscribeArguments) async throws -> ToolResult {
        switch arguments.action {
        case "start":
            let name = try await LiveCapture.shared.startTranscript()
            let others = CaptureSettings.includeOthers ? ", including the other side of calls" : ""
            return ToolResult("Recording\(others). Click the notch or say “Alfred, stop” to finish · \(name)")
        case "stop":
            return ToolResult(await LiveCapture.shared.stop())
        default:
            guard let url = LiveCapture.lastTranscript, let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw ToolError("There's no transcript yet. Say “start transcribing” first")
            }
            let notes = try await TranscriptSummarizer.summarize(text)
            let title = "Summary: " + url.deletingPathExtension().lastPathComponent
            var body = "Key points\n" + notes.points.map { "• " + $0 }.joined(separator: "\n")
            if !notes.actions.isEmpty { body += "\n\nTo do\n" + notes.actions.map { "• " + $0 }.joined(separator: "\n") }
            try await AppleScript.run("""
                tell application "Notes"
                    tell default account
                        set newNote to make new note at default folder with properties {body:\(AppleScript.quoted(NoteTool.body(title: title, text: body)))}
                    end tell
                    show newNote
                end tell
                """, controlling: "Notes")
            return ToolResult("Summary saved to Notes: \(notes.points.count) key points, \(notes.actions.count) to-dos")
        }
    }

    func directArguments(for command: DirectCommand) -> TranscribeArguments? {
        let text = command.text
        let starts = ["start transcribing", "start recording", "record this", "transcribe this", "record the meeting", "transcribe the meeting",
                      "start a transcript", "take minutes", "record my meeting", "transcribe my meeting", "record this call", "transcribe this call"]
        let stops = ["stop transcribing", "stop recording", "stop the recording", "end the recording", "stop the transcript", "finish recording"]
        if stops.contains(where: text.hasPrefix) { return TranscribeArguments(action: "stop") }
        if starts.contains(where: text.hasPrefix) { return TranscribeArguments(action: "start") }
        if ["summarise", "summarize", "sum up"].contains(where: text.hasPrefix),
           ["meeting", "transcript", "recording", "call", "that"].contains(where: text.contains) {
            return TranscribeArguments(action: "summarize")
        }
        return nil
    }
}

@Generable
struct DictationArguments: Sendable {
    @Guide(description: "Where the words go", .anyOf(["here", "notes", "stop"]))
    var target: String
    @Guide(description: "Words to type right away, only if the user said them after \"type\"")
    var text: String?
}

/// Dictation: into the focused text field ("dictate", "type what I say")
/// or a new note ("take dictation", "dictate a note").
struct DictationTool: AssistantTool {
    let name = "dictate"
    let title = "Dictation"
    let symbol = "text.bubble"
    let keywords: Set<String> = ["dictate", "dictation", "type", "typing"]
    let description = """
        Dictation. "dictate" or "type what I say" → here. "take dictation" or "dictate a note" → notes. "stop dictation" → stop.
        """
    let requiresNetwork = false
    let permission = ToolPermission.accessibility
    let reversibility = Reversibility.notApplicable

    func target(of arguments: DictationArguments) -> String { arguments.target == "notes" ? "Notes" : "Here" }

    static let hintKey = "dictation.hintShown"

    func execute(_ arguments: DictationArguments) async throws -> ToolResult {
        if arguments.target == "stop" { return ToolResult(await LiveCapture.shared.stop()) }
        // "Type hello there": just those words, now.
        if let text = arguments.text?.trimmingCharacters(in: .whitespaces), !text.isEmpty, Recipients.wasSaid(text) {
            try SystemKeys.ensureTrusted()
            await FocusedText.insert(text)
            return ToolResult("Typed")
        }
        let toNotes = arguments.target == "notes"
        try await LiveCapture.shared.startDictation(toNotes: toNotes)
        let place = toNotes ? " into a new note" : ""
        // The instructions once; after that, just "Dictating".
        guard !UserDefaults.standard.bool(forKey: Self.hintKey) else { return ToolResult("Dictating\(place)") }
        UserDefaults.standard.set(true, forKey: Self.hintKey)
        return ToolResult("Dictating\(place). Say “new line”, “full stop”, “scratch that”, or “stop dictation”")
    }

    func directArguments(for command: DirectCommand) -> DictationArguments? {
        let text = command.text
        if ["stop dictation", "stop dictating", "end dictation", "stop typing"].contains(text) { return DictationArguments(target: "stop", text: nil) }
        if ["take dictation", "dictate a note", "dictate into notes", "dictate into a note", "dictate in notes", "start dictating a note",
            "dictate to notes", "start a dictation note", "take notes", "start taking notes", "type in notes", "start typing in notes"].contains(text) {
            return DictationArguments(target: "notes", text: nil)
        }
        if ["dictate", "start dictation", "start dictating", "dictation", "type what i say", "type for me", "dictate here", "start typing what i say",
            "start typing", "type", "start writing", "type this", "dictate this", "keep typing"].contains(text) {
            return DictationArguments(target: "here", text: nil)
        }
        // "type hello Amay, this is a test", "type in …", "type out …".
        if let words = Recipients.rest(of: command.original, after: Recipients.opening + #"(?:start\s+)?typ(?:e|ing)(?:\s+(?:in|out|this))?[:,]?\s+"#),
           !words.isEmpty, !["what i say", "for me", "in notes"].contains(words.lowercased()) {
            return DictationArguments(target: "here", text: words)
        }
        return nil
    }
}
