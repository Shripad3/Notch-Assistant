import AppKit
import FoundationModels
@preconcurrency import ScreenCaptureKit

/// Where macOS saves screenshots (Screenshot app › Options), else Desktop.
enum CaptureFolder {
    static var url: URL {
        if let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !path.isEmpty {
            let url = URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return URL.desktopDirectory
    }

    /// "Screenshot 2026-09-28 at 10.15.30.png", like macOS's own.
    static func name(_ prefix: String, _ ext: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(prefix) \(formatter.string(from: date)).\(ext)"
    }

    static var placeName: String {
        let url = url
        if url == URL.desktopDirectory { return "the Desktop" }
        return url.lastPathComponent
    }
}

/// Screen capture through ScreenCaptureKit, leaving Alfred's own notch out.
/// Needs the Screen & System Audio Recording permission.
enum ScreenCapture {
    static func content() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw AssistantFailure("Allow Notch Assistant in Screen & System Audio Recording to capture the screen", link: .screenRecording)
        }
    }

    /// The display the pointer is on.
    static func currentDisplay(in content: SCShareableContent) async -> SCDisplay? {
        let id = await MainActor.run { () -> CGDirectDisplayID? in
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            return screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        }
        return content.displays.first { $0.displayID == id } ?? content.displays.first
    }

    static func displayFilter(_ content: SCShareableContent, display: SCDisplay) -> SCContentFilter {
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        return SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
    }

    static func scale(for display: SCDisplay) async -> CGFloat {
        await MainActor.run {
            NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID }?.backingScaleFactor ?? 2
        }
    }

    /// The front window of an app (the front app if nil), front-most first.
    static func frontWindow(of appName: String?, in content: SCShareableContent) async throws -> SCWindow {
        let pid: pid_t? = await MainActor.run {
            if let appName {
                let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
                let name = AppNameMatcher.match(appName, candidates: running.compactMap(\.localizedName))
                return running.first { $0.localizedName == name }?.processIdentifier
            }
            return NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
        guard let pid else { throw ToolError("\(appName ?? "That app") isn't open") }
        // Front-to-back order comes from the window server.
        let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        for id in order {
            if let window = content.windows.first(where: { $0.windowID == id }) { return window }
        }
        throw ToolError("\(appName ?? "The front app") has no window on screen")
    }

    static func image(_ filter: SCContentFilter, width: Int, height: Int) async throws -> CGImage {
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

/// A screen recording to a .mov file, optionally with the Mac's sound and
/// the microphone.
final class ScreenRecorder: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var finished: CheckedContinuation<Void, Never>?

    func start(to url: URL, sound: Bool, voice: Bool) async throws {
        let content = try await ScreenCapture.content()
        guard let display = await ScreenCapture.currentDisplay(in: content) else { throw ToolError("There's no display to record") }
        let scale = await ScreenCapture.scale(for: display)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(CGFloat(display.width) * scale)
        configuration.height = Int(CGFloat(display.height) * scale)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.showsCursor = true
        configuration.capturesAudio = sound
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = voice
        let stream = SCStream(filter: ScreenCapture.displayFilter(content, display: display), configuration: configuration, delegate: nil)
        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = url
        recording.outputFileType = .mov
        recording.videoCodecType = .h264
        let output = SCRecordingOutput(configuration: recording, delegate: self)
        try stream.addRecordingOutput(output)
        try await stream.startCapture()
        self.stream = stream
        self.output = output
    }

    /// Stops and waits (up to 5 s) for the file to be written.
    func stop() async {
        guard let stream, let output else { return }
        self.stream = nil
        self.output = nil
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    self.finished = continuation
                    try? stream.removeRecordingOutput(output)
                }
            }
            group.addTask { try? await Task.sleep(for: .seconds(5)) }
            await group.next()
            group.cancelAll()
        }
        finished?.resume()
        finished = nil
        try? await stream.stopCapture()
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        finished?.resume()
        finished = nil
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        Log.tools.error("screen recording failed: \(error.localizedDescription, privacy: .public)")
        finished?.resume()
        finished = nil
    }
}

