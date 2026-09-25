import FoundationModels

public struct FoundationModelsEngine: AssistantEngine {
    public var timeout: Duration

    public init(timeout: Duration = .seconds(10)) {
        self.timeout = timeout
    }

    public func unavailableReason() -> AssistantFailure? {
        switch SystemLanguageModel.default.availability {
        case .available:
            nil
        case .unavailable(.appleIntelligenceNotEnabled):
            AssistantFailure("Apple Intelligence is off, or the Mac and Siri languages don't match", link: .appleIntelligence)
        case .unavailable(.modelNotReady):
            AssistantFailure("The on-device model is still downloading", link: .appleIntelligence)
        case .unavailable(.deviceNotEligible):
            AssistantFailure("This Mac can't run Apple Intelligence")
        case .unavailable:
            AssistantFailure("The on-device model is unavailable", link: .appleIntelligence)
        }
    }

    public func plan(for transcript: String, tools: [AnyAssistantTool]) async throws -> Plan {
        if let reason = unavailableReason() { throw reason }
        let transcript = Self.clean(transcript)
        if let reply = SmallTalk.reply(to: transcript) ?? ContentRequests.refusal(for: transcript) {
            return Plan(steps: [], isDirect: true, reply: reply)
        }
        guard !tools.isEmpty else { return Plan(steps: []) }
        if let plan = DirectMatcher.plan(for: transcript, tools: tools) {
            Log.intelligence.notice("direct match for \"\(transcript, privacy: .public)\": \(plan.steps[0].tool.name, privacy: .public) \(plan.steps[0].arguments.jsonString, privacy: .public)")
            return plan
        }

        let tools = ToolRouter.relevant(for: transcript, among: tools)
        Log.intelligence.notice("model sees: \(tools.map(\.name).joined(separator: ", "), privacy: .public)")
        let schema = try PlanSchema.make(for: tools)
        let content: GeneratedContent
        do {
            content = try await withTimeout(timeout) {
                // One activation, one session: nothing carries over (spec §8).
                let session = LanguageModelSession(instructions: Prompt.instructions)
                return try await session.respond(
                    to: transcript,
                    schema: schema,
                    options: GenerationOptions(sampling: .greedy)
                ).content
            }
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.failure(for: error)
        }
        Log.intelligence.notice("plan for \"\(transcript, privacy: .public)\": \(content.jsonString, privacy: .public)")
        return try PlanSchema.decode(content, tools: tools, transcript: transcript)
    }

    /// Punctuation around the command changes the model's choice: "Open
    /// YouTube." chose openApp where "Open YouTube" chose openURL. Speech
    /// recognition adds it inconsistently, so strip it.
    static func clean(_ transcript: String) -> String {
        transcript.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static func failure(for error: LanguageModelSession.GenerationError) -> AssistantFailure {
        switch error {
        case .exceededContextWindowSize:
            AssistantFailure("That command was too long")
        case .assetsUnavailable:
            AssistantFailure("The on-device model is unavailable", link: .appleIntelligence)
        case .guardrailViolation, .refusal:
            AssistantFailure("The model declined that request")
        case .unsupportedLanguageOrLocale:
            AssistantFailure("The on-device model doesn't support this language")
        default:
            AssistantFailure("The model couldn't make sense of that")
        }
    }
}

private func withTimeout<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw AssistantFailure("The model took too long")
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
