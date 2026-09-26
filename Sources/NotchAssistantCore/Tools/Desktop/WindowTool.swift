import AppKit
import ApplicationServices
import FoundationModels

@Generable
struct WindowArguments: Sendable {
    @Guide(description: "Where the window goes", .anyOf(["leftHalf", "rightHalf", "topHalf", "bottomHalf", "maximize", "center", "fullScreen", "exitFullScreen", "minimize", "nextDisplay"]))
    var action: String
    @Guide(description: "App name, only if the user named one, e.g. \"Safari\"; otherwise the front window")
    var app: String?
}

/// Arranges the front window, or a named app's: halves, maximise, centre,
/// full screen, minimise, or the other display. Through Accessibility, like
/// a window manager; nothing is closed or quit.
struct WindowTool: AssistantTool {
    let name = "arrangeWindow"
    let title = "Window"
    let symbol = "macwindow"
    let keywords: Set<String> = ["window", "left", "right", "half", "side", "maximize", "maximise", "fullscreen", "full", "center", "centre", "minimize", "minimise", "display", "monitor", "tile", "snap"]
    let description = """
        Move or resize a window. "put Safari on the left half" → leftHalf, app "Safari". \
        "make this full screen" → fullScreen. "move this window to the other display" → nextDisplay.
        """
    let requiresNetwork = false
    let permission = ToolPermission.accessibility
    let reversibility = Reversibility.notApplicable

    func target(of arguments: WindowArguments) -> String {
        [arguments.app, WindowLayout.describe(arguments.action)].compactMap { $0 }.joined(separator: " · ")
    }

    func execute(_ arguments: WindowArguments) async throws -> ToolResult {
        try SystemKeys.ensureTrusted()
        let spoken = ClockPhrases.grounded(arguments.app)
        return try await MainActor.run {
            let app = try Self.targetApp(spoken)
            guard let window = Self.window(of: app) else {
                throw ToolError("\(app.localizedName ?? "That app") has no window to move")
            }
            if spoken != nil { app.activate() }
            try WindowLayout.apply(arguments.action, to: window)
            return ToolResult("\(app.localizedName ?? "Window"): \(WindowLayout.describe(arguments.action))")
        }
    }

    @MainActor
    private static func targetApp(_ spoken: String?) throws -> NSRunningApplication {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        if let spoken {
            let names = running.compactMap(\.localizedName)
            guard let name = AppNameMatcher.match(spoken, candidates: names),
                  let app = running.first(where: { $0.localizedName == name }) else {
                throw ToolError("\(spoken) isn't open")
            }
            return app
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { throw ToolError("There's no window in front") }
        return app
    }

    @MainActor
    private static func window(of app: NSRunningApplication) -> AXUIElement? {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value {
                return (value as! AXUIElement)
            }
        }
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows) == .success,
              let list = windows as? [AXUIElement] else { return nil }
        return list.first
    }

    private static let positions: [(words: [String], action: String)] = [
        (["left half"], "leftHalf"), (["left side"], "leftHalf"), (["to the left"], "leftHalf"), (["on the left"], "leftHalf"),
        (["right half"], "rightHalf"), (["right side"], "rightHalf"), (["to the right"], "rightHalf"), (["on the right"], "rightHalf"),
        (["top half"], "topHalf"), (["bottom half"], "bottomHalf"),
        (["exit full screen"], "exitFullScreen"), (["leave full screen"], "exitFullScreen"), (["exit fullscreen"], "exitFullScreen"),
        (["full screen"], "fullScreen"), (["fullscreen"], "fullScreen"),
        (["maximize"], "maximize"), (["maximise"], "maximize"), (["fill the screen"], "maximize"),
        (["minimize"], "minimize"), (["minimise"], "minimize"),
        (["other screen"], "nextDisplay"), (["other display"], "nextDisplay"), (["other monitor"], "nextDisplay"),
        (["next screen"], "nextDisplay"), (["next display"], "nextDisplay"), (["external display"], "nextDisplay"), (["external monitor"], "nextDisplay"),
        (["center"], "center"), (["centre"], "center"),
    ]
    private static let verbs: Set<String> = ["put", "move", "snap", "tile", "send", "make", "set", "throw", "push", "place", "drag"]
    private static let filler: Set<String> = [
        "put", "move", "snap", "tile", "send", "make", "set", "throw", "push", "place", "drag", "the", "this", "that", "my", "window",
        "windows", "to", "on", "of", "in", "a", "it", "screen", "display", "monitor", "half", "side", "left", "right", "top", "bottom",
        "full", "fullscreen", "maximize", "maximise", "minimize", "minimise", "center", "centre", "other", "next", "external", "exit",
        "leave", "fill", "app", "please", "and",
    ]

    /// "put Safari on the left half", "maximize this window", "full screen",
    /// "move this to the other display", "center the window".
    func directArguments(for command: DirectCommand) -> WindowArguments? {
        guard !["open", "launch", "play", "watch", "search", "search for", "google", "look up", "go to"].contains(command.verb) else { return nil }
        let text = " \(command.text) "
        guard let match = Self.positions.first(where: { entry in entry.words.contains { text.contains(" \($0) ") } }) else { return nil }
        let words = command.text.split(separator: " ").map(String.init)
        // Directions and "center" need a window verb or the word "window":
        // "what's on the left" is not a window command.
        let needsVerb = ["leftHalf", "rightHalf", "center"].contains(match.action) && !text.contains(" half ")
        if needsVerb, !(Self.verbs.contains(words.first ?? "") || words.contains("window")) { return nil }
        let rest = words.filter { !Self.filler.contains($0) }
        guard rest.count <= 3 else { return nil }
        return WindowArguments(action: match.action, app: rest.isEmpty ? nil : rest.joined(separator: " "))
    }
}

