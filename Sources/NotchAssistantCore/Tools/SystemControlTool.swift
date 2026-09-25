import AudioToolbox
import CoreAudio
import FoundationModels

@Generable
struct SystemControlArguments: Sendable {
    @Guide(description: "What to do", .anyOf([
        "volumeUp", "volumeDown", "setVolume", "mute", "unmute",
        "brightnessUp", "brightnessDown", "setBrightness",
        "doNotDisturbOn", "doNotDisturbOff", "lock", "sleep",
    ]))
    var action: String
    @Guide(description: "Percent from 0 to 100, only for setVolume or setBrightness")
    var value: Int?
}

/// Volume and mute through CoreAudio, sleep through System Events,
/// brightness and lock through simulated keys (Accessibility), and Do Not
/// Disturb through the user's shortcuts. No shell escape hatch (spec §9).
struct SystemControlTool: AssistantTool {
    let name = "systemControl"
    let title = "System"
    let symbol = "slider.horizontal.3"
    let keywords: Set<String> = ["volume", "sound", "mute", "unmute", "louder", "quieter", "loud", "quiet", "brightness", "brighter", "dim", "dimmer", "darker", "screen", "lock", "sleep", "disturb", "dnd", "focus"]
    let description = """
        Change this Mac's volume or screen brightness, turn Do Not Disturb on or off, lock the screen, or sleep. \
        "turn it down" → action "volumeDown". "set the volume to 30" → action "setVolume", value 30. \
        "make the screen brighter" → action "brightnessUp".
        """
    let requiresNetwork = false
    let permission = ToolPermission.varies
    let reversibility = Reversibility.notApplicable

    private static let step: Float = 0.1

    func target(of arguments: SystemControlArguments) -> String {
        switch arguments.action {
        case "setVolume": "Volume \(arguments.value.map { "\($0)%" } ?? "")"
        case "volumeUp": "Volume up"
        case "volumeDown": "Volume down"
        case "mute": "Mute"
        case "unmute": "Unmute"
        case "sleep": "Sleep"
        case "brightnessUp": "Brighter"
        case "brightnessDown": "Dimmer"
        case "setBrightness": "Brightness \(arguments.value.map { "\($0)%" } ?? "")"
        case "doNotDisturbOn": "Do Not Disturb on"
        case "doNotDisturbOff": "Do Not Disturb off"
        case "lock": "Lock screen"
        default: arguments.action
        }
    }

    /// Words that must appear before anything changes: given "Hi how are
    /// you", the model turned the volume down.
    private static let groundingWords: Set<String> = [
        "volume", "sound", "audio", "mute", "unmute", "louder", "quieter", "loud", "quiet", "turn", "sleep", "speakers",
        "brightness", "bright", "brighter", "dim", "dimmer", "darker", "screen", "display", "disturb", "focus", "lock", "dnd",
    ]

