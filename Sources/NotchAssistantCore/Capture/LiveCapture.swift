import AppKit
import ApplicationServices
import Foundation

/// What the notch and menu bar show while Alfred is recording or taking
/// dictation.
public struct CaptureStatus: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case transcript, dictation(toNotes: Bool) }
    public let kind: Kind
    public let started: Date
    /// The latest words, as they're recognised.
    public var lastLine: String
}

/// Settings for recording.
public enum CaptureSettings {
    public static let saveAudioKey = "capture.saveAudio"
    public static let includeOthersKey = "capture.includeOthers"
    public static var saveAudio: Bool { UserDefaults.standard.bool(forKey: saveAudioKey) }
    public static var includeOthers: Bool { UserDefaults.standard.bool(forKey: includeOthersKey) }

    public static var folder: URL {
        URL.documentsDirectory.appending(path: "Alfred Transcripts")
    }
}

/// Transcribing a meeting or call to a file, or dictating into the focused
/// text field or a new note. One at a time. Only ever started by the user;
/// stopped by "Alfred, stop", "stop dictation", a click on the notch,
/// Escape, or after three hours.
public actor LiveCapture {
    public static let shared = LiveCapture()
    static let maximum: Duration = .seconds(3 * 3600)

    public private(set) var status: CaptureStatus?
    private var transcribers: [LiveTranscriber] = []
    private var file: FileHandle?
    private var fileURL: URL?
    private var formatter = DictationFormatter()
    private var dictated = ""
    private var noteID: String?
    private var noteTitle = ""
    private var limit: Task<Void, Never>?
    private var onChange: (@Sendable (CaptureStatus?) -> Void)?
    private var queue: [@Sendable () async -> Void] = []
    private var draining = false

    public func setObserver(_ observer: @escaping @Sendable (CaptureStatus?) -> Void) {
        onChange = observer
    }

    /// The latest transcript, for "summarise the meeting".
    public nonisolated static var lastTranscript: URL? {
        UserDefaults.standard.string(forKey: "capture.lastTranscript").map { URL(filePath: $0) }
    }

    // MARK: Transcripts

    /// Starts recording to a new transcript file; returns its name.
    public func startTranscript() async throws -> String {
        guard status == nil else { throw ToolError("Alfred is already \(status?.kind == .transcript ? "recording" : "taking dictation")") }
        let now = Date()
        let stamp = Self.fileStamp(now)
        try FileManager.default.createDirectory(at: CaptureSettings.folder, withIntermediateDirectories: true)
        let url = CaptureSettings.folder.appending(path: "\(stamp) Transcript.txt")
        let header = "Transcript — \(now.formatted(date: .complete, time: .shortened))\n\n"
        try Data(header.utf8).write(to: url)
        file = try FileHandle(forWritingTo: url)
        try file?.seekToEnd()
        fileURL = url
        UserDefaults.standard.set(url.path, forKey: "capture.lastTranscript")

        let others = CaptureSettings.includeOthers
        let audio = CaptureSettings.saveAudio ? CaptureSettings.folder.appending(path: "\(stamp) Audio.m4a") : nil
        let mine = transcriber(speaker: others ? "Me" : nil, started: now, punctuate: true)
        try await mine.start(.microphone(saveAudioTo: audio))
        transcribers = [mine]
        if others {
            let theirs = transcriber(speaker: "Others", started: now, punctuate: true)
            do {
                try await theirs.start(.systemAudio)
                transcribers.append(theirs)
            } catch {
                await mine.stop()
                transcribers = []
                throw error
            }
        }
        begin(.transcript, at: now)
        return url.lastPathComponent
    }

    private func transcriber(speaker: String?, started: Date, punctuate: Bool) -> LiveTranscriber {
        LiveTranscriber(punctuate: punctuate, onSegment: { [weak self] text, _ in
            Task { await self?.transcriptLine(text, speaker: speaker, started: started) }
        }, onDraft: { [weak self] text in
            Task { await self?.draft(text) }
        })
    }

    private func transcriptLine(_ text: String, speaker: String?, started: Date) async {
        guard status?.kind == .transcript else { return }
        let (kept, stop) = DictationFormatter.transcriptStop(in: text)
        if !kept.isEmpty {
            let elapsed = Int(Date().timeIntervalSince(started))
            let time = String(format: "[%02d:%02d:%02d]", elapsed / 3600, (elapsed % 3600) / 60, elapsed % 60)
            let line = "\(time) \(speaker.map { "\($0): " } ?? "")\(kept)\n"
            try? file?.write(contentsOf: Data(line.utf8))
            draft(kept)
        }
        if stop { _ = await self.stop() }
    }

    // MARK: Dictation

    public func startDictation(toNotes: Bool) async throws {
        guard status == nil else { throw ToolError("Alfred is already \(status?.kind == .transcript ? "recording" : "taking dictation")") }
        if !toNotes, !AXIsProcessTrusted() {
            throw AssistantFailure("Notch Assistant needs Accessibility to type for you", link: .accessibility)
        }
        formatter = DictationFormatter()
        dictated = ""
        noteID = nil
        if toNotes {
            noteTitle = "Dictation " + Date().formatted(date: .abbreviated, time: .shortened)
            noteID = try await Self.createNote(titled: noteTitle)
        }
        let now = Date()
        let transcriber = LiveTranscriber(punctuate: false, onSegment: { [weak self] text, _ in
            Task { await self?.dictate(text) }
        }, onDraft: { [weak self] text in
            Task { await self?.draft(text) }
        })
        try await transcriber.start(.microphone(saveAudioTo: nil))
        transcribers = [transcriber]
        begin(.dictation(toNotes: toNotes), at: now)
    }

    private func dictate(_ segment: String) async {
        guard case .dictation(let toNotes) = status?.kind else { return }
        for edit in formatter.process(segment) {
            switch edit {
            case .insert(let text):
                dictated += text
                if !toNotes { await enqueue { await FocusedText.insert(text) } }
            case .delete(let count):
                dictated.removeLast(min(count, dictated.count))
                if !toNotes { await enqueue { await FocusedText.deleteBackward(count) } }
            case .stop:
                _ = await stop()
                return
            }
        }
        if toNotes, let noteID {
            let body = NoteTool.body(title: noteTitle, text: dictated)
            await enqueue { try? await Self.setNote(noteID, body: body) }
        }
        draft(segment)
    }

    /// Typing and note updates happen in order, one at a time.
    private func enqueue(_ work: @escaping @Sendable () async -> Void) async {
        queue.append(work)
        guard !draining else { return }
        draining = true
        while !queue.isEmpty {
            let next = queue.removeFirst()
            await next()
        }
        draining = false
    }

    // MARK: Stopping

    /// Stops whatever is running; returns what to tell the user.
    @discardableResult
    public func stop() async -> String {
        guard let current = status else { return "Alfred isn't recording" }
        status = nil
        limit?.cancel()
        let running = transcribers
        transcribers = []
        for transcriber in running { await transcriber.stop() }
        onChange?(nil)
        let minutes = max(1, Int(Date().timeIntervalSince(current.started) / 60 + 0.5))
        switch current.kind {
        case .transcript:
            try? file?.close()
            file = nil
            let name = fileURL?.lastPathComponent ?? "the transcript"
            Log.tools.notice("capture: transcript saved")
            return "Stopped after \(minutes) min. Saved \(name) in Documents › Alfred Transcripts. Say “summarise the meeting” for the key points"
        case .dictation(let toNotes):
            return toNotes ? "Dictation saved in Notes" : "Dictation stopped"
        }
    }

    private func begin(_ kind: CaptureStatus.Kind, at date: Date) {
        status = CaptureStatus(kind: kind, started: date, lastLine: "")
        onChange?(status)
        limit = Task { [weak self] in
            try? await Task.sleep(for: Self.maximum)
            guard !Task.isCancelled else { return }
            await self?.stop()
        }
    }

    private func draft(_ text: String) {
        guard status != nil else { return }
        status?.lastLine = String(text.suffix(80))
        onChange?(status)
    }

    static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return formatter.string(from: date)
    }

    // MARK: Notes

    private static func createNote(titled title: String) async throws -> String {
        let ids = try await AppleScript.evaluate("""
            tell application "Notes"
                tell default account
                    set newNote to make new note at default folder with properties {body:\(AppleScript.quoted("<div><b>\(NoteTool.html(title))</b></div>"))}
                end tell
                show newNote
                activate
                return id of newNote
            end tell
            """, controlling: "Notes")
        guard let id = ids.first else { throw ToolError("Notes didn't create the note") }
        return id
    }

    private static func setNote(_ id: String, body: String) async throws {
        try await AppleScript.run("""
            tell application "Notes"
                set theNote to note id \(AppleScript.quoted(id))
                set body of theNote to \(AppleScript.quoted(body))
            end tell
            """, controlling: "Notes")
    }
}

/// Typing into whatever text field is focused in the front app.
@MainActor
enum FocusedText {
    /// Inserts at the cursor through Accessibility; if the app doesn't
    /// allow that, pastes (putting the clipboard back afterwards).
    static func insert(_ text: String) async {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let focused,
           AXUIElementSetAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, text as CFString) == .success {
            return
        }
        let board = NSPasteboard.general
        let saved = board.string(forType: .string)
        board.clearContents()
        board.setString(text, forType: .string)
        SystemKeys.pasteShortcut()
        try? await Task.sleep(for: .milliseconds(250))
        board.clearContents()
        if let saved { board.setString(saved, forType: .string) }
    }

    static func deleteBackward(_ count: Int) async {
        let source = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<count {
            for down in [true, false] {
                CGEvent(keyboardEventSource: source, virtualKey: 0x33, keyDown: down)?.post(tap: .cghidEventTap)
            }
        }
    }
}
