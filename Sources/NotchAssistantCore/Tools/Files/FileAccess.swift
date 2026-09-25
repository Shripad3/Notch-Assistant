import CoreServices
import Foundation

/// Where file tools may look, and the checks every resolved path must pass
/// before it is acted on. Enforced here in the executor, after
/// canonicalisation, never by prompt (spec §9 "Validation belongs in the
/// executor"). Failing any check refuses the operation; there is no override.
enum FileAccess {
    static let rootsKey = "files.scopedRoots"

    /// Documents, Downloads and Desktop unless the user configured others.
    static var scopedRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configured = UserDefaults.standard.stringArray(forKey: rootsKey) ?? ["Documents", "Downloads", "Desktop"]
        return configured.map { home.appending(path: $0, directoryHint: .isDirectory).resolvingSymlinksInPath() }
    }

    /// Touches each root, which makes macOS ask for Files and Folders access
    /// the first time, and throws a legible error when it has been refused.
    /// Spotlight silently omits results from folders the app can't read, so
    /// without this check a refusal would look like "no files found".
    static func ensureAccess() throws {
        for root in scopedRoots {
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))
            } catch let error as CocoaError where error.code == .fileReadNoPermission {
                throw AssistantFailure("Notch Assistant can't see your \(root.lastPathComponent) folder", link: .filesAndFolders)
            } catch {
                continue // A missing root is fine.
            }
        }
    }

    /// The canonical URL if `url` may be acted on, otherwise nil.
    static func validated(_ url: URL, roots: [URL] = scopedRoots) -> URL? {
        // resolvingSymlinksInPath also canonicalises "..", so a symlink or
        // path trick pointing outside a root fails the prefix test below.
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let components = resolved.pathComponents
        guard roots.contains(where: { root in components.starts(with: root.pathComponents) && components.count > root.pathComponents.count }) else {
            return nil
        }
        let denied = components.contains { component in
            component.hasPrefix(".") || component.hasSuffix(".app") || component == "Library"
        }
        return denied ? nil : resolved
    }
}

/// Spotlight, metadata only. Content-scope search (kMDItemTextContent) is
/// never used: it would return matches from inside documents.
///
/// Uses MDQuery synchronously on a background thread. NSMetadataQuery needs a
/// run loop, so it ran on the main thread, where a Desktop screenshot search
/// stalled inside a nested event loop: Escape stopped working (its handler
/// waits for the main thread) and hovering the notch crashed.
enum SpotlightSearch {
    private static let queue = DispatchQueue(label: "dev.shripad.NotchAssistant.spotlight", qos: .userInitiated)

    static func run(_ query: FileQuery, limit: Int = 25, roots: [URL] = FileAccess.scopedRoots) async throws -> [FoundFile] {
        guard query.isSpecific else {
            throw ToolError("Which file? Say part of its name, its type, where it is or when it's from")
        }
        let roots = query.folder.map { folder in roots.filter { $0.lastPathComponent == folder } } ?? roots
        let queryString = Self.queryString(for: query)

        let answer = OneShot<[Item]?>()
        let items = await withCheckedContinuation { continuation in
            answer.set(continuation)
            queue.async { answer.resume(execute(queryString, scopes: roots)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { answer.resume(nil) }
        }
        guard let items else { throw ToolError("The file search took too long") }

        let files = items.compactMap { item -> FoundFile? in
            guard let url = FileAccess.validated(URL(fileURLWithPath: item.path), roots: roots) else { return nil }
            let date = [item.changed, item.added].compactMap { $0 }.max() ?? .distantPast
            return FoundFile(url: url, name: item.name ?? url.lastPathComponent, date: date)
        }
        return Array(FileRanking.rank(files, for: query).prefix(limit))
    }

    /// Spotlight's query syntax. Words are normalised to letters and digits
    /// before they get here, so nothing needs escaping.
    static func queryString(for query: FileQuery) -> String {
        var clauses = query.words.map { "kMDItemFSName == \"*\($0)*\"cd" }
        switch query.kind {
        case .screenshot: clauses.append("kMDItemIsScreenCapture == 1")
        case let kind?: clauses.append("kMDItemContentTypeTree == \"\(kind.contentType)\"")
        case nil: clauses.append("kMDItemContentTypeTree != \"public.folder\"")
        }
        if let period = query.period {
            let range = period.range()
            let formatter = ISO8601DateFormatter()
            let start = formatter.string(from: range.lowerBound), end = formatter.string(from: range.upperBound)
            clauses.append("((kMDItemFSContentChangeDate >= $time.iso(\(start)) && kMDItemFSContentChangeDate < $time.iso(\(end))) || (kMDItemDateAdded >= $time.iso(\(start)) && kMDItemDateAdded < $time.iso(\(end))))")
        }
        return clauses.joined(separator: " && ")
    }

    private struct Item: Sendable {
        let path: String
        let name: String?
        let changed: Date?
        let added: Date?
    }

    /// Blocking; call off the main thread.
    private static func execute(_ queryString: String, scopes: [URL]) -> [Item]? {
        guard let query = MDQueryCreate(kCFAllocatorDefault, queryString as CFString, nil, nil) else {
            Log.tools.error("spotlight: invalid query \(queryString, privacy: .public)")
            return nil
        }
        MDQuerySetSearchScope(query, scopes.map { $0.path(percentEncoded: false) } as CFArray, 0)
        MDQuerySetMaxCount(query, 200)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return nil }
        return (0..<MDQueryGetResultCount(query)).compactMap { index in
            guard let raw = MDQueryGetResultAtIndex(query, index) else { return nil }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { return nil }
            return Item(
                path: path,
                name: MDItemCopyAttribute(item, kMDItemFSName) as? String,
                changed: MDItemCopyAttribute(item, kMDItemFSContentChangeDate) as? Date,
                added: MDItemCopyAttribute(item, kMDItemDateAdded) as? Date
            )
        }
    }
}
