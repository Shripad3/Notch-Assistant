import FoundationModels
@testable import NotchAssistantCore
import Testing

struct MediaAndSystemDirectTests {
    let tools = ToolRegistry(tools: ToolRegistry.standard.tools, isEnabled: { _ in true }).enabledTools()

    private func match(_ transcript: String) -> (tool: String, action: String?, query: String?, value: Int?)? {
        guard let step = DirectMatcher.plan(for: transcript, tools: tools)?.steps.first else { return nil }
        let args = step.arguments
        return (
            step.tool.name,
            try? args.value(String.self, forProperty: "action"),
            try? args.value(String?.self, forProperty: "query"),
            try? args.value(Int?.self, forProperty: "value")
        )
    }

    @Test(arguments: [
        ("Play some music", "play"), ("pause the music", "pause"), ("Skip this song.", "next"),
        ("previous track", "previous"), ("resume", "play"), ("Play.", "play"), ("stop", "pause"),
    ])
    func spotifyTransport(transcript: String, action: String) {
        let result = match(transcript)
        #expect(result?.tool == "controlSpotify")
        #expect(result?.action == action)
    }

    @Test func playSong() {
        let result = match("play bohemian rhapsody on spotify")
        #expect(result?.action == "playSong")
        #expect(result?.query == "bohemian rhapsody")
    }

    @Test func playPlaylist() {
        let result = match("Play my chill vibes playlist")
        #expect(result?.action == "playPlaylist")
        #expect(result?.query == "chill vibes")
    }

    /// The canonical command is for the browser, never Spotify.
    @Test func youtubeIsNotSpotify() {
        #expect(match("Open Arc and play the Mat Armstrong YouTube video") == nil)
        #expect(match("play the mat armstrong video") == nil)
    }

    @Test(arguments: [
        ("Mute", "mute", nil), ("unmute the sound", "unmute", nil), ("Turn the volume up", "volumeUp", nil),
        ("quieter", "volumeDown", nil), ("set the volume to 40%", "setVolume", 40), ("volume 75", "setVolume", 75),
        ("put my Mac to sleep", "sleep", nil),
    ] as [(String, String, Int?)])
    func system(transcript: String, action: String, value: Int?) {
        let result = match(transcript)
        #expect(result?.tool == "systemControl")
        #expect(result?.action == action)
        #expect(result?.value == value)
    }

    @Test(arguments: ["set the volume to 140", "volume loud", "sleep on it later"])
    func systemLeftToModel(transcript: String) {
        #expect(match(transcript)?.tool != "systemControl")
    }

    @Test func appleScriptQuoting() {
        #expect(AppleScript.quoted("say \"hi\" \\ bye") == "\"say \\\"hi\\\" \\\\ bye\"")
    }
}

struct SpotifyExtrasTests {
    @Test(arguments: ["liked songs", "My Liked Songs", "my likes", "favorites"])
    func likedSongsRecognised(query: String) {
        #expect(SpotifyWebAPI.isLikedSongs(query))
    }

    @Test func ordinaryPlaylistIsNotLikedSongs() {
        #expect(!SpotifyWebAPI.isLikedSongs("liked songs 2019"))
        #expect(!SpotifyWebAPI.isLikedSongs("chill vibes"))
    }
}

struct BrightnessLockFocusTests {
    let tools = ToolRegistry(tools: ToolRegistry.standard.tools, isEnabled: { _ in true }).enabledTools()

    private func action(_ transcript: String) -> (tool: String, action: String?, value: Int?)? {
        guard let step = DirectMatcher.plan(for: transcript, tools: tools)?.steps.first else { return nil }
        return (step.tool.name, try? step.arguments.value(String.self, forProperty: "action"), try? step.arguments.value(Int?.self, forProperty: "value"))
    }

    @Test(arguments: [
        ("Make the screen brighter", "brightnessUp", nil), ("dimmer", "brightnessDown", nil),
        ("set the brightness to 60", "setBrightness", 60), ("brightness 30%", "setBrightness", 30),
        ("full brightness", "setBrightness", 100), ("Lock my Mac.", "lock", nil), ("lock the screen", "lock", nil),
        ("Turn on do not disturb", "doNotDisturbOn", nil), ("do not disturb off", "doNotDisturbOff", nil),
    ] as [(String, String, Int?)])
    func routes(transcript: String, expected: String, value: Int?) {
        let result = action(transcript)
        #expect(result?.tool == "systemControl")
        #expect(result?.action == expected)
        #expect(result?.value == value)
    }

    /// "lock" alone is the screen, but "open my lock screen wallpaper" is not.
    @Test func lockOnlyAsCommand() {
        #expect(action("open my lock screen wallpaper")?.action != "lock")
    }

    @Test func groundingCoversNewWords() async {
        await #expect(throws: ToolError.self) {
            try await CommandContext.$transcript.withValue("hello there") {
                try await SystemControlTool().execute(SystemControlArguments(action: "lock", value: nil))
            }
        }
    }
}