// MARK: - Tools

@Generable
struct ScreenshotArguments: Sendable {
    @Guide(description: "What to capture", .anyOf(["screen", "window", "selection", "clipboard"]))
    var target: String
    @Guide(description: "App whose window to capture, only if the user named one")
    var app: String?
}

/// "Take a screenshot", "screenshot this window", "screenshot Safari",
/// "screenshot a selection", "copy a screenshot".
struct ScreenshotTool: AssistantTool {
    let name = "screenshot"
    let title = "Screenshot"
    let symbol = "camera.viewfinder"
    let keywords: Set<String> = ["screenshot", "screenshots", "capture", "snap", "grab"]
    let description = """
        Take a screenshot. "take a screenshot" → screen. "screenshot this window" → window. "screenshot Safari" → window, app "Safari". \
        "screenshot part of the screen" → selection. "copy a screenshot" → clipboard.
        """
    let requiresNetwork = false
    let permission = ToolPermission.varies
    let reversibility = Reversibility.notApplicable

    func target(of arguments: ScreenshotArguments) -> String { arguments.app ?? arguments.target }

    func execute(_ arguments: ScreenshotArguments) async throws -> ToolResult {
        if arguments.target == "selection" {
            // macOS's own crosshair; it saves where screenshots go.
            try SystemKeys.ensureTrusted()
            await SystemKeys.shortcut(key: 0x15, flags: [.maskCommand, .maskShift]) // ⌘⇧4
            return ToolResult("Drag to select the area; Escape cancels")
        }
        // Let the notch finish showing, and step out of the picture.
        try await Task.sleep(for: .milliseconds(300))
        let content = try await ScreenCapture.content()
        let image: CGImage
        let what: String
        if arguments.target == "window" {
            let window = try await ScreenCapture.frontWindow(of: ClockPhrases.grounded(arguments.app), in: content)
            let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2 }
            image = try await ScreenCapture.image(SCContentFilter(desktopIndependentWindow: window),
                                                  width: Int(window.frame.width * scale), height: Int(window.frame.height * scale))
            what = window.owningApplication?.applicationName ?? "the window"
        } else {
            guard let display = await ScreenCapture.currentDisplay(in: content) else { throw ToolError("There's no display") }
            let scale = await ScreenCapture.scale(for: display)
            image = try await ScreenCapture.image(ScreenCapture.displayFilter(content, display: display),
                                                  width: Int(CGFloat(display.width) * scale), height: Int(CGFloat(display.height) * scale))
            what = "the screen"
        }
        guard let data = ScreenCapture.png(image) else { throw ToolError("The screenshot couldn't be made") }
        if arguments.target == "clipboard" {
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(data, forType: .png)
            }
            return ToolResult("Screenshot of \(what) copied")
        }
        let url = CaptureFolder.url.appending(path: CaptureFolder.name("Screenshot", "png"))
        try data.write(to: url)
        return ToolResult("Screenshot of \(what) saved to \(CaptureFolder.placeName)")
    }

    func directArguments(for command: DirectCommand) -> ScreenshotArguments? {
        var text = command.text.replacingOccurrences(of: "screen shot", with: "screenshot").replacingOccurrences(of: "screen grab", with: "screenshot")
        text = text.replacingOccurrences(of: "capture the screen", with: "screenshot").replacingOccurrences(of: "capture my screen", with: "screenshot")
        guard text.contains("screenshot") else { return nil }
        // "open my latest screenshot", "delete that screenshot": files.
        let first = text.split(separator: " ").first.map(String.init) ?? ""
        guard ["take", "grab", "snap", "screenshot", "capture", "make", "copy", "get"].contains(first) else { return nil }
        if ["selection", "area", "part", "region", "portion", "section"].contains(where: text.contains) {
            return ScreenshotArguments(target: "selection", app: nil)
        }
        if first == "copy" || text.contains("clipboard") { return ScreenshotArguments(target: "clipboard", app: nil) }
        if text.contains("window") { return ScreenshotArguments(target: "window", app: nil) }
        // "screenshot Safari", "take a screenshot of Arc".
        let words = text.split(separator: " ").map(String.init)
        let filler: Set<String> = ["take", "grab", "snap", "screenshot", "capture", "make", "get", "a", "an", "the", "of", "my", "this", "screen", "whole", "entire", "full", "please", "now"]
        let rest = words.filter { !filler.contains($0) }
        if !rest.isEmpty, rest.count <= 3 { return ScreenshotArguments(target: "window", app: rest.joined(separator: " ")) }
        return ScreenshotArguments(target: "screen", app: nil)
    }
}

