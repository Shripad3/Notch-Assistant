import Foundation

/// Lowers the Mac's output volume while the microphone listens, so music
/// from the speakers doesn't drown out the command (spec §7, "duck other
/// audio during capture rather than pausing it"). Music playing at full
/// volume produced empty transcripts, or only the tail of a command.
///
/// The original volume is saved to UserDefaults before lowering, so a crash
/// mid-command can't leave the Mac quiet: `recoverIfNeeded()` restores it at
/// the next launch.
enum AudioDucker {
    static let enabledKey = "audio.duckWhileListening"
    private static let savedVolumeKey = "audio.duckedFromVolume"
    private static let duckedToKey = "audio.duckedToVolume"
    /// Fraction of the current volume kept while listening.
    private static let duckFactor: Float = 0.3

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static func duck() {
        guard isEnabled, UserDefaults.standard.object(forKey: savedVolumeKey) == nil,
              let volume = try? SystemAudio.volume(), volume > 0.05,
              let lowered = try? SystemAudio.setVolume(volume * duckFactor, unmute: false)
        else { return }
        UserDefaults.standard.set(volume, forKey: savedVolumeKey)
        UserDefaults.standard.set(lowered, forKey: duckedToKey)
    }

    /// Instant rather than faded: it runs before the command executes, and a
    /// fade still in progress would override "set the volume to 50".
    static func restore() {
        let defaults = UserDefaults.standard
        guard let saved = defaults.object(forKey: savedVolumeKey) as? Float else { return }
        let duckedTo = defaults.object(forKey: duckedToKey) as? Float
        defaults.removeObject(forKey: savedVolumeKey)
        defaults.removeObject(forKey: duckedToKey)
        // If the user changed the volume meanwhile, leave their choice alone.
        if let current = try? SystemAudio.volume(), let duckedTo, abs(current - duckedTo) > 0.02 { return }
        _ = try? SystemAudio.setVolume(saved, unmute: false)
    }

    /// Call at launch: restores the volume if the app quit while ducked.
    static func recoverIfNeeded() {
        if UserDefaults.standard.object(forKey: savedVolumeKey) != nil {
            Log.speech.notice("restoring volume left lowered by a previous session")
            restore()
        }
    }
}