    func execute(_ arguments: SystemControlArguments) async throws -> ToolResult {
        if let transcript = CommandContext.transcript,
           !AppNameMatcher.normalize(transcript).split(separator: " ").contains(where: { Self.groundingWords.contains(String($0)) }) {
            throw ToolError("I didn't catch what to change")
        }
        try Task.checkCancellation()
        switch arguments.action {
        case "volumeUp":
            let volume = try SystemAudio.setVolume(SystemAudio.volume() + Self.step)
            return "Volume \(Int((volume * 100).rounded()))%"
        case "volumeDown":
            let volume = try SystemAudio.setVolume(SystemAudio.volume() - Self.step)
            return "Volume \(Int((volume * 100).rounded()))%"
        case "setVolume":
            guard let value = arguments.value else { throw ToolError("What volume should I set?") }
            let volume = try SystemAudio.setVolume(Float(value) / 100)
            return "Volume \(Int((volume * 100).rounded()))%"
        case "mute":
            try SystemAudio.setMuted(true)
            return "Muted"
        case "unmute":
            try SystemAudio.setMuted(false)
            return "Unmuted"
        case "brightnessUp":
            try await SystemKeys.adjust(.up(steps: 2))
            return "Brighter"
        case "brightnessDown":
            try await SystemKeys.adjust(.down(steps: 2))
            return "Dimmer"
        case "setBrightness":
            guard let value = arguments.value, (0...100).contains(value) else { throw ToolError("What brightness should I set?") }
            try await SystemKeys.adjust(.set(Double(value) / 100))
            return "Brightness \(value)%"
        case "doNotDisturbOn":
            try await Shortcuts.setDoNotDisturb(.on)
            return "Do Not Disturb on"
        case "doNotDisturbOff":
            try await Shortcuts.setDoNotDisturb(.off)
            return "Do Not Disturb off"
        case "lock":
            // Like sleep: let the notch show the result first.
            try SystemKeys.ensureTrusted()
            Task {
                try? await Task.sleep(for: .seconds(1))
                try? await SystemKeys.lockScreen()
            }
            return "Locking"
        case "sleep":
            // Leave a moment for the notch to show the result first.
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                try? await AppleScript.run("tell application \"System Events\" to sleep", controlling: "System Events")
            }
            return "Going to sleep"
        default:
            throw ToolError("I can't do \"\(arguments.action)\" yet")
        }
    }

    func directArguments(for command: DirectCommand) -> SystemControlArguments? {
        // "DND" is how people say Do Not Disturb.
        let text = (" " + command.text + " ")
            .replacingOccurrences(of: " dnd ", with: " do not disturb ")
            .trimmingCharacters(in: .whitespaces)
        switch text {
        case "mute", "mute the sound", "mute sound", "mute the volume", "mute audio":
            return .init(action: "mute", value: nil)
        case "unmute", "unmute the sound", "unmute sound", "unmute the volume", "unmute audio":
            return .init(action: "unmute", value: nil)
        case "volume up", "turn the volume up", "turn up the volume", "turn it up", "louder":
            return .init(action: "volumeUp", value: nil)
        case "volume down", "turn the volume down", "turn down the volume", "turn it down", "quieter":
            return .init(action: "volumeDown", value: nil)
        case "go to sleep", "put the mac to sleep", "put my mac to sleep", "sleep the mac", "sleep now":
            return .init(action: "sleep", value: nil)
        case "brighter", "brightness up", "increase brightness", "increase the brightness", "turn up the brightness",
             "turn the brightness up", "make the screen brighter", "make it brighter":
            return .init(action: "brightnessUp", value: nil)
        case "dimmer", "darker", "brightness down", "decrease brightness", "decrease the brightness", "turn down the brightness",
             "turn the brightness down", "dim the screen", "make the screen darker", "make it darker":
            return .init(action: "brightnessDown", value: nil)
        case "max brightness", "maximum brightness", "full brightness":
            return .init(action: "setBrightness", value: 100)
        case "lock", "lock the screen", "lock screen", "lock my mac", "lock the mac", "lock my screen", "lock the computer":
            return .init(action: "lock", value: nil)
        case "turn on do not disturb", "do not disturb on", "enable do not disturb", "do not disturb", "don t disturb me",
             "turn on focus", "focus mode on":
            return .init(action: "doNotDisturbOn", value: nil)
        case "turn off do not disturb", "do not disturb off", "disable do not disturb", "turn off focus", "focus mode off":
            return .init(action: "doNotDisturbOff", value: nil)
        default:
            break
        }
        // "set the volume to 40", "volume 40", "volume to 40 percent"
        let words = text.split(separator: " ").map(String.init).filter { !["set", "the", "to", "percent", "at"].contains($0) }
        if words.count == 2, words[0] == "volume", let value = Int(words[1]), (0...100).contains(value) {
            return .init(action: "setVolume", value: value)
        }
        // "set the brightness to 60", "brightness 60"
        if words.count == 2, words[0] == "brightness", let value = Int(words[1]), (0...100).contains(value) {
            return .init(action: "setBrightness", value: value)
        }
        return nil
    }
}

/// The default output device's volume and mute, via CoreAudio.
enum SystemAudio {
    static func volume() throws -> Float {
        var address = mainVolumeAddress
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let device = try outputDevice()
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr
        else { throw noVolumeControl }
        return volume
    }

    /// Returns the volume actually set, clamped to 0...1. Setting a
    /// non-zero volume unmutes, as the volume keys do, unless told not to.
    @discardableResult
    static func setVolume(_ volume: Float, unmute: Bool = true) throws -> Float {
        var address = mainVolumeAddress
        var value = Float32(min(max(volume, 0), 1))
        let device = try outputDevice()
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue,
              AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
        else { throw noVolumeControl }
        if unmute, value > 0 { try? setMuted(false) }
        return value
    }

    static func setMuted(_ muted: Bool) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = UInt32(muted ? 1 : 0)
        let device = try outputDevice()
        guard AudioObjectHasProperty(device, &address),
              AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
        else { throw ToolError("This output device can't be muted") }
    }

    private static var mainVolumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static let noVolumeControl = ToolError("This output device's volume can't be changed from the Mac")

    private static func outputDevice() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0
        else { throw ToolError("There's no sound output device") }
        return device
    }
}
