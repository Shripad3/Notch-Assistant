import AppKit
import FoundationModels

@Generable
struct OpenURLArguments: Sendable {
    @Guide(description: "Full web address starting with https://, e.g. https://www.youtube.com")
    var url: String
    @Guide(description: "Browser name, only if the user named one, e.g. \"Arc\"")
    var browser: String?
}

struct OpenURLTool: AssistantTool {
    let name = "openURL"
    let title = "Open website"
    let symbol = "globe"
    let keywords: Set<String> = ["open", "go", "website", "site", "com", "org", "www", "page", "visit", "browser"]
    let description = """
        Open a website in a browser. "open YouTube" or "go to YouTube" → url "https://www.youtube.com". \
        "open YouTube in Arc" → url "https://www.youtube.com", browser "Arc"; no openApp step. \
        Only use a site's home page or an address the user said. Never make up a path or video ID.
        """
    let requiresNetwork = true
    let permission = ToolPermission.none
    let reversibility = Reversibility.notApplicable

    func target(of arguments: OpenURLArguments) -> String {
        WebAddress.normalize(arguments.url)?.host() ?? arguments.url
    }

    func execute(_ arguments: OpenURLArguments) async throws -> ToolResult {
        guard var url = WebAddress.normalize(arguments.url) else {
            throw ToolError("\"\(arguments.url)\" isn't a web address I can open")
        }
        var browserName = arguments.browser
        // Act only on what the user said: an invented path falls back to the
        // site's home page, and an unspoken browser to the default one.
        if let transcript = CommandContext.transcript {
            if !Grounding.isSpoken(url, in: transcript), let home = WebAddress.homePage(of: url) {
                Log.tools.notice("openURL: \(url.absoluteString, privacy: .public) not spoken; opening home page")
                url = home
            }
        }
        browserName = Browser.grounded(browserName)
        // "go to YouTube" came back with browser "YouTube": the site, not a browser.
        if let name = browserName, (url.host() ?? "").contains(AppNameMatcher.key(name)) {
            browserName = nil
        }
        let host = url.host() ?? url.absoluteString
        try Task.checkCancellation()
        let browser = try await Browser.open(url, in: browserName)
        return browser.map { "Opened \(host) in \($0)" } ?? "Opened \(host)"
    }
}

/// Opens a URL in a named browser, or the default one.
enum Browser {
    /// Drops a browser the user didn't say. Returns the name of the browser
    /// used, or nil for the default.
    ///
    /// With no browser given, uses an installed browser the user named anyway:
    /// "open Arc and play the … YouTube video" plans openApp Arc, then a
    /// YouTube step without a browser, which would open elsewhere.
    static func grounded(_ name: String?) -> String? {
        guard let transcript = CommandContext.transcript else { return name }
        guard let name else { return mentionedBrowser(in: transcript) }
        if Grounding.mentions(name, in: transcript) { return name }
        Log.tools.notice("browser \"\(name, privacy: .public)\" not spoken; using default")
        return mentionedBrowser(in: transcript)
    }

    private static func mentionedBrowser(in transcript: String) -> String? {
        NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "https://example.com")!)
            .map { $0.deletingPathExtension().lastPathComponent }
            .first { Grounding.mentions($0, in: transcript) }
    }

    /// The running browser that `open(_:in:)` used, for Accessibility work
    /// on the page it opened (YouTube autoplay).
    static func runningApp(named name: String?) -> NSRunningApplication? {
        let url = name.flatMap { InstalledApps.resolve($0)?.url }
            ?? NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
        guard let url else { return nil }
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }
    }

    static func open(_ url: URL, in spokenBrowser: String?) async throws -> String? {
        let configuration = NSWorkspace.OpenConfiguration()
        if let spoken = spokenBrowser?.trimmingCharacters(in: .whitespaces), !spoken.isEmpty,
           !AppNameMatcher.isGenericBrowser(spoken) {
            guard let browser = InstalledApps.resolve(spoken) else {
                throw ToolError("I couldn't find a browser called \"\(spoken)\"")
            }
            Log.tools.notice("open → \(url.absoluteString, privacy: .public) in \(browser.name, privacy: .public)")
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: browser.url, configuration: configuration)
            return browser.name
        }
        Log.tools.notice("open → \(url.absoluteString, privacy: .public)")
        _ = try await NSWorkspace.shared.open(url, configuration: configuration)
        return nil
    }
}

extension OpenURLTool {
    func directArguments(for command: DirectCommand) -> OpenURLArguments? {
        guard ["open", "go to"].contains(command.verb) else { return nil }
        let (thing, spokenBrowser) = command.target
        var browser: String?
        if let spokenBrowser {
            guard AppNameMatcher.isGenericBrowser(spokenBrowser) || InstalledApps.resolve(spokenBrowser) != nil else { return nil }
            browser = spokenBrowser
        }
        if let url = WebAddress.spoken(thing) {
            return OpenURLArguments(url: url.absoluteString, browser: browser)
        }
        guard let site = WebAddress.knownSites[AppNameMatcher.key(thing)] else { return nil }
        return OpenURLArguments(url: site, browser: browser)
    }
}

enum WebAddress {
    /// Sites people open by name. Keys are compact keys (`AppNameMatcher.key`).
    static let knownSites: [String: String] = [
        "youtube": "https://www.youtube.com",
        "gmail": "https://mail.google.com",
        "google": "https://www.google.com",
        "googlemaps": "https://maps.google.com",
        "github": "https://github.com",
        "wikipedia": "https://www.wikipedia.org",
        "reddit": "https://www.reddit.com",
        "netflix": "https://www.netflix.com",
        "amazon": "https://www.amazon.com",
        "twitter": "https://x.com",
        "x": "https://x.com",
        "linkedin": "https://www.linkedin.com",
        "instagram": "https://www.instagram.com",
        "facebook": "https://www.facebook.com",
        "whatsapp": "https://web.whatsapp.com",
        "chatgpt": "https://chatgpt.com",
        "claude": "https://claude.ai",
    ]

    private static let spokenDomainEndings: Set<String> = ["com", "org", "net", "io", "ai", "dev", "app", "nl", "in", "co", "uk"]

    /// A bare domain as it arrives from normalised speech: "github com" or
    /// "github dot com" → https://github.com. Paths are left to the model.
    static func spoken(_ words: String) -> URL? {
        var parts = words.split(separator: " ").map(String.init).filter { $0 != "dot" }
        guard parts.count >= 2, parts.count <= 3, let ending = parts.last, spokenDomainEndings.contains(ending) else { return nil }
        parts.removeLast()
        return normalize(parts.joined() + "." + ending)
    }

    /// Accepts "youtube.com", "https://youtube.com/x" and similar. Only http
    /// and https: the model must not be able to open file: or app URL schemes.
    static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".")
        else { return nil }
        return url
    }

    static func homePage(of url: URL) -> URL? {
        guard let scheme = url.scheme, let host = url.host() else { return nil }
        return URL(string: "\(scheme)://\(host)")
    }
}
