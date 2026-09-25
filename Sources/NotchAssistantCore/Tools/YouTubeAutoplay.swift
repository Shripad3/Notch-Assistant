import AppKit
import ApplicationServices

/// Tier 2 of spec §9's playYouTube: after the results page opens, find the
/// video in the browser's accessibility tree and send the tab to it. Best
/// effort by design: YouTube's page changes without notice, so any failure
/// leaves the user on a results page (Tier 1), never with nothing, and never
/// touches a tab this command didn't open.
enum YouTubeAutoplay {
    /// Bump when the rules below change, so logs show which rules failed.
    static let recipeVersion = "youtube-results/2026-09-25b"
    static let enabledKey = "youtube.autoplay"
    static let pageTimeout: Duration = .seconds(10)
    /// Accessibility trees of results pages are large; stop searching after this many elements.
    static let searchBudget = 8000
    /// A creator's channel appears near the top of the results, or not at all.
    static let channelSearchLinks = 60

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Scriptable browsers whose tabs can be created and addressed. Arc
    /// accepted an Accessibility press on a video link without navigating.
    static let chromiumBrowsers: Set<String> = [
        "company.thebrowser.Browser", "company.thebrowser.dia", "com.google.Chrome", "com.brave.Browser",
        "com.microsoft.edgemac", "org.chromium.Chromium", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    /// The tab this command opened. Only this tab is ever navigated.
    enum ResultsTab: Sendable, Equatable {
        /// Created by script; its id is known.
        case id(String)
        /// Opened some other way; found by address.
        case search(String)
    }

    // MARK: Flow

    /// Opens the results in a new tab of the front window, by script, and
    /// returns its id. Arc sends links from other apps to Little Arc, apart
    /// from the user's tabs; a scripted tab lands with the rest. The id is
    /// read from the active tab: the tab reference `make` returns in Arc
    /// can't be read back (error -1700, it sits in an unnamed space class).
    static func openResultsTab(_ url: URL, in app: NSRunningApplication) async -> String? {
        guard let bundle = app.bundleIdentifier, chromiumBrowsers.contains(bundle) else { return nil }
        do {
            return try await AppleScript.evaluate(makeTabScript(bundle: bundle, url: url), controlling: app.localizedName ?? "the browser").first
        } catch {
            Log.tools.notice("youtube autoplay: couldn't open a tab by script (\(AssistantFailure(error).message, privacy: .public))")
            return nil
        }
    }

    /// Finds the video and sends the results tab to it. Returns the video's
    /// title once the tab is really on it; nil leaves a results page.
    ///
    /// With `latestFromCreator`, the query is treated as a creator: their
    /// channel's Videos page (newest first) supplies the video. Sorting all
    /// of YouTube by upload date instead played the newest video *anyone*
    /// posted with those words ("KINGS x TRANNOS - MADAME" for "Madame's
    /// latest"). Without a matching channel it falls back to that sort.
    static func play(query: String, latestFromCreator: Bool, in app: NSRunningApplication, tab: ResultsTab) async throws -> String? {
        guard AXIsProcessTrusted() else {
            Log.tools.notice("youtube autoplay: no Accessibility permission; staying on results")
            return nil
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 1.5)
        // Chromium browsers only build the page's accessibility tree when asked.
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let browser = Browser(app: app, tab: tab)

        var onResults: (URL) -> Bool = { $0.path() == "/results" }
        if latestFromCreator {
            let channel = try await poll { channelLink(in: application, matching: query) }
            if let channel, let videos = channelVideosPage(channel) {
                Log.tools.notice("youtube autoplay: \(query, privacy: .public) → channel \(channel.absoluteString, privacy: .public)")
                guard try await browser.navigate(to: videos) else { return nil }
                onResults = { $0.path().hasSuffix("/videos") }
            } else if let sorted = PlayYouTubeTool.searchURL(for: query, latest: true) {
                Log.tools.notice("youtube autoplay: no channel for \(query, privacy: .public); newest uploads instead")
                guard try await browser.navigate(to: sorted) else { return nil }
                onResults = { $0.path() == "/results" && ($0.query() ?? "").contains("sp=") }
            }
        }

        let page = onResults
        guard let (title, video) = try await poll({ firstVideo(in: application, onPage: page) }) else {
            Log.tools.notice("youtube autoplay [\(recipeVersion, privacy: .public)]: no video found; \(describe(application), privacy: .public)")
            return nil
        }
        guard try await browser.navigate(to: video), try await reachesVideo(application) else {
            Log.tools.notice("youtube autoplay [\(recipeVersion, privacy: .public)]: didn't reach \(video.absoluteString, privacy: .public)")
            return nil
        }
        Log.tools.notice("youtube autoplay: playing \"\(title, privacy: .public)\"")
        return title
    }

    /// Retries until the page has loaded enough to answer, or times out.
    /// Polls rather than sleeping a fixed time (spec §9); Escape cancels.
    private static func poll<T>(_ attempt: () -> T?) async throws -> T? {
        let deadline = ContinuousClock.now + pageTimeout
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let value = attempt() { return value }
            try await Task.sleep(for: .milliseconds(400))
        }
        return nil
    }