@Generable
struct ScreenRecordArguments: Sendable {
    @Guide(description: "What to do", .anyOf(["start", "stop", "selection"]))
    var action: String
    @Guide(description: "True if the user asked for the Mac's sound")
    var sound: Bool?
    @Guide(description: "True if the user asked for their voice or the microphone")
    var voice: Bool?
}

/// "Record my screen (with sound / with my voice)", "stop screen
/// recording", "record part of the screen".
struct ScreenRecordTool: AssistantTool {
    let name = "recordScreen"
    let title = "Screen Recording"
    let symbol = "record.circle"
    let keywords: Set<String> = ["record", "recording", "screen"]
    let description = """
        Record the screen. "record my screen" → start. "record my screen with sound and my voice" → start, sound true, voice true. \
        "stop screen recording" → stop. "record part of the screen" → selection.
        """
    let requiresNetwork = false
    let permission = ToolPermission.varies
    let reversibility = Reversibility.notApplicable

    func target(of arguments: ScreenRecordArguments) -> String { arguments.action }

    func execute(_ arguments: ScreenRecordArguments) async throws -> ToolResult {
        switch arguments.action {
        case "stop":
            return ToolResult(await LiveCapture.shared.stop())
        case "selection":
            try SystemKeys.ensureTrusted()
            await SystemKeys.shortcut(key: 0x17, flags: [.maskCommand, .maskShift]) // ⌘⇧5
            return ToolResult("Choose the area and press Record in the bar at the bottom")
        default:
            let said = CommandContext.transcript.map { SpokenWords($0).lower } ?? []
            // Only what the user asked for, whatever the model says.
            let sound = arguments.sound == true && (said.isEmpty || !Set(said).isDisjoint(with: ["sound", "audio", "system"]))
            let voice = arguments.voice == true && (said.isEmpty || !Set(said).isDisjoint(with: ["voice", "mic", "microphone", "narration", "audio", "me"]))
            let name = try await LiveCapture.shared.startScreenRecording(sound: sound, voice: voice)
            let extras = [sound ? "sound" : nil, voice ? "your voice" : nil].compactMap { $0 }
            return ToolResult("Recording the screen\(extras.isEmpty ? "" : " with " + extras.joined(separator: " and ")). Click the notch or say “Alfred, stop recording” · \(name)")
        }
    }

    func directArguments(for command: DirectCommand) -> ScreenRecordArguments? {
        let text = command.text
        guard text.contains("screen") else { return nil }
        if ["stop screen recording", "stop recording the screen", "stop recording my screen", "stop the screen recording", "end screen recording"].contains(where: text.hasPrefix) {
            return ScreenRecordArguments(action: "stop", sound: nil, voice: nil)
        }
        let starts = ["record my screen", "record the screen", "start screen recording", "start recording my screen", "start recording the screen",
                      "screen record", "record screen", "start a screen recording", "record part of the screen", "record a part of the screen",
                      "record a selection of the screen", "record an area of the screen"]
        guard starts.contains(where: text.hasPrefix) else { return nil }
        if ["part of", "selection", "area of", "region"].contains(where: text.contains) {
            return ScreenRecordArguments(action: "selection", sound: nil, voice: nil)
        }
        let both = text.contains("with audio")
        let sound = both || ["with sound", "with system audio", "and sound", "with the sound"].contains(where: text.contains)
        let voice = both || ["voice", "microphone", "mic", "narration", "narrating"].contains(where: text.contains)
        return ScreenRecordArguments(action: "start", sound: sound, voice: voice)
    }
}
