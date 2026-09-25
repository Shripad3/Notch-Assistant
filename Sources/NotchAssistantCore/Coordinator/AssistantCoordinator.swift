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
    private static let undoLabel = ToolLabel(name: "organiseFiles", title: "Files", symbol: "folder")
    private var work: Task<Void, Never>?
    private var dismissal: Task<Void, Never>?

    public init(
        transcription: any TranscriptionService,
        engine: any AssistantEngine,
        registry: ToolRegistry,
        presenter: any NotchPresenter
    ) {
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
        // Idle, or answering a pending confirmation by voice.
        var answering = false
        if case .confirm = state { answering = true }
        guard state == .idle || answering, !isSuspended else { return }
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
            if outcomes.last?.undoable == true { resultDelay = .seconds(5) }
            await apply(.done(text, items: items), session: id)
        } catch is CancellationError {
            // cancel() already returned to Idle.
        } catch {
            await apply(.failure(AssistantFailure(error)), session: id)
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
    }

    private func dismiss(session id: Int) async {
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
        default: return
        }
        dismissal = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self.dismiss(session: id)
        }
    }
}