    // MARK: Navigating only our tab

    private struct Browser {
        let app: NSRunningApplication
        let tab: ResultsTab

        /// Sends this command's tab to `url`. False if that tab can't be
        /// found; then, for the final video only, a new tab is opened.
        func navigate(to url: URL) async throws -> Bool {
            let bundle = app.bundleIdentifier ?? ""
            let name = app.localizedName ?? "the browser"
            guard chromiumBrowsers.contains(bundle) || bundle == "com.apple.Safari" else { return false }
            do {
                let outcome = try await AppleScript.evaluate(navigateScript(bundle: bundle, tab: tab, to: url), controlling: name)
                if outcome.first == "replaced" { return true }
                Log.tools.notice("youtube autoplay: our tab is no longer active or can't be found")
            } catch {
                Log.tools.notice("youtube autoplay: couldn't script \(name, privacy: .public) (\(AssistantFailure(error).message, privacy: .public))")
            }
            // Never another tab: for the video itself, a new tab.
            guard isVideo(url), let appURL = app.bundleURL else { return false }
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
            return true
        }
    }

    static func makeTabScript(bundle: String, url: URL) -> String {
        [
            "tell application id \(AppleScript.quoted(bundle))",
            "    activate",
            "    if (count of windows) = 0 then make new window",
            "    tell front window",
            "        make new tab with properties {URL:\(AppleScript.quoted(url.absoluteString))}",
            "        delay 0.3",
            "        return (id of active tab) as text",
            "    end tell",
            "end tell",
        ].joined(separator: "\n")
    }

    /// By id: only if our tab is still the active one (the user may have
    /// switched away). By address (Safari, or when the tab wasn't scripted):
    /// the results tab in any window, space or application tab list.
    /// Pure, for testing.
    static func navigateScript(bundle: String, tab: ResultsTab, to url: URL) -> String {
        let target = AppleScript.quoted(url.absoluteString)
        switch tab {
        case .id(let id):
            return [
                "tell application id \(AppleScript.quoted(bundle))",
                "    if (count of windows) = 0 then return \"missing\"",
                "    tell front window",
                "        if ((id of active tab) as text) is \(AppleScript.quoted(id)) then",
                "            set URL of active tab to \(target)",
                "            return \"replaced\"",
                "        end if",
                "    end tell",
                "    return \"missing\"",
                "end tell",
            ].joined(separator: "\n")
        case .search(let word):
            return [
                "tell application id \(AppleScript.quoted(bundle))",
                "    set candidates to {}",
                "    repeat with w in windows",
                "        try",
                "            set candidates to candidates & (tabs of w)",
                "        end try",
                "    end repeat",
                "    repeat with t in candidates",
                "        try",
                "            if (URL of t) contains \"youtube.com/results\" and (URL of t) contains \(AppleScript.quoted(word)) then",
                "                set URL of t to \(target)",
                "                return \"replaced\"",
                "            end if",
                "        end try",
                "    end repeat",
                "    return \"missing\"",
                "end tell",
            ].joined(separator: "\n")
        }
    }

    // MARK: Rules (pure)

    /// A real video: youtube.com/watch?v=… Shorts, channels, playlists
    /// without a video and ad-redirect links are not.
    static func isVideo(_ url: URL) -> Bool {
        guard isYouTube(url), url.path() == "/watch",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.contains(where: { $0.name == "v" && !($0.value ?? "").isEmpty }) == true
        else { return false }
        let text = url.absoluteString.lowercased()
        return !["adurl", "pagead", "googleadservices", "/shorts/"].contains { text.contains($0) }
    }

