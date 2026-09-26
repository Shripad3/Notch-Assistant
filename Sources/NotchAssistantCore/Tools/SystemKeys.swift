import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Simulated key presses for controls with no public API: display
/// brightness (the brightness keys) and locking the screen (⌃⌘Q). Posting
/// events needs the Accessibility permission (spec §10).
enum SystemKeys {
    /// macOS moves built-in display brightness in 16 steps per key press.
    static let brightnessSteps = 16

    static func ensureTrusted() throws {
        guard !AXIsProcessTrusted() else { return }
        // Shows macOS's prompt, which leads to the Accessibility pane.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        throw AssistantFailure("Notch Assistant needs Accessibility to press keys for you", link: .accessibility)
    }

    enum Brightness {
        case up(steps: Int)
        case down(steps: Int)
        /// A level from 0 to 1. There is no public way to read brightness, so
        /// this goes to the bottom first and counts up from there.
        case set(Double)
    }

    static func adjust(_ change: Brightness) async throws {
        try ensureTrusted()
        let presses: [(key: Int32, count: Int)] = switch change {
        case .up(let steps): [(Int32(NX_KEYTYPE_BRIGHTNESS_UP), steps)]
        case .down(let steps): [(Int32(NX_KEYTYPE_BRIGHTNESS_DOWN), steps)]
        case .set(let level):
            [
                (Int32(NX_KEYTYPE_BRIGHTNESS_DOWN), brightnessSteps),
                // At least one step: fully down turns the backlight off.
                (Int32(NX_KEYTYPE_BRIGHTNESS_UP), max(1, Int((min(max(level, 0), 1) * Double(brightnessSteps)).rounded()))),
            ]
        }
        for press in presses {
            for _ in 0..<press.count {
                try Task.checkCancellation()
                await MainActor.run { postSystemKey(press.key) }
                try await Task.sleep(for: .milliseconds(12))
            }
        }
    }

    static func lockScreen() async throws {
        try ensureTrusted()
        await MainActor.run {
            let source = CGEventSource(stateID: .hidSystemState)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_Q), keyDown: down)
                event?.flags = [.maskCommand, .maskControl]
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    /// A "system defined" media key event (subtype 8), as the keyboard's
    /// function row sends: key code in the top half of data1, then the
    /// key-down (0xA) or key-up (0xB) state.
    @MainActor
    private static func postSystemKey(_ key: Int32) {
        for state in [0xA, 0xB] {
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: Int((key << 16) | Int32(state << 8)),
                data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

/// Runs the user's own shortcuts from the Shortcuts app, silently, through
/// the "Shortcuts Events" helper (Apple Events, not a shell). Used for Do Not
/// Disturb, which has no key event and no public API.
enum Shortcuts {
    enum Switch { case on, off }

    /// Finds the user's Do Not Disturb shortcut by name ("DND On", "Do Not
    /// Disturb Off", …) rather than demanding an exact name, then runs it.
    static func setDoNotDisturb(_ state: Switch) async throws {
        let names = try await AppleScript.evaluate(
            "tell application id \"com.apple.shortcuts.events\" to get name of every shortcut",
            controlling: "Shortcuts"
        )
        guard let name = doNotDisturbShortcut(state, among: names) else {
            let example = state == .on ? "DND On" : "DND Off"
            throw ToolError("I need a shortcut called something like “\(example)”. See Settings › Capabilities")
        }
        try await AppleScript.run(
            "tell application id \"com.apple.shortcuts.events\" to run the shortcut named \(AppleScript.quoted(name))",
            controlling: "Shortcuts"
        )
    }

    /// Runs the user's shortcut whose name matches (exact first, then close
    /// spelling), and returns its real name.
    static func run(named spoken: String) async throws -> String {
        let names = try await AppleScript.evaluate(
            "tell application id \"com.apple.shortcuts.events\" to get name of every shortcut",
            controlling: "Shortcuts"
        )
        guard let name = AppNameMatcher.match(spoken, candidates: names, aliases: [:]) else {
            throw ToolError("I couldn't find a shortcut called “\(spoken)” in the Shortcuts app")
        }
        try await AppleScript.run(
            "tell application id \"com.apple.shortcuts.events\" to run the shortcut named \(AppleScript.quoted(name))",
            controlling: "Shortcuts"
        )
        return name
    }

    /// A name that mentions Do Not Disturb (or DND) and the wanted state as a
    /// whole word. Pure, for testing.
    static func doNotDisturbShortcut(_ state: Switch, among names: [String]) -> String? {
        let wanted = state == .on ? "on" : "off"
        let other = state == .on ? "off" : "on"
        return names.first { name in
            let words = AppNameMatcher.normalize(name).split(separator: " ").map(String.init)
            let joined = " " + words.joined(separator: " ") + " "
            let isDoNotDisturb = joined.contains(" do not disturb ") || words.contains("dnd")
            return isDoNotDisturb && words.contains(wanted) && !words.contains(other)
        }
    }
}
