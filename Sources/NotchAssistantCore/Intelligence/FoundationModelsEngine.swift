import FoundationModels

public struct FoundationModelsEngine: AssistantEngine {
    public var timeout: Duration

    public init(timeout: Duration = .seconds(10)) {
        self.timeout = timeout
    }

    public func unavailableReason() -> AssistantFailure? {
        ModelRouter.backend(for: .intent).unavailableReason
    }

    public func plan(for transcript: String, tools: [AnyAssistantTool]) async throws -> Plan {
        if let reason = unavailableReason() { throw reason }
        let transcript = Self.clean(transcript)
        // Before small talk, so a "good night" routine wins over a reply.
        if let routine = Routines.match(transcript) {
            Log.intelligence.notice("routine \"\(routine.name, privacy: .public)\" for \"\(transcript, privacy: .public)\"")
            return Routines.plan(for: routine, tools: tools)
        }
        if let reply = SmallTalk.reply(to: transcript) {
            return Plan(steps: [], isDirect: true, reply: reply, isSmallTalk: true)
        }
        if let refusal = ContentRequests.refusal(for: transcript) {
            return Plan(steps: [], isDirect: true, reply: refusal)
        }
        guard !tools.isEmpty else { return Plan(steps: []) }
        if let plan = DirectMatcher.plan(for: transcript, tools: tools) {
            Log.intelligence.notice("direct match for \"\(transcript, privacy: .public)\": \(plan.steps[0].tool.name, privacy: .public) \(plan.steps[0].arguments.jsonString, privacy: .public)")
            return plan
        }

        let tools = ToolRouter.relevant(for: transcript, among: tools)
        // Nothing here is about a tool: it's conversation.
        if tools.isEmpty, Conversation.isEnabled { return Plan(steps: [], chat: transcript) }
        Log.intelligence.notice("model sees: \(tools.map(\.name).joined(separator: ", "), privacy: .public)")
        let schema = try PlanSchema.make(for: tools)
        let content: GeneratedContent
        let backend = ModelRouter.backend(for: .intent)
        do {
            content = try await withTimeout(timeout) {
                // One activation, one session: nothing carries over (spec §8).
                try await backend.respond(system: Prompt.instructions, prompt: transcript, schema: schema, deterministic: true)
            }
        } catch let error as ModelError {
            throw Self.failure(for: error)
        }
        Log.intelligence.notice("plan for \"\(transcript, privacy: .public)\": \(content.jsonString, privacy: .public)")
        let plan = try PlanSchema.decode(content, tools: tools, transcript: transcript)
        return plan.chat != nil && !Conversation.isEnabled ? Plan(steps: []) : plan
    }

    public func plan(for transcript: String, tools: [AnyAssistantTool], conversing: Bool) async throws -> Plan {
        guard conversing else { return try await plan(for: transcript, tools: tools) }
        if let reason = unavailableReason() { throw reason }
        let transcript = Self.clean(transcript)
        if let routine = Routines.match(transcript) { return Routines.plan(for: routine, tools: tools) }
        if let plan = DirectMatcher.plan(for: transcript, tools: tools) { return plan }
        return Plan(steps: [], chat: transcript)
    }

    /// Punctuation around the command changes the model's choice: "Open
    /// YouTube." chose openApp where "Open YouTube" chose openURL. Speech
    /// recognition adds it inconsistently, so strip it.
    static func clean(_ transcript: String) -> String {
        transcript.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static func failure(for error: ModelError) -> AssistantFailure {
        error == .contextOverflow ? AssistantFailure("That command was too long") : error.failure
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
