/// Transcript in, planned tool calls out (spec §3).
public protocol AssistantEngine: Sendable {
    /// Nil when the engine can run; otherwise the reason it cannot.
    func unavailableReason() -> AssistantFailure?
    func plan(for transcript: String, tools: [AnyAssistantTool]) async throws -> Plan
    /// Mid-conversation: commands still run, anything else is talk.
    func plan(for transcript: String, tools: [AnyAssistantTool], conversing: Bool) async throws -> Plan
}

extension AssistantEngine {
    public func plan(for transcript: String, tools: [AnyAssistantTool], conversing: Bool) async throws -> Plan {
        try await plan(for: transcript, tools: tools)
    }
}
