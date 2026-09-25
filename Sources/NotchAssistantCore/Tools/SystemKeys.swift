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
    static let doNotDisturbOn = "Alfred: Do Not Disturb On"
    static let doNotDisturbOff = "Alfred: Do Not Disturb Off"

    static func run(_ name: String) async throws {
        do {
            try await AppleScript.run(
                "tell application id \"com.apple.shortcuts.events\" to run the shortcut named \(AppleScript.quoted(name))",
                controlling: "Shortcuts"
            )
        } catch let error as ToolError where error.message.contains("didn't accept") {
            throw ToolError("I need a shortcut named “\(name)”. See Settings › Capabilities")
        }
    }
}
