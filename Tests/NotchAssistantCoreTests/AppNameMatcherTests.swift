@testable import NotchAssistantCore
import Testing

struct AppNameMatcherTests {
    let installed = [
        "Arc", "Spotify", "Safari", "Google Chrome", "Chrome Remote Desktop", "Visual Studio Code",
        "System Settings", "Notes", "Numbers", "Finder", "App Store", "FaceTime", "Xcode",
    ]

    @Test(arguments: [
        ("Spotify", "Spotify"),
        ("spotify", "Spotify"),
        ("the Spotify app", "Spotify"),
        ("Spotify.app", "Spotify"),
        ("arc", "Arc"),
        ("ark", "Arc"),
        ("chrome", "Google Chrome"),
        ("google chrome", "Google Chrome"),
        ("vs code", "Visual Studio Code"),
        ("VSCode", "Visual Studio Code"),
        ("settings", "System Settings"),
        ("system preferences", "System Settings"),
        ("spotfy", "Spotify"),
        ("appstore", "App Store"),
        ("Face Time", "FaceTime"),
    ])
    func matches(spoken: String, expected: String) {
        #expect(AppNameMatcher.match(spoken, candidates: installed) == expected)
    }

    @Test(arguments: ["YouTube", "my calendar thing", "", "   ", "no", "Microsoft Word"])
    func noConfidentMatchFails(spoken: String) {
        #expect(AppNameMatcher.match(spoken, candidates: installed) == nil)
    }

    @Test func ambiguousWordMatchFails() {
        #expect(AppNameMatcher.match("remote", candidates: ["Chrome Remote Desktop", "Remote Desktop Connection"]) == nil)
    }

    @Test func nearTieSpellingFails() {
        #expect(AppNameMatcher.match("noters", candidates: ["Notes", "Noter"]) != "Notes")
    }

    @Test func userAliasesApply() {
        #expect(AppNameMatcher.match("music", candidates: installed, aliases: ["music": "Spotify"]) == "Spotify")
    }

    @Test(arguments: ["browser", "my browser", "the browser", "web browser"])
    func genericBrowser(spoken: String) {
        #expect(AppNameMatcher.isGenericBrowser(spoken))
    }
}
