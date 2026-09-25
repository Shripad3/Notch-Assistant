import AppKit
import Synchronization

/// Opaque tokens for found files (spec §9 "the model never handles a
/// path"). A list in the notch shows names and dates; its rows carry only a
/// token. Real paths stay in this table, which is cleared at the start of
/// every activation, so a token from an earlier command can't be reused.
enum FileTokens {
    private static let table = Mutex<[String: URL]>([:])

    /// Replaces the table with these files and returns their rows.
    static func register(_ files: [FoundFile]) -> [ResultItem] {
        let dates = RelativeDateTimeFormatter()
        var entries: [String: URL] = [:]
        let items = files.map { file in
            let token = "file_" + String(UUID().uuidString.prefix(8)).lowercased()
            entries[token] = file.url
            return ResultItem(
                id: token,
                title: file.name,
                detail: file.date == .distantPast ? "" : dates.localizedString(for: file.date, relativeTo: Date()),
                symbol: symbol(for: file.url)
            )
        }
        table.withLock { $0 = entries }
        return items
    }

    static func reset() {
        table.withLock { $0.removeAll() }
    }

    /// Resolves a token and opens the file, validating the path again at the
    /// moment of use.
    static func open(_ token: String) async throws -> String {
        guard let url = table.withLock({ $0[token] }) else {
            throw ToolError("That list has expired; ask again")
        }
        guard let valid = FileAccess.validated(url) else {
            throw ToolError("That file is outside the folders I may open")
        }
        Log.tools.notice("openFile (from list) → \(valid.lastPathComponent, privacy: .public)")
        _ = try await NSWorkspace.shared.open(valid, configuration: NSWorkspace.OpenConfiguration())
        return "Opened \(valid.lastPathComponent)"
    }

    private static func symbol(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic", "gif", "tiff": "photo"
        case "pdf": "doc.richtext"
        case "mov", "mp4", "m4v": "film"
        case "mp3", "m4a", "wav": "waveform"
        case "key", "pptx": "rectangle.on.rectangle"
        case "numbers", "xlsx", "csv": "tablecells"
        default: "doc"
        }
    }
}

/// Acting on a selected result row. Dispatches by token kind, so the
/// coordinator stays unaware of what the rows are.
public enum ResultActions {
    public static func select(_ id: String) async throws -> String {
        if id.hasPrefix("file_") { return try await FileTokens.open(id) }
        throw ToolError("That item can't be opened")
    }

    public static func reset() {
        FileTokens.reset()
    }
}
