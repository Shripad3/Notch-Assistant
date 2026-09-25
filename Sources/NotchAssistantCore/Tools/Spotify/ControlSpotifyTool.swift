import AppKit
import FoundationModels

@Generable
struct ControlSpotifyArguments: Sendable {
    @Guide(description: "What to do", .anyOf(["play", "pause", "next", "previous", "setVolume", "playSong", "playPlaylist"]))
    var action: String
    @Guide(description: "Song, artist or playlist name as the user said it, only for playSong or playPlaylist")
    var query: String?
    @Guide(description: "Spotify volume from 0 to 100, only for setVolume")
    var value: Int?
}

/// Drives the Spotify desktop app with AppleScript: no OAuth, no network
/// round trip, instant transport (spec §9). playSong and playPlaylist use the
/// Web API only to find the URI, when the user has connected it in Settings;
/// otherwise they open Spotify's search instead of playing.
struct ControlSpotifyTool: AssistantTool {
    let name = "controlSpotify"
    let title = "Spotify"
    let symbol = "music.note"
    let keywords: Set<String> = ["play", "music", "song", "songs", "spotify", "pause", "resume", "skip", "next", "previous", "playlist", "album", "track", "listen"]
    let description = """
        Control music in the Spotify app. "play some music" → action "play". "skip this song" → action "next". \
        "play Bohemian Rhapsody" → action "playSong", query "Bohemian Rhapsody". \
        "play my running playlist" → action "playPlaylist", query "running".
        """
    let requiresNetwork = true
    let permission = ToolPermission.automation
    let reversibility = Reversibility.notApplicable

    static let bundleIdentifier = "com.spotify.client"

    func target(of arguments: ControlSpotifyArguments) -> String {
        switch arguments.action {
        case "playSong", "playPlaylist": arguments.query ?? ""
        case "setVolume": "Volume \(arguments.value.map { "\($0)%" } ?? "")"
        case "next": "Next track"
        case "previous": "Previous track"
        default: arguments.action.capitalized
        }
    }

    /// Something musical must have been said. Given "turn on DND", the model
    /// chose Spotify play (query "DND"), launched Spotify and started music.
    private static let groundingWords: Set<String> = [
        "play", "music", "song", "songs", "spotify", "pause", "resume", "skip", "next", "previous", "track",
        "playlist", "album", "artist", "stop", "listen", "put",
    ]

