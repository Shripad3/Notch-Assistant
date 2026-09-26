import Foundation

/// Owns the state machine and is the only thing that talks across layers
/// (spec §3).
public actor AssistantCoordinator {
    private let transcription: any TranscriptionService
    private let engine: any AssistantEngine
    private let registry: ToolRegistry
    private let presenter: any NotchPresenter

    private var state: AssistantState = .idle
    /// Increments per activation. Work from an earlier activation that
    /// finishes late carries a stale id and is ignored.
    private var session = 0
    private var lastTrigger: ContinuousClock.Instant?
    /// Set by the kill switch and by the "Disable" display fallback.
    private var isSuspended = false
    /// The wake-word detection that started this session, if hands-free.
    private var wake: WakeContext?
    /// A batch of file changes waiting for yes or no.
    private var pendingConfirmation: String?
    /// How long the next result stays up; longer for undoable file changes.
    private var resultDelay: Duration = .seconds(3)
    /// The alert the user interrupted by speaking: "stop" and "snooze" apply
    /// to it.
    private var interruptedAlert: ClockAlert?
    /// Alerts that came due while the notch was busy; shown once it's idle.
    private var queuedAlerts: [ClockAlert] = []
    private let clock: ClockStore
    /// How long an alert rings before it counts as missed.
    static let ringFor: Duration = .seconds(60)
    private static let undoLabel = ToolLabel(name: "organiseFiles", title: "Files", symbol: "folder")
    private var work: Task<Void, Never>?
    private var dismissal: Task<Void, Never>?

    public init(
        transcription: any TranscriptionService,
        engine: any AssistantEngine,
        registry: ToolRegistry,
        presenter: any NotchPresenter,
        clock: ClockStore = .shared
    ) {
        self.clock = clock
        self.transcription = transcription
        self.engine = engine
        self.registry = registry
        self.presenter = presenter
    }

    public var currentState: AssistantState { state }

    /// Suspending stops all activation and cancels anything in flight.
    public func setSuspended(_ suspended: Bool) async {
        isSuspended = suspended
        if suspended { await cancel() }
    }

    public func handle(_ event: ActivationEvent) async {
        switch event {
        case .triggered: await activationBegan()
        case .wake(let context): await activationBegan(wake: context)
        case .released: activationEnded()
        case .cancelled: await cancel()
        }
    }

    /// Arbitration (spec §6): accepted only when Idle, with a 1 s debounce.
    public func activationBegan(wake: WakeContext? = nil) async {
        // Idle, answering a pending confirmation by voice, or stopping an
        // alert ("Alfred, stop").
        var answering = false
        interruptedAlert = nil
        switch state {
        case .confirm: answering = true
        case .alert(let alert):
            answering = true
            interruptedAlert = alert
        default: break
        }
        guard state == .idle || answering, !isSuspended || interruptedAlert != nil else { return }
        if !answering {
            pendingConfirmation = nil
            Confirmations.discard()
        }
        let now = ContinuousClock.now
        if let lastTrigger, lastTrigger.duration(to: now) < .seconds(1) { return }
        lastTrigger = now
        session += 1
        // Tokens from an earlier command can't be reused (spec §9).
        ResultActions.reset()
        self.wake = wake
        let id = session

        if let reason = engine.unavailableReason() {
            await apply(.failure(reason), session: id)
            return
        }
        await apply(.activation, session: id)
        do {
            try await transcription.start(wake: wake) { [weak self] update in
                Task { await self?.received(update, session: id) }
            }
        } catch {
            await apply(.failure(AssistantFailure(error)), session: id)
        }
    }

    /// Hold-to-talk release is the endpoint.
    public func activationEnded() {
        guard case .listening = state else { return }
        let id = session
        work = Task { await self.process(session: id) }
    }

    /// The user picked a row from a result list in the notch.
    public func select(_ itemID: String) async {
        guard case .list = state else { return }
        let id = session
        dismissal?.cancel()
        do {
            await apply(.selected(try await ResultActions.select(itemID)), session: id)
        } catch {
            await apply(.failure(AssistantFailure(error)), session: id)
        }
    }

    /// The notch's Confirm or Cancel button for a pending batch.
    public func resolveConfirmation(_ confirmed: Bool) async {
        guard case .confirm = state, let token = pendingConfirmation else { return }
        pendingConfirmation = nil
        let id = session
        guard confirmed else {
            Confirmations.discard()
            await apply(.cancel, session: id)
            return
        }
        dismissal?.cancel()
        do {
            resultDelay = .seconds(5)
            await apply(.selected(try await Confirmations.confirm(token)), session: id)
        } catch {
            await apply(.failure(AssistantFailure(error)), session: id)
        }
    }

    /// A timer or alarm is due: ring now, or as soon as the notch is free.
    public func ring(_ alert: ClockAlert) async {
        guard state == .idle else {
            queuedAlerts.append(alert)
            return
        }
        session += 1
        await apply(.ring(alert), session: session)
    }

    /// The notch's Stop or Snooze button.
    public func resolveAlert(snooze: Bool) async {
        guard case .alert(let alert) = state else { return }
        if snooze, alert.canSnooze { clock.snooze(alert) }
        await apply(.dismiss, session: session)
    }

    /// Escape: back to Idle from any non-idle state, aborting in-flight work.
    public func cancel() async {
        guard state != .idle else { return }
        pendingConfirmation = nil
        Confirmations.discard()
        work?.cancel()
        work = nil
        await transcription.cancel()
        await apply(.cancel, session: session)
    }

    private func process(session id: Int) async {
        var transcript = await transcription.finish()
        guard !transcript.isEmpty else {
            await apply(.silence, session: id)
            return
        }
        if let wake, wake.confirmed {
            // The speech detector already transcribed "Alfred"; this second
            // recognizer often mishears it ("I said…", "Hi friend…"), which
            // rejected real commands. Only tidy the transcript.
            transcript = WakePhrase.commandAfterConfirmedWake(transcript)
        } else if wake != nil {
            guard let command = WakePhrase.command(from: transcript) else {
                // A false detection: the wake word isn't in what was said.
                Log.coordinator.notice("wake word not confirmed in \"\(transcript, privacy: .public)\"; ignoring")
                await apply(.silence, session: id)
                return
            }
            transcript = command
        }
        await apply(.endpoint(transcript), session: id)

        // Spoken over a ringing alert: "stop" and "snooze" are for it;
        // anything else is a new command (the alert is already silenced).
        if let alert = interruptedAlert {
            interruptedAlert = nil
            switch AlertReply.interpret(transcript) {
            case .snooze where alert.canSnooze:
                let date = clock.snooze(alert)
                await apply(.textOnly("Snoozed until \(date.formatted(date: .omitted, time: .shortened))"), session: id)
                return
            case .snooze, .stop:
                await apply(.textOnly(alert.kind == .timer ? "Timer stopped" : "Alarm stopped"), session: id)
                return
            case nil:
                break
            }
        }

        // A pending batch: "yes" applies it, "no" drops it, anything else is
        // a new command and the batch is dropped.
        if let token = pendingConfirmation {
            pendingConfirmation = nil
            switch Confirmations.answer(in: transcript) {
            case true?:
                await apply(.toolCall(Self.undoLabel, target: "Confirmed"), session: id)
                do {
                    resultDelay = .seconds(5)
                    await apply(.done(try await Confirmations.confirm(token)), session: id)
                } catch {
                    await apply(.failure(AssistantFailure(error)), session: id)
                }
                return
            case false?:
                Confirmations.discard()
                await apply(.textOnly("Cancelled. Nothing was changed."), session: id)
                return
            case nil:
                Confirmations.discard()
            }
        }

        do {
            let plan = try await engine.plan(for: transcript, tools: registry.enabledTools())
            if plan.steps.isEmpty, let reply = plan.reply {
                await apply(.textOnly(reply), session: id)
                return
            }
            if let routine = plan.routine {
                try await run(routine, plan.steps, session: id)
                return
            }
            guard !plan.steps.isEmpty else {
                throw AssistantFailure("I can't do that yet")
            }
            var outcomes: [ToolResult] = []
            for (index, step) in plan.steps.enumerated() {
                try Task.checkCancellation()
                await apply(.toolCall(step.tool.label, target: step.target()), session: id)
                // A throwing step leaves the remaining steps unexecuted (spec §8).
                outcomes.append(try await step.execute(isFinal: index == plan.steps.count - 1))
            }
            let items = outcomes.last?.items ?? []
            let text = outcomes.map(\.text).joined(separator: " · ")
            if let token = outcomes.last?.confirmation {
                pendingConfirmation = token
                await apply(.needsConfirmation(text, items), session: id)
                return
            }
            if outcomes.count == 1, outcomes[0].isAnswer {
                await apply(.answer(text), session: id)
                return
            }
            if outcomes.last?.undoable == true { resultDelay = .seconds(5) }
            await apply(.done(text, items: items), session: id)
        } catch is CancellationError {
            // cancel() already returned to Idle.
        } catch {
            await apply(.failure(AssistantFailure(error)), session: id)
        }
    }

    /// A routine runs every step even when one fails (the lights being
    /// unreachable shouldn't stop the music), then speaks its closing line,
    /// or says what didn't work.
    private func run(_ routine: RoutineRun, _ steps: [PlannedStep], session id: Int) async throws {
        var failures = routine.skipped.map { "\($0) (turned off)" }
        for (index, step) in steps.enumerated() {
            try Task.checkCancellation()
            await apply(.toolCall(step.tool.label, target: step.target()), session: id)
            do {
                _ = try await step.execute(isFinal: index == steps.count - 1)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.coordinator.notice("routine step \(step.tool.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                failures.append("\(step.tool.label.title) “\(step.target())”: \(AssistantFailure(error).message)")
            }
        }
        let ran = steps.count + routine.skipped.count - failures.count
        if failures.isEmpty {
            await apply(.answer(routine.closing ?? "\(routine.name): done"), session: id)
        } else if ran == 0 {
            await apply(.failure(AssistantFailure("\(routine.name) didn't work. " + failures.joined(separator: " · "))), session: id)
        } else {
            let lead = routine.closing.map { $0 + " " } ?? ""
            await apply(.answer(lead + "But \(failures.count) step\(failures.count == 1 ? "" : "s") didn't work: " + failures.joined(separator: " · ")), session: id)
        }
    }

    private func received(_ update: TranscriptionUpdate, session id: Int) async {
        switch update {
        case .partial(let text):
            await apply(.partial(text), session: id)
        case .level(let level):
            guard id == session, case .listening = state else { return }
            await presenter.audioLevel(level)
        case .endOfSpeech:
            guard id == session else { return }
            activationEnded()
        case .noSpeech:
            // No speech after waking. The command may still be there: said in
            // one breath ("Hey Alfred, open Notes"), it was over before the
            // detection, and lives in the pre-roll audio the recognizer was
            // given. Finishing transcribes it; an empty or wake-word-only
            // transcript is handled in process().
            guard id == session else { return }
            activationEnded()
        }
    }

    private func apply(_ event: AssistantEvent, session id: Int) async {
        guard id == session, let next = StateMachine.transition(from: state, on: event) else { return }
        state = next
        if case .partial = event {} else {
            Log.coordinator.notice("→ \(String(describing: next), privacy: .public)")
        }
        scheduleDismissal(after: next, session: id)
        await presenter.render(next)
        if next == .idle, !queuedAlerts.isEmpty {
            await ring(queuedAlerts.removeFirst())
        }
    }

    private func dismiss(session id: Int) async {
        if case .alert(let alert) = state, id == session {
            // Rang for a minute with nobody there.
            clock.missed(alert)
        }
        if case .confirm = state, id == session {
            // Unanswered: the batch is dropped, nothing changes.
            pendingConfirmation = nil
            Confirmations.discard()
        }
        await apply(.dismiss, session: id)
    }

    private func scheduleDismissal(after state: AssistantState, session id: Int) {
        dismissal?.cancel()
        let delay: Duration
        switch state {
        case .result:
            delay = resultDelay
            resultDelay = .seconds(3)
        case .confirm: delay = .seconds(20)
        case .reply: delay = .seconds(4)
        case .list: delay = .seconds(10)
        case .error: delay = .seconds(5)
        case .alert: delay = Self.ringFor
        default: return
        }
        dismissal = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self.dismiss(session: id)
        }
    }
}
