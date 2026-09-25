#if DEBUG
import Foundation
import NotchAssistantCore
import Synchronization

/// Debug builds only. Detects the main thread being blocked (which stops
/// Escape, the hotkey and the notch) and records a stack sample of the whole
/// process while it is still stuck, using the system `sample` tool. Samples
/// go to ~/Library/Logs/NotchAssistant/. This runs a fixed diagnostic
/// command, never anything the model chooses.
final class MainThreadWatchdog: Sendable {
    static let threshold: TimeInterval = 2
    private let lastPong = Mutex(Date())
    private let lastSample = Mutex(Date.distantPast)

    func start() {
        let thread = Thread { [self] in
            while true {
                Thread.sleep(forTimeInterval: 0.5)
                DispatchQueue.main.async { [self] in lastPong.withLock { $0 = Date() } }
                let stalled = Date().timeIntervalSince(lastPong.withLock { $0 })
                if stalled > Self.threshold { record(stalled) }
            }
        }
        thread.name = "main-thread watchdog"
        thread.qualityOfService = .utility
        thread.start()
    }

    private func record(_ stalled: TimeInterval) {
        // One sample per stall, at most once a minute.
        guard lastSample.withLock({ last in
            guard Date().timeIntervalSince(last) > 60 else { return false }
            last = Date()
            return true
        }) else { return }
        let folder = URL.libraryDirectory.appending(path: "Logs/NotchAssistant", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let file = folder.appending(path: "stall-\(stamp).txt")
        Log.app.notice("main thread stalled for \(String(format: "%.1f", stalled), privacy: .public)s; sampling to \(file.path, privacy: .public)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "2", "-file", file.path]
        try? process.run()
    }
}
#endif
