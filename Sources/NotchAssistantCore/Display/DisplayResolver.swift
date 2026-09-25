import AppKit

/// What the resolver needs to know about a screen. Separate from NSScreen so
/// the choice can be tested with fake screen lists.
public struct ScreenDescriptor: Sendable, Equatable {
    public let displayID: CGDirectDisplayID
    public let topSafeAreaInset: CGFloat
    public let isBuiltin: Bool

    public init(displayID: CGDirectDisplayID, topSafeAreaInset: CGFloat, isBuiltin: Bool) {
        self.displayID = displayID
        self.topSafeAreaInset = topSafeAreaInset
        self.isBuiltin = isBuiltin
    }
}

/// What to do when there is no notched built-in screen (spec §5).
public enum DisplayFallback: String, CaseIterable, Sendable {
    /// UI disappears; the hotkey still works.
    case hide
    /// Floating panel on the primary external display.
    case floating
    /// The assistant suspends until the built-in display returns.
    case disable

    public static let defaultsKey = "display.fallback"

    public static var current: DisplayFallback {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(DisplayFallback.init(rawValue:)) ?? .hide
    }

    public var title: String {
        switch self {
        case .hide: "Hide"
        case .floating: "Floating panel on the external display"
        case .disable: "Disable the assistant"
        }
    }
}

/// Finds the built-in notched screen and follows it across monitor changes.
///
/// Never uses `NSScreen.main`: that follows keyboard focus to an external
/// monitor. Never holds an NSScreen either, since those are invalidated by
/// reconfiguration; only the display ID is kept, and `targetScreen` is looked
/// up fresh on every read.
@MainActor
public final class DisplayResolver {
    public private(set) var targetDisplayID: CGDirectDisplayID?
    /// Called after a debounced change, on the main actor.
    public var onChange: (() -> Void)?

    /// Written once in init, read in deinit; NotificationCenter is thread-safe.
    nonisolated(unsafe) private var observer: NSObjectProtocol?
    private var debounce: Task<Void, Never>?

    public init() {
        targetDisplayID = Self.resolve(Self.describeScreens())
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.screensChanged() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// The built-in notched screen, or nil when it is unavailable (lid
    /// closed, display asleep).
    public var targetScreen: NSScreen? {
        guard let targetDisplayID else { return nil }
        return NSScreen.screens.first { $0.displayID == targetDisplayID }
    }

    /// The primary external display, for the floating fallback. Only
    /// meaningful when there is no target screen.
    public var fallbackScreen: NSScreen? {
        NSScreen.screens.first { CGDisplayIsBuiltin($0.displayID ?? 0) == 0 } ?? NSScreen.screens.first
    }

    /// Primary signal: a non-zero top safe-area inset, which only a notched
    /// display has. Fallback: the display reports itself built in.
    public nonisolated static func resolve(_ screens: [ScreenDescriptor]) -> CGDirectDisplayID? {
        screens.first { $0.topSafeAreaInset > 0 }?.displayID
            ?? screens.first { $0.isBuiltin }?.displayID
    }

    /// The notification fires several times while the system settles, so act
    /// only after 300 ms of quiet.
    private func screensChanged() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            let resolved = Self.resolve(Self.describeScreens())
            Log.app.info("screens changed; built-in display \(resolved.map(String.init) ?? "unavailable", privacy: .public)")
            self.targetDisplayID = resolved
            self.onChange?()
        }
    }

    private static func describeScreens() -> [ScreenDescriptor] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            return ScreenDescriptor(
                displayID: id,
                topSafeAreaInset: screen.safeAreaInsets.top,
                isBuiltin: CGDisplayIsBuiltin(id) != 0
            )
        }
    }
}

extension NSScreen {
    public var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