/// Window frames, in AppKit coordinates (origin bottom left) until applied.
enum WindowLayout {
    static func describe(_ action: String) -> String {
        switch action {
        case "leftHalf": "left half"
        case "rightHalf": "right half"
        case "topHalf": "top half"
        case "bottomHalf": "bottom half"
        case "maximize": "maximised"
        case "center": "centred"
        case "fullScreen": "full screen"
        case "exitFullScreen": "out of full screen"
        case "minimize": "minimised"
        case "nextDisplay": "moved to the other display"
        default: action
        }
    }

    /// The frame for a placement within a screen's visible area (menu bar
    /// and Dock excluded). Nil for actions that aren't a frame.
    static func frame(for action: String, in visible: CGRect, current: CGRect) -> CGRect? {
        let v = visible
        switch action {
        case "leftHalf": return CGRect(x: v.minX, y: v.minY, width: v.width / 2, height: v.height)
        case "rightHalf": return CGRect(x: v.midX, y: v.minY, width: v.width / 2, height: v.height)
        case "topHalf": return CGRect(x: v.minX, y: v.midY, width: v.width, height: v.height / 2)
        case "bottomHalf": return CGRect(x: v.minX, y: v.minY, width: v.width, height: v.height / 2)
        case "maximize": return v
        case "center":
            let size = CGSize(width: min(current.width, v.width), height: min(current.height, v.height))
            return CGRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2, width: size.width, height: size.height)
        default: return nil
        }
    }

    /// The same relative place on another screen.
    static func moved(_ frame: CGRect, from source: CGRect, to destination: CGRect) -> CGRect {
        let sx = destination.width / source.width, sy = destination.height / source.height
        return CGRect(
            x: destination.minX + (frame.minX - source.minX) * sx,
            y: destination.minY + (frame.minY - source.minY) * sy,
            width: frame.width * sx,
            height: frame.height * sy
        )
    }

    /// AppKit's bottom-left origin ↔ Accessibility's top-left origin, both
    /// relative to the primary screen. The conversion is its own inverse.
    static func flipped(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    @MainActor
    static func apply(_ action: String, to window: AXUIElement) throws {
        switch action {
        case "fullScreen", "exitFullScreen":
            set(window, "AXFullScreen", (action == "fullScreen" ? kCFBooleanTrue : kCFBooleanFalse)!)
            return
        case "minimize":
            set(window, kAXMinimizedAttribute, kCFBooleanTrue!)
            return
        default:
            break
        }
        guard let primary = NSScreen.screens.first, let current = frame(of: window) else {
            throw ToolError("I couldn't read that window's position")
        }
        let appKitFrame = flipped(current, primaryHeight: primary.frame.height)
        let screens = NSScreen.screens
        let index = screens.firstIndex { $0.frame.contains(CGPoint(x: appKitFrame.midX, y: appKitFrame.midY)) } ?? 0
        let screen = screens[index]
        let target: CGRect
        if action == "nextDisplay" {
            guard screens.count > 1 else { throw ToolError("There's only one display") }
            let next = screens[(index + 1) % screens.count]
            target = moved(appKitFrame, from: screen.visibleFrame, to: next.visibleFrame)
        } else {
            guard let placed = frame(for: action, in: screen.visibleFrame, current: appKitFrame) else {
                throw ToolError("I don't know how to do that with a window")
            }
            target = placed
        }
        let ax = flipped(target, primaryHeight: primary.frame.height)
        var origin = ax.origin
        var size = ax.size
        // Position, size, then position again: some apps clamp the size to
        // the screen they're on before the move lands.
        let position = AXValueCreate(.cgPoint, &origin)!
        set(window, kAXPositionAttribute, position)
        set(window, kAXSizeAttribute, AXValueCreate(.cgSize, &size)!)
        set(window, kAXPositionAttribute, position)
    }

    @MainActor
    private static func frame(of window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    @MainActor
    private static func set(_ window: AXUIElement, _ attribute: String, _ value: CFTypeRef) {
        AXUIElementSetAttributeValue(window, attribute as CFString, value)
    }
}
