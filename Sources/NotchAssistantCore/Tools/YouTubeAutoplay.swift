import AppKit
import ApplicationServices

/// Tier 2 of spec §9's playYouTube: after the results page opens, find the
/// first real video in the browser's accessibility tree and press it. Best
/// effort by design: YouTube's page changes without notice, so any failure
/// leaves the user on the results page (Tier 1), never with nothing.
enum YouTubeAutoplay {
    /// Bump when the rules below change, so logs show which rules failed.
    static let recipeVersion = "youtube-results/2026-09-25"
    static let enabledKey = "youtube.autoplay"
    static let timeout: Duration = .seconds(10)
    /// Accessibility trees of results pages are large; stop searching after this many elements.
    static let searchBudget = 8000

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// The first result's title when it was pressed, or nil when the results
    /// page stays as it is.
    static func playFirstResult(in app: NSRunningApplication) async throws -> String? {
        guard AXIsProcessTrusted() else {
            Log.tools.notice("youtube autoplay: no Accessibility permission; staying on results")
            return nil
        }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 1.5)
        // Chromium browsers (Arc, Chrome, Edge, Brave) only build the page's
        // accessibility tree when asked; Safari ignores this.
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let (link, title, url) = firstVideoLink(in: application) {
                try await open(url, link: link, in: app)
                // Only claim success once the tab is really on the video.
                guard try await reachesVideo(application) else {
                    Log.tools.notice("youtube autoplay [\(recipeVersion, privacy: .public)]: \(app.bundleIdentifier ?? "?", privacy: .public) didn't navigate to \(url.absoluteString, privacy: .public)")
                    return nil
                }
                Log.tools.notice("youtube autoplay: playing \"\(title, privacy: .public)\"")
                return title
            }
            // The page is still loading: poll rather than sleep a fixed time (spec §9).
            try await Task.sleep(for: .milliseconds(400))
        }
        Log.tools.notice("youtube autoplay [\(recipeVersion, privacy: .public)]: no video found within \(timeout, privacy: .public); \(describe(application), privacy: .public)")
        return nil
    }

    /// What the tree looked like when nothing was found, for the log.
    private static func describe(_ application: AXUIElement) -> String {
        guard let window: AXUIElement = attribute(application, kAXFocusedWindowAttribute) else { return "no focused window" }
        var budget = searchBudget
        guard let page = resultsPage(under: window, budget: &budget) else { return "no web area in the focused window" }
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
        return "page \(pageURL?.absoluteString ?? "without an address"), \(count) links, examined \(searchBudget - budget) elements, first: \(links)"
    }

    /// Scriptable browsers whose active tab's address can be set directly.
    /// Arc accepted an Accessibility press on the link but didn't navigate.
    static let chromiumBrowsers: Set<String> = [
        "company.thebrowser.Browser", "company.thebrowser.dia", "com.google.Chrome", "com.brave.Browser",
        "com.microsoft.edgemac", "org.chromium.Chromium", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    /// Sends the browser's current tab to the video: by AppleScript where
    /// the browser supports it, else by pressing the link.
    private static func open(_ url: URL, link: AXUIElement, in app: NSRunningApplication) async throws {
        let bundle = app.bundleIdentifier ?? ""
        let name = app.localizedName ?? "the browser"
        let script: String? = if chromiumBrowsers.contains(bundle) {
            "tell application id \"\(bundle)\" to set URL of active tab of front window to \(AppleScript.quoted(url.absoluteString))"
        } else if bundle == "com.apple.Safari" {
            "tell application id \"com.apple.Safari\" to set URL of current tab of front window to \(AppleScript.quoted(url.absoluteString))"
        } else {
            nil
        }
        if let script {
            do {
                try await AppleScript.run(script, controlling: name)
                return
            } catch {
                Log.tools.notice("youtube autoplay: script navigation failed (\(AssistantFailure(error).message, privacy: .public)); pressing instead")
            }
        }
        _ = AXUIElementPerformAction(link, kAXPressAction as CFString)
    }

    /// Whether the page shows a video within about three seconds.
    private static func reachesVideo(_ application: AXUIElement) async throws -> Bool {
        for _ in 0..<8 {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(400))
            if let window: AXUIElement = attribute(application, kAXFocusedWindowAttribute) {
                var budget = 2000
                if let page = anyWebArea(under: window, budget: &budget),
                   let url: URL = attribute(page, kAXURLAttribute), isVideo(url) {
                    return true
                }
            }
        }
        return false
    }

    private static func anyWebArea(under root: AXUIElement, budget: inout Int) -> AXUIElement? {
        var found: AXUIElement?
        walk(root, budget: &budget) { element, role in
            guard role == "AXWebArea" else { return true }
            let url: URL? = attribute(element, kAXURLAttribute)
            if let url, url.host()?.contains("youtube.com") == true {
                found = element
                return false
            }
            return true
        }
        return found
    }

    /// The canonical address for a video, rebuilt from its id alone so
    /// nothing else from the page is passed to the browser.
    static func canonical(_ url: URL) -> URL? {
        guard let id = videoID(url), id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return URL(string: "https://www.youtube.com/watch?v=\(id)")
    }

    /// A real video: youtube.com/watch?v=… Shorts, channels, playlists
    /// without a video and ad-redirect links are not. Pure, for testing.
    static func isVideo(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased(), host == "youtube.com" || host.hasSuffix(".youtube.com"),
              url.path() == "/watch",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.contains(where: { $0.name == "v" && !($0.value ?? "").isEmpty }) == true
        else { return false }
        let text = url.absoluteString.lowercased()
        return !["adurl", "pagead", "googleadservices", "/shorts/"].contains { text.contains($0) }
    }

    static func videoID(_ url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
    }

    // MARK: Accessibility tree

    private static func firstVideoLink(in application: AXUIElement) -> (AXUIElement, String, URL)? {
        guard let window: AXUIElement = attribute(application, kAXFocusedWindowAttribute) else { return nil }
        var budget = searchBudget
        guard let page = resultsPage(under: window, budget: &budget) else { return nil }
        return firstLink(under: page, budget: &budget)
    }

    /// The web area showing YouTube search results, or else the first web
    /// area (some browsers don't report the page's address).
    private static func resultsPage(under root: AXUIElement, budget: inout Int) -> AXUIElement? {
        var fallback: AXUIElement?
        var found: AXUIElement?
        walk(root, budget: &budget) { element, role in
            guard role == "AXWebArea" else { return true }
            let url: URL? = attribute(element, kAXURLAttribute)
            if let url, url.host()?.contains("youtube.com") == true, url.path() == "/results" {
                found = element
                return false
            }
            if fallback == nil { fallback = element }
            return true
        }
        return found ?? fallback
    }

    /// Document order: the first qualifying link is the top result.
    private static func firstLink(under page: AXUIElement, budget: inout Int) -> (AXUIElement, String, URL)? {
        var result: (AXUIElement, String)?
        var firstVideo: String?
        var firstURL: URL?
        walk(page, budget: &budget) { element, role in
            guard role == "AXLink", let url: URL = attribute(element, kAXURLAttribute), isVideo(url) else { return true }
            let id = videoID(url)
            let title: String = attribute(element, kAXTitleAttribute) ?? attribute(element, kAXDescriptionAttribute) ?? ""
            if firstVideo == nil {
                firstVideo = id
                firstURL = canonical(url)
                result = (element, title)
                // A thumbnail link has no text; look for its title link next.
                return title.isEmpty
            }
            // Only the same video's title link; never a later result.
            guard id == firstVideo else { return false }
            if !title.isEmpty { result = (element, title) }
            return title.isEmpty
        }
        guard let result, let firstURL else { return nil }
        return (result.0, result.1.isEmpty ? "the top result" : result.1, firstURL)
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
