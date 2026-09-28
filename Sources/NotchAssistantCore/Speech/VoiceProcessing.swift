@preconcurrency import AVFoundation

/// Apple's voice processing on the microphone: echo cancellation (music or
/// a video playing from the Mac is removed from what Alfred hears) and
/// noise suppression (fans, hum). Used for the wake word, commands and
/// dictation; not for meeting transcripts, where it could drop other
/// people's voices. A setting, on by default.
public enum VoiceProcessing {
    public static let key = "audio.voiceProcessing"
    public static var isEnabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// Call before reading the input format or installing a tap. Returns
    /// true when voice processing is on: the input then has several
    /// identical channels of the processed voice (seven on an M4 Air), and
    /// taps should take `voice(of:)`.
    @discardableResult
    static func prepare(_ node: AVAudioInputNode, wanted: Bool = isEnabled) -> Bool {
        guard wanted else {
            if node.isVoiceProcessingEnabled { try? node.setVoiceProcessingEnabled(false) }
            return false
        }
        if !node.isVoiceProcessingEnabled {
            do {
                try node.setVoiceProcessingEnabled(true)
            } catch {
                Log.speech.notice("voice processing unavailable: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        // Don't turn the user's music down: Alfred ducks it itself while
        // listening, only when needed.
        node.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
            enableAdvancedDucking: false, duckingLevel: .min
        )
        return true
    }

    /// The processed voice as one channel (the first; with voice processing
    /// the channels carry the same signal).
    static func voice(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.format.channelCount > 1 else { return buffer.copied() }
        guard let source = buffer.floatChannelData,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate, channels: 1, interleaved: false),
              let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let destination = mono.floatChannelData else { return nil }
        mono.frameLength = buffer.frameLength
        destination[0].update(from: source[0], count: Int(buffer.frameLength))
        return mono
    }

    /// The format `voice(of:)` produces for this input format.
    static func voiceFormat(for format: AVAudioFormat) -> AVAudioFormat {
        guard format.channelCount > 1 else { return format }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false) ?? format
    }
}
