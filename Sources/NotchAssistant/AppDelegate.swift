import AppKit
import NotchAssistantCore

/// Composition root: builds each layer and wires activation to the coordinator.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let status = StatusModel()
    private let hotkey = HotkeyActivation()
    private var display: DisplayResolver?
    private var notch: NotchController?
    private var coordinator: AssistantCoordinator?
    private var listener: Task<Void, Never>?
    private var defaultsObserver: NSObjectProtocol?
    private lazy var settings = SettingsWindowController(status: status)
    private var power: PowerProfileMonitor?
    private var wakeListener: (any WakeListening)?
    private var wakeWanted = false
    private var wakeEngine: WakeEngine?
    private var wakeAccent: String?
    private var wakeEvents: AsyncStream<ActivationEvent>.Continuation?
    private var wakeTask: Task<Void, Never>?
    private let clockNotifier = SystemClockNotifier()

    func showSettings() {
        settings.show()
    }

    /// Opening the app again while it runs (Finder, Spotlight, `open`) shows
    /// Settings, as menu bar apps conventionally do.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    #if DEBUG
    private let watchdog = MainThreadWatchdog()
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        #if DEBUG
        watchdog.start()
        #endif

        let display = DisplayResolver()
        let notch = NotchController(status: status, display: display)
        let speech = SystemSTT()
        let coordinator = AssistantCoordinator(
            transcription: speech,
            engine: FoundationModelsEngine(),
            registry: .standard,
            presenter: notch
        )
        self.display = display
        self.notch = notch
        self.coordinator = coordinator

        notch.onChange = { [hotkey] state in
            hotkey.setCancelKeyEnabled(state != .idle)
        }
        display.onChange = { [weak self] in self?.environmentChanged() }
        let power = PowerProfileMonitor()
        self.power = power
        power.onChange = { [weak self] in self?.updateWakeWord() }
        let (wakeStream, wakeContinuation) = AsyncStream<ActivationEvent>.makeStream()
        wakeEvents = wakeContinuation
        wakeTask = Task {
            for await event in wakeStream {
                await coordinator.handle(event)
            }
        }
        status.onPausedChange = { [weak self] in
            self?.updateSuspension()
            self?.updateWakeWord()
        }
        status.onSelect = { id in Task { await coordinator.select(id) } }
        status.onConfirm = { confirmed in Task { await coordinator.resolveConfirmation(confirmed) } }
        status.onAlert = { snooze in Task { await coordinator.resolveAlert(snooze: snooze) } }
        ClockStore.shared.start(
            notifier: clockNotifier,
            onChange: { [status] snapshot in Task { @MainActor in status.clock = snapshot } },
            onFire: { alert in Task { await coordinator.ring(alert) } }
        )
        // The display fallback setting lives in UserDefaults.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.environmentChanged() }
        }

        do {
            try hotkey.start()
        } catch {
            notch.render(.error(AssistantFailure(error)))
        }
        listener = Task { [hotkey] in
            for await event in hotkey.events {
                await coordinator.handle(event)
            }
        }
        environmentChanged()
        Task { [weak self] in
            await speech.prepare()
            // After the microphone permission is settled.
            self?.updateWakeWord()
        }
        Log.app.info("launched")
        #if DEBUG
        // Checks browser tab scripting end to end (make, read id, navigate,
        // close) on a throwaway tab: open NotchAssistant.app --args --probe-browser
        if CommandLine.arguments.contains("--probe-browser") {
            Task { await BrowserProbe.run() }
        }
        // Exercises every notch transition, including hiding, without a mic:
        // open NotchAssistant.app --args --preview-states
        if CommandLine.arguments.contains("--preview-states") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                for _ in 0..<3 {
                    await previewStates()?.value
                    try? await Task.sleep(for: .seconds(1))
                }
                Log.app.notice("preview: finished")
            }
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let wakeListener { Task { await wakeListener.stop() } }
        listener?.cancel()
        hotkey.stop()
    }

    #if DEBUG
    /// Cycles the notch through every state without the microphone or the
    /// model, to check the v1 "all six states" criterion by eye.
    @discardableResult
    func previewStates() -> Task<Void, Never>? {
        guard let notch else { return nil }
        let openURL = ToolLabel(name: "openURL", title: "Open website", symbol: "globe")
        let steps: [(AssistantState, Duration)] = [
            (.listening(partial: ""), .seconds(1)),
            (.listening(partial: "open youtube in"), .seconds(1.5)),
            (.listening(partial: "open youtube in arc"), .seconds(1)),
            (.thinking(transcript: "open youtube in arc"), .seconds(2)),
            (.acting(tool: openURL, target: "www.youtube.com"), .seconds(2)),
            (.result("Opened www.youtube.com in Arc"), .seconds(3)),
            (.list("Found 3 — click one to open", [
                ResultItem(id: "preview_1", title: "Screenshot 2026-09-20 at 22.49.31.png", detail: "5 days ago", symbol: "photo"),
                ResultItem(id: "preview_2", title: "Screenshot 2026-09-18 at 09.12.04.png", detail: "1 week ago", symbol: "photo"),
                ResultItem(id: "preview_3", title: "Invoice August.pdf", detail: "3 weeks ago", symbol: "doc.richtext"),
            ]), .seconds(5)),
            (.error(AssistantFailure("Microphone access is off for Notch Assistant", link: .microphone)), .seconds(4)),
            (.alert(.preview(.timer)), .seconds(7)),
            (.alert(.preview(.alarm)), .seconds(7)),
            (.idle, .zero),
        ]
        return Task {
            let levels = Task {
                while !Task.isCancelled {
                    notch.audioLevel(Float.random(in: 0.2...0.9))
                    try? await Task.sleep(for: .milliseconds(60))
                }
            }
            for (state, duration) in steps {
                notch.render(state)
                try? await Task.sleep(for: duration)
            }
            levels.cancel()
        }
    }
    #endif

    private func environmentChanged() {
        notch?.environmentChanged()
        updateSuspension()
        updateWakeWord()
    }

    /// Starts or stops hands-free listening from the setting, the power
    /// profile (spec §11) and the kill switch.
    private func updateWakeWord() {
        guard let power else { return }
        let enabled = UserDefaults.standard.bool(forKey: "wake.enabled")
        let reason: String? = if !enabled {
            nil
        } else if status.isPaused {
            "listening is paused"
        } else if status.isSuspendedByDisplay {
            "no built-in display"
        } else if PowerProfileMonitor.autoSwitch {
            power.profile.pauseReason
        } else {
            nil
        }
        let engine = WakeEngine.current
        let accent = UserDefaults.standard.string(forKey: SpeechWakeListener.localeKey) ?? ""
        let wanted = enabled && reason == nil

        // Settings writes land here too; only act on a real change.
        guard wanted != wakeWanted || engine != wakeEngine || accent != wakeAccent else {
            if !wanted { status.wakeStatus = enabled ? .paused(reason ?? "") : .off }
            return
        }
        wakeWanted = wanted
        let previous = wakeListener
        if engine != wakeEngine || accent != wakeAccent { wakeListener = nil }
        wakeEngine = engine
        wakeAccent = accent

        guard wanted else {
            status.wakeStatus = enabled ? .paused(reason ?? "") : .off
            Task { await previous?.stop() }
            return
        }
        do {
            if wakeListener == nil {
                let events = wakeEvents
                let onDetect: @Sendable (WakeContext) -> Void = { context in events?.yield(.wake(context)) }
                switch engine {
                case .speech:
                    wakeListener = SpeechWakeListener(onDetect: onDetect)
                case .model:
                    guard let models = WakeWordModels.locate() else {
                        status.wakeStatus = .unavailable("the wake-word models are missing")
                        return
                    }
                    wakeListener = try WakeWordListener(models: models, onDetect: onDetect)
                }
            }
        } catch {
            status.wakeStatus = .unavailable(AssistantFailure(error).message)
            return
        }
        let listener = wakeListener
        status.wakeStatus = .paused("starting…")
        Task { [weak self] in
            if previous !== listener { await previous?.stop() }
            do {
                try await listener?.start()
                self?.status.wakeStatus = .listening
            } catch {
                self?.status.wakeStatus = .unavailable(AssistantFailure(error).message)
                self?.wakeWanted = false
            }
        }
    }

    /// Suspended by the kill switch, or by the "Disable" fallback while
    /// there is no notched display.
    private func updateSuspension() {
        guard let display, let coordinator else { return }
        let byDisplay = display.targetScreen == nil && DisplayFallback.current == .disable
        status.isSuspendedByDisplay = byDisplay
        let suspended = status.isPaused || byDisplay
        Task { await coordinator.setSuspended(suspended) }
    }
}