    func execute(_ arguments: ControlSpotifyArguments) async throws -> ToolResult {
        if let transcript = CommandContext.transcript,
           !AppNameMatcher.normalize(transcript).split(separator: " ").contains(where: { Self.groundingWords.contains(String($0)) }) {
            throw ToolError("I didn't catch what to do")
        }
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) != nil else {
            throw ToolError("Spotify isn't installed")
        }
        try Task.checkCancellation()
        // Only playing is worth launching Spotify for.
        if ["pause", "next", "previous", "setVolume"].contains(arguments.action), !Self.isRunning {
            throw ToolError("Spotify isn't running")
        }
        switch arguments.action {
        case "play":
            try await launchIfNeeded()
            try await tell("play")
            if try await becomesPlaying() { return "Playing on Spotify" }
            // Freshly launched Spotify can have nothing to resume.
            try await tell("play")
            if try await becomesPlaying() { return "Playing on Spotify" }
            if SpotifyWebAPI.isSignedIn, let liked = try await SpotifyWebAPI.shared.likedSongs() {
                try await tell("play track \(AppleScript.quoted(liked.uri))")
                if try await becomesPlaying() { return "Playing \(liked.title)" }
            }
            throw ToolError("Spotify opened but had nothing to play. Try “play” with a song or playlist name")
        case "pause":
            try await tell("pause")
            return "Paused Spotify"
        case "next":
            try await tell("next track")
            return "Next track"
        case "previous":
            try await tell("previous track")
            return "Previous track"
        case "setVolume":
            guard let value = arguments.value, (0...100).contains(value) else { throw ToolError("What volume should Spotify play at?") }
            try await tell("set sound volume to \(value)")
            return "Spotify volume \(value)%"
        case "playSong", "playPlaylist":
            guard let query = arguments.query?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
                throw ToolError("What should I play?")
            }
            guard SpotifyWebAPI.isSignedIn else { return ToolResult(try await openSearch(for: query)) }
            let isPlaylist = arguments.action == "playPlaylist"
            let match = if SpotifyWebAPI.isLikedSongs(query) {
                try await SpotifyWebAPI.shared.likedSongs()
            } else if isPlaylist {
                try await SpotifyWebAPI.shared.findPlaylist(query)
            } else {
                try await SpotifyWebAPI.shared.findTrack(query)
            }
            guard let match else {
                throw ToolError("I couldn't find \(isPlaylist ? "a playlist" : "a song") called “\(query)” on Spotify")
            }
            try Task.checkCancellation()
            Log.tools.notice("controlSpotify → \(match.uri, privacy: .public)")
            try await launchIfNeeded()
            try await tell("play track \(AppleScript.quoted(match.uri))")
            guard try await becomesPlaying() else {
                throw ToolError("Spotify didn't start playing \(match.title)")
            }
            return "Playing \(match.title)"
        default:
            throw ToolError("Spotify can't do \"\(arguments.action)\"")
        }
    }

    func directArguments(for command: DirectCommand) -> ControlSpotifyArguments? {
        // Dropped first: "play some music on Spotify" is the transport phrase
        // "play some music", not a song called "some music".
        var text = command.text
        for suffix in [" on spotify", " in spotify"] where text.hasSuffix(suffix) {
            text.removeLast(suffix.count)
        }
        switch text {
        case "play", "play some music", "play music", "play my music", "resume", "resume music", "resume the music", "play spotify", "resume spotify":
            return .init(action: "play", query: nil, value: nil)
        case "pause", "stop", "pause music", "pause the music", "stop the music", "stop music", "pause spotify":
            return .init(action: "pause", query: nil, value: nil)
        case "next", "next song", "next track", "skip", "skip song", "skip this song", "skip this":
            return .init(action: "next", query: nil, value: nil)
        case "previous", "previous song", "previous track", "last song":
            return .init(action: "previous", query: nil, value: nil)
        default:
            break
        }
        guard command.verb == "play" else { return nil }
        var query = command.rest
        // YouTube and videos belong to the browser (v3 playYouTube), not Spotify.
        guard !query.contains("youtube"), !query.contains("video") else { return nil }
        for suffix in [" on spotify", " in spotify"] where query.hasSuffix(suffix) {
            query.removeLast(suffix.count)
        }
        if query.hasSuffix(" playlist") {
            query.removeLast(" playlist".count)
            for prefix in ["my ", "the "] where query.hasPrefix(prefix) { query.removeFirst(prefix.count) }
            return query.isEmpty ? nil : .init(action: "playPlaylist", query: query, value: nil)
        }
        return .init(action: "playSong", query: query, value: nil)
    }

    private static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    /// Launches Spotify in the background and waits until it answers, up to
    /// 20 s. A just-launched Spotify ignored "play", so it isn't sent until
    /// Spotify reports a player state. Escape cancels the wait.
    private func launchIfNeeded() async throws {
        guard !Self.isRunning else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if (try? await playerState()) != nil {
                // Answering isn't quite ready to play; give it a moment.
                try await Task.sleep(for: .milliseconds(800))
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw ToolError("Spotify took too long to open")
    }

    /// Whether Spotify reports "playing" within about two seconds.
    private func becomesPlaying() async throws -> Bool {
        for _ in 0..<5 {
            try Task.checkCancellation()
            if try await playerState() == "playing" { return true }
            try await Task.sleep(for: .milliseconds(400))
        }
        return false
    }

    private func playerState() async throws -> String? {
        try await AppleScript.evaluate(
            "tell application id \"\(Self.bundleIdentifier)\" to get player state as string",
            controlling: "Spotify"
        ).first
    }

    private func tell(_ command: String) async throws {
        try await AppleScript.run("tell application id \"\(Self.bundleIdentifier)\" to \(command)", controlling: "Spotify")
    }

    private func openSearch(for query: String) async throws -> String {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
        guard let url = URL(string: "spotify:search:\(encoded)") else { throw ToolError("Couldn't search Spotify for that") }
        _ = try await NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
        return "Searched Spotify for “\(query)”"
    }
}
