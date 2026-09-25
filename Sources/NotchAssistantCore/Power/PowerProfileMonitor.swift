import Foundation
import IOKit.ps

/// Power and thermal state, and what it allows (spec §11). On a fanless Air
/// the ceiling is heat, not battery; both pause the wake word, never the
/// hotkey.
public enum PowerProfile: Sendable, Equatable {
    case pluggedIn
    case battery
    case lowPowerMode
    case thermalPressure

    public var allowsWakeWord: Bool { self == .pluggedIn }

    public var pauseReason: String? {
        switch self {
        case .pluggedIn: nil
        case .battery: "on battery"
        case .lowPowerMode: "Low Power Mode is on"
        case .thermalPressure: "the Mac is running hot"
        }
    }

    /// Thermal pressure outranks everything; then Low Power Mode; then power
    /// source.
    public static func resolve(isPluggedIn: Bool, lowPowerMode: Bool, thermal: ProcessInfo.ThermalState) -> PowerProfile {
        if thermal == .serious || thermal == .critical { return .thermalPressure }
        if lowPowerMode { return .lowPowerMode }
        return isPluggedIn ? .pluggedIn : .battery
    }
}

/// Watches power source, Low Power Mode and thermal state, by notification.
@MainActor
public final class PowerProfileMonitor {
    public static let autoSwitchKey = "power.autoSwitch"

    public private(set) var profile: PowerProfile
    public var onChange: (() -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var powerSource: CFRunLoopSource?

    public init() {
        profile = Self.current()
        let center = NotificationCenter.default
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let address = UInt(bitPattern: context)
            Task { @MainActor in
                guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
                Unmanaged<PowerProfileMonitor>.fromOpaque(pointer).takeUnretainedValue().refresh()
            }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
    }

    /// Whether the user lets profiles switch automatically (default on).
    public static var autoSwitch: Bool {
        UserDefaults.standard.object(forKey: autoSwitchKey) as? Bool ?? true
    }

    private func refresh() {
        let next = Self.current()
        guard next != profile else { return }
        profile = next
        Log.app.notice("power profile: \(String(describing: next), privacy: .public)")
        onChange?()
    }

    private static func current() -> PowerProfile {
        let info = ProcessInfo.processInfo
        return PowerProfile.resolve(isPluggedIn: isPluggedIn(), lowPowerMode: info.isLowPowerModeEnabled, thermal: info.thermalState)
    }

    private static func isPluggedIn() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue()
        else { return true } // A Mac without a battery reports nothing: treat as mains.
        return (type as String) == kIOPSACPowerValue
    }
}
