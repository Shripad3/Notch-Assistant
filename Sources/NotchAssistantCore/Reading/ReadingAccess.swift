import Foundation
import Synchronization

/// Which files Alfred may read. Reading never leaves the Mac, but it's still
/// limited: folders the user allows (Documents, Downloads, Desktop by
/// default), never secrets or system files. Writing to a file's contents
/// remains impossible: nothing in the reading code opens a file for writing.
public enum ReadingAccess {
    public static let foldersKey = "reading.folders"
    public static let enabledKey = "reading.enabled"

    public static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// The allowed folders, as absolute paths.
    public static var folders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let stored = UserDefaults.standard.stringArray(forKey: foldersKey)
            ?? ["Documents", "Downloads", "Desktop"].map { home.appending(path: $0).path(percentEncoded: false) }
        return stored.map { URL(filePath: $0, directoryHint: .isDirectory).resolvingSymlinksInPath() }
    }

    public static func setFolders(_ urls: [URL]) {
        UserDefaults.standard.set(urls.map { $0.path(percentEncoded: false) }, forKey: foldersKey)
    }

    public enum Decision: Equatable {
        case allowed(URL)
        /// Never readable, whatever the settings: the reason, to say.
        case forbidden(String)
        /// Readable only if the user adds this folder.
        case outsideFolders(URL)
    }

    /// Secrets and system files, refused regardless of the allowed folders.
    public static func check(_ url: URL, folders: [URL] = folders) -> Decision {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let components = resolved.pathComponents
        let name = resolved.lastPathComponent.lowercased()
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().pathComponents

        if components.contains(where: { $0.hasSuffix(".app") }) { return .forbidden("I don't read inside apps") }
        if components.starts(with: ["/", "System"]) || components.starts(with: ["/", "Library"]) || components.starts(with: ["/", "Applications"])
            || components.starts(with: ["/", "private"]) || components.starts(with: ["/", "usr"]) || components.starts(with: ["/", "bin"]) {
            return .forbidden("I don't read system files")
        }
        if components.starts(with: home + ["Library"]) { return .forbidden("I don't read the Library folder, where apps keep their private data") }
        if components.contains(where: { [".ssh", ".gnupg", ".aws", ".kube", ".docker"].contains($0.lowercased()) }) || name.hasPrefix("id_rsa")
            || name.hasPrefix("id_ed25519") || name.hasPrefix("id_ecdsa") || name.hasPrefix("id_dsa") {
            return .forbidden("That's a security key. I never read keys")
        }
        let secretExtensions = ["pem", "key", "p12", "pfx", "keychain", "keychain-db", "kdbx", "gpg", "asc", "cer", "crt", "jks", "keystore"]
        if secretExtensions.contains(resolved.pathExtension.lowercased()) {
            return .forbidden("That file holds keys or passwords. I never read those")
        }
        if name == ".env" || name.hasPrefix(".env.") || name.hasSuffix(".env") || [".netrc", ".npmrc", ".pgpass", "credentials", "credentials.json", ".git-credentials"].contains(name) {
            return .forbidden("That file holds passwords or tokens. I never read those")
        }
        // Hidden files and folders hold settings and secrets, not documents.
        if components.dropFirst().contains(where: { $0.hasPrefix(".") }) { return .forbidden("I don't read hidden files") }

        guard folders.contains(where: { folder in components.starts(with: folder.pathComponents) && components.count > folder.pathComponents.count }) else {
            return .outsideFolders(resolved.deletingLastPathComponent())
        }
        return .allowed(resolved)
    }
}

/// What Alfred has read this session, so "what have you read?" can be
/// answered. In memory only; cleared when the app quits.
public enum ReadLog {
    public struct Entry: Sendable, Equatable {
        public let date: Date
        public let name: String
        public let path: String
    }

    private static let entries = Mutex<[Entry]>([])

    static func record(_ url: URL) {
        entries.withLock { list in
            list.removeAll { $0.path == url.path }
            list.append(Entry(date: Date(), name: url.lastPathComponent, path: url.path))
            if list.count > 50 { list.removeFirst(list.count - 50) }
        }
    }

    public static var all: [Entry] { entries.withLock { $0 } }
    static var last: URL? { entries.withLock { $0.last.map { URL(filePath: $0.path) } } }
}

/// Spots secrets (passwords, keys, tokens) in text before it is spoken or
/// shown, for the clipboard, file reading and the screen.
public enum SecretRedactor {
    static let placeholder = "[hidden]"

    private static let patterns: [NSRegularExpression] = [
        // "password: hunter2", "passcode = 1234", "API key: …"
        #"(?i)\b(pass(word|code|phrase)?|pwd|pin|secret|api[ _-]?key|access[ _-]?key|auth[ _-]?token|token|private[ _-]?key|client[ _-]?secret)\s*[:=]\s*\S+"#,
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#,
        #"\b(sk|pk|rk)-[A-Za-z0-9_-]{16,}\b"#,          // OpenAI/Stripe-style keys
        #"\bAKIA[0-9A-Z]{16}\b"#,                         // AWS access key IDs
        #"\bgh[pousr]_[A-Za-z0-9]{30,}\b"#,               // GitHub tokens
        #"\bxox[abprs]-[A-Za-z0-9-]{10,}\b"#,             // Slack tokens
        #"\bAIza[0-9A-Za-z_-]{30,}\b"#,                   // Google API keys
        #"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#, // JWTs
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// The text with anything that looks secret replaced.
    public static func redact(_ text: String) -> String {
        var result = text
        for pattern in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: placeholder)
        }
        return result
    }

    public static func containsSecret(_ text: String) -> Bool {
        redact(text) != text
    }
}
