#if DEBUG
import AppKit

/// Debug builds only: checks the browser tab scripting that YouTube autoplay
/// relies on (make a tab, read its id, navigate it, close it) against the
/// real default browser, on a throwaway example.com tab.
public enum BrowserProbe {
    public static func run() async {
        guard let app = Browser.runningApp(named: nil), let bundle = app.bundleIdentifier else {
            Log.tools.notice("probe: no default browser running")
            return
        }
        let first = URL(string: "https://example.com/?probe=1")!
        guard let id = await YouTubeAutoplay.openResultsTab(first, in: app) else {
            Log.tools.notice("probe: make tab failed in \(bundle, privacy: .public)")
            return
        }
        Log.tools.notice("probe: made tab id \(id, privacy: .public) in \(bundle, privacy: .public)")
        try? await Task.sleep(for: .seconds(1))
        let second = URL(string: "https://example.com/?probe=2")!
        let navigated = try? await AppleScript.evaluate(
            YouTubeAutoplay.navigateScript(bundle: bundle, tab: .id(id), to: second), controlling: "browser")
        Log.tools.notice("probe: navigate → \(navigated?.first ?? "error", privacy: .public)")
        try? await Task.sleep(for: .seconds(1))
        let closed = try? await AppleScript.evaluate([
            "tell application id \(AppleScript.quoted(bundle))",
            "    tell front window",
            "        if ((id of active tab) as text) is \(AppleScript.quoted(id)) then",
            "            set u to URL of active tab",
            "            close active tab",
            "            return \"closed \" & u",
            "        end if",
            "    end tell",
            "    return \"not ours; left open\"",
            "end tell",
        ].joined(separator: "\n"), controlling: "browser")
        Log.tools.notice("probe: \(closed?.first ?? "close error", privacy: .public)")
    }

}
#endif
