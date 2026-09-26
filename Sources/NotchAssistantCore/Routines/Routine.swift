import Foundation
import FoundationModels

/// A named set of steps started by a phrase: "I'm home", "good night".
/// Written by the user in Settings, so it runs without the model and without
/// grounding checks. Steps go through the ordinary tools, with their safety
/// checks; file changes are deliberately not a step type.
public struct Routine: Codable, Identifiable, Sendable, Equatable, Hashable {
    public var id = UUID()
    public var name: String
    /// Phrases that start it, e.g. "I'm home", "I am home".
    public var triggers: [String]
    public var steps: [RoutineStep]
    /// Spoken when it finishes, e.g. "Welcome home". Empty: a short summary.
    public var response: String
    public var enabled = true

    public init(name: String, triggers: [String], steps: [RoutineStep], response: String = "") {
        self.name = name
        self.triggers = triggers
        self.steps = steps
        self.response = response
    }
}

public struct RoutineStep: Codable, Identifiable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case openApp, openWebsite, playMusic, playPlaylist, playSong, pauseMusic, runShortcut
        case setVolume, setBrightness, doNotDisturbOn, doNotDisturbOff, mute, unmute, lockScreen

        public var title: String {
            switch self {
            case .openApp: "Open app"
            case .openWebsite: "Open website"
            case .playMusic: "Play music"
            case .playPlaylist: "Play playlist"
            case .playSong: "Play song"
            case .pauseMusic: "Pause music"
            case .runShortcut: "Run shortcut"
            case .setVolume: "Set volume"
            case .setBrightness: "Set brightness"
            case .doNotDisturbOn: "Do Not Disturb on"
            case .doNotDisturbOff: "Do Not Disturb off"
            case .mute: "Mute"
            case .unmute: "Unmute"
            case .lockScreen: "Lock screen"
            }
        }

        /// The label of the text the step needs, if any.
        public var textLabel: String? {
            switch self {
            case .openApp: "App"
            case .openWebsite: "Address"
            case .playPlaylist: "Playlist"
            case .playSong: "Song"
            case .runShortcut: "Shortcut name"
            default: nil
            }
        }

        public var takesPercent: Bool { self == .setVolume || self == .setBrightness }
    }

    public var id = UUID()
    public var kind: Kind
    public var text = ""
    public var percent = 50

    public init(_ kind: Kind, text: String = "", percent: Int = 50) {
        self.kind = kind
        self.text = text
        self.percent = percent
    }

    public var summary: String {
        if let _ = kind.textLabel { return "\(kind.title): \(text)" }
        if kind.takesPercent { return "\(kind.title) to \(percent)%" }
        return kind.title
    }

    /// The tool and its arguments, as if the user had asked for this step.
    func invocation() -> (tool: String, arguments: GeneratedContent)? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if kind.textLabel != nil, text.isEmpty { return nil }
        let percent = min(max(percent, 0), 100)
        switch kind {
        case .openApp: return ("openApp", OpenAppArguments(appName: text).generatedContent)
        case .openWebsite: return ("openURL", OpenURLArguments(url: text, browser: nil).generatedContent)
        case .playMusic: return ("controlSpotify", ControlSpotifyArguments(action: "play", query: nil, value: nil).generatedContent)
        case .playPlaylist: return ("controlSpotify", ControlSpotifyArguments(action: "playPlaylist", query: text, value: nil).generatedContent)
        case .playSong: return ("controlSpotify", ControlSpotifyArguments(action: "playSong", query: text, value: nil).generatedContent)
        case .pauseMusic: return ("controlSpotify", ControlSpotifyArguments(action: "pause", query: nil, value: nil).generatedContent)
        case .runShortcut: return ("runShortcut", RunShortcutArguments(name: text).generatedContent)
        case .setVolume: return ("systemControl", SystemControlArguments(action: "setVolume", value: percent).generatedContent)
        case .setBrightness: return ("systemControl", SystemControlArguments(action: "setBrightness", value: percent).generatedContent)
        case .doNotDisturbOn: return ("systemControl", SystemControlArguments(action: "doNotDisturbOn", value: nil).generatedContent)
        case .doNotDisturbOff: return ("systemControl", SystemControlArguments(action: "doNotDisturbOff", value: nil).generatedContent)
        case .mute: return ("systemControl", SystemControlArguments(action: "mute", value: nil).generatedContent)
        case .unmute: return ("systemControl", SystemControlArguments(action: "unmute", value: nil).generatedContent)
        case .lockScreen: return ("systemControl", SystemControlArguments(action: "lock", value: nil).generatedContent)
        }
    }
}

/// Stores routines, recognises their phrases, and turns one into a plan.
public enum Routines {
    public static let defaultsKey = "routines"

    public static var all: [Routine] {
        get {
            UserDefaults.standard.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode([Routine].self, from: $0) } ?? []
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: defaultsKey)
        }
    }

    /// The routine a short command asks for: one of its phrases, said on its
    /// own or with a couple of extra words ("hey, I'm home now"). Long
    /// sentences that merely contain a phrase don't trigger it.
    public static func match(_ transcript: String, in routines: [Routine] = all) -> Routine? {
        let said = AppNameMatcher.normalize(transcript).split(separator: " ").count
        for routine in routines where routine.enabled {
            for trigger in routine.triggers {
                let phrase = trigger.trimmingCharacters(in: .whitespaces)
                let length = AppNameMatcher.normalize(phrase).split(separator: " ").count
                guard length > 0, said <= length + 2, Grounding.mentions(phrase, in: transcript) else { continue }
                return routine
            }
        }
        return nil
    }

    /// Steps whose tool is turned off are skipped and reported.
    public static func plan(for routine: Routine, tools: [AnyAssistantTool]) -> Plan {
        var steps: [PlannedStep] = []
        var skipped: [String] = []
        for step in routine.steps {
            guard let (name, arguments) = step.invocation(), let tool = tools.first(where: { $0.name == name }) else {
                skipped.append(step.summary)
                continue
            }
            steps.append(PlannedStep(tool: tool, arguments: arguments, transcript: nil))
        }
        let closing = routine.response.trimmingCharacters(in: .whitespaces)
        return Plan(steps: steps, isDirect: true, routine: RoutineRun(name: routine.name, closing: closing.isEmpty ? nil : closing, skipped: skipped))
    }

    /// Ready-made examples offered in Settings.
    public static let examples: [Routine] = [
        Routine(name: "I'm home", triggers: ["I'm home", "I am home"], steps: [
            RoutineStep(.runShortcut, text: "Lights On"),
            RoutineStep(.playPlaylist, text: "Liked Songs"),
            RoutineStep(.openApp, text: "Visual Studio Code"),
        ], response: "Welcome home."),
        Routine(name: "Good night", triggers: ["good night", "goodnight", "going to bed"], steps: [
            RoutineStep(.pauseMusic),
            RoutineStep(.runShortcut, text: "Lights Off"),
            RoutineStep(.doNotDisturbOn),
            RoutineStep(.lockScreen),
        ], response: "Good night."),
        Routine(name: "Focus", triggers: ["focus mode", "time to focus", "work mode"], steps: [
            RoutineStep(.doNotDisturbOn),
            RoutineStep(.setVolume, percent: 30),
            RoutineStep(.playPlaylist, text: "Deep Focus"),
        ], response: "Focus mode on."),
    ]
}