    static func isYouTube(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    /// A channel: youtube.com/@handle or /channel/ID.
    static func isChannel(_ url: URL) -> Bool {
        let parts = url.path().split(separator: "/")
        guard isYouTube(url), let first = parts.first else { return false }
        return (first.hasPrefix("@") && parts.count == 1) || (first == "channel" && parts.count == 2)
    }

    /// A channel's name matches what was said: every word of the name was
    /// said, or the spelling is close ("Mat Armstrong" for "matt armstrong").
    static func channelMatches(title: String, query: String) -> Bool {
        let name = AppNameMatcher.normalize(title).split(separator: " ").map(String.init)
        let said = Set(AppNameMatcher.normalize(query).split(separator: " ").map(String.init))
        guard !name.isEmpty else { return false }
        if name.allSatisfy(said.contains) { return true }
        return AppNameMatcher.similarity(AppNameMatcher.key(title), AppNameMatcher.key(query)) >= 0.8
    }

    /// The channel's Videos tab, which lists newest first, rebuilt from the
    /// channel path alone.
    static func channelVideosPage(_ channel: URL) -> URL? {
        let path = channel.path()
        guard isChannel(channel), path.allSatisfy({ $0.isLetter || $0.isNumber || "/@-_.".contains($0) }) else { return nil }
        return URL(string: "https://www.youtube.com\(path)/videos")
    }

    static func videoID(_ url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
    }

    /// The canonical address for a video, rebuilt from its id alone so
    /// nothing else from the page is passed to the browser.
    static func canonical(_ url: URL) -> URL? {
        guard let id = videoID(url), id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return URL(string: "https://www.youtube.com/watch?v=\(id)")
    }

    /// A word from the search that appears in the results tab's address
    /// however the browser encodes spaces ("%20" or "+").
    static func searchWord(for query: String) -> String {
        let words: [String] = AppNameMatcher.normalize(query).split(separator: " ").map(String.init)
        return words.max { $0.count < $1.count } ?? query
    }

    // MARK: Accessibility tree

    /// The first video on the YouTube page satisfying `onPage`, as (title,
    /// canonical URL). Document order: the first qualifying link is the top.
    private static func firstVideo(in application: AXUIElement, onPage: (URL) -> Bool) -> (String, URL)? {
        var budget = searchBudget
        guard let page = youtubePage(in: application, budget: &budget, where: onPage) else { return nil }
        var title: String?
        var found: URL?
        walk(page, budget: &budget) { element, role in
            guard role == "AXLink", let url: URL = attribute(element, kAXURLAttribute), isVideo(url) else { return true }
            let text: String = attribute(element, kAXTitleAttribute) ?? attribute(element, kAXDescriptionAttribute) ?? ""
            if found == nil {
                found = canonical(url)
                title = text
                // A thumbnail link has no text; its title link follows.
                return text.isEmpty
            }
            guard canonical(url) == found else { return false } // Never a later result.
            if !text.isEmpty { title = text }
            return text.isEmpty
        }
        guard let found else { return nil }
        return ((title ?? "").isEmpty ? "the top result" : title!, found)
    }

    /// The first channel link near the top whose name matches the query.
    private static func channelLink(in application: AXUIElement, matching query: String) -> URL? {
        var budget = searchBudget
        guard let page = youtubePage(in: application, budget: &budget, where: { $0.path() == "/results" }) else { return nil }
        var links = 0
        var found: URL?
        walk(page, budget: &budget) { element, role in
            guard role == "AXLink" else { return true }
            links += 1
            if let url: URL = attribute(element, kAXURLAttribute), isChannel(url) {
                let text: String = attribute(element, kAXTitleAttribute) ?? attribute(element, kAXDescriptionAttribute) ?? ""
                if channelMatches(title: text, query: query) {
                    found = url
                    return false
                }
            }
            return links < channelSearchLinks
        }
        return found
    }

    private static func youtubePage(in application: AXUIElement, budget: inout Int, where accept: (URL) -> Bool) -> AXUIElement? {
        guard let window: AXUIElement = attribute(application, kAXFocusedWindowAttribute) else { return nil }
        var found: AXUIElement?
        walk(window, budget: &budget) { element, role in
            guard role == "AXWebArea" else { return true }
            if let url: URL = attribute(element, kAXURLAttribute), isYouTube(url), accept(url) {
                found = element
                return false
            }
            return true
        }
        return found
    }

    /// Whether the page shows a video within about three seconds.
    private static func reachesVideo(_ application: AXUIElement) async throws -> Bool {
        for _ in 0..<8 {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(400))
            var budget = 2000
            if youtubePage(in: application, budget: &budget, where: isVideo) != nil { return true }
        }
        return false
    }

    /// What the tree looked like when nothing was found, for the log.
    private static func describe(_ application: AXUIElement) -> String {
        var budget = searchBudget
        guard let page = youtubePage(in: application, budget: &budget, where: { _ in true }) else {
            return "no YouTube page in the focused window"
        }
        let pageURL: URL? = attribute(page, kAXURLAttribute)
        var links: [String] = []
        var count = 0
        walk(page, budget: &budget) { element, role in
            if role == "AXLink" {
                count += 1
                if links.count < 5, let url: URL = attribute(element, kAXURLAttribute) { links.append(url.absoluteString) }
            }
            return true
        }
        return "page \(pageURL?.absoluteString ?? "?"), \(count) links, first: \(links)"
    }

    /// Pre-order walk. `visit` returns false to stop.
    private static func walk(_ root: AXUIElement, budget: inout Int, visit: (AXUIElement, String) -> Bool) {
        var stack = [root]
        while let element = stack.popLast(), budget > 0 {
            budget -= 1
            let role: String = attribute(element, kAXRoleAttribute) ?? ""
            guard visit(element, role) else { return }
            let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
            stack.append(contentsOf: children.reversed())
        }
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        if T.self == URL.self, CFGetTypeID(value) == CFURLGetTypeID() {
            return (value as! CFURL as URL) as? T
        }
        if T.self == AXUIElement.self, CFGetTypeID(value) == AXUIElementGetTypeID() {
            return (value as! AXUIElement) as? T
        }
        return value as? T
    }
}
