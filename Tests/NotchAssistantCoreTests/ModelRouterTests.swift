import Foundation
import FoundationModels
@testable import NotchAssistantCore
import Synchronization
import Testing

/// Answers every call with fixed text and records what it was asked.
final class FakeBackend: ModelBackend, @unchecked Sendable {
    let identifier = "fake"
    let contextWindow = 1_000
    var unavailableReason: AssistantFailure? { nil }
    let prompts = Mutex<[String]>([])
    let answer: String

    init(answer: String = "Sounds like a long one.") { self.answer = answer }

    func respond(system: String, prompt: String, temperature: Double?) async throws(ModelError) -> String {
        prompts.withLock { $0.append(prompt) }
        return answer
    }

    func respond<T: Generable & Sendable>(system: String, prompt: String, generating type: T.Type) async throws(ModelError) -> T {
        prompts.withLock { $0.append(prompt) }
        throw .other("not supported by the fake")
    }

    func respond(system: String, prompt: String, schema: GenerationSchema, deterministic: Bool) async throws(ModelError) -> GeneratedContent {
        prompts.withLock { $0.append(prompt) }
        return GeneratedContent(properties: ["justTalking": true, "steps": [GeneratedContent]()])
    }

    func chat(system: String) -> any ChatSession { FakeChat(backend: self) }
}

private struct FakeChat: ChatSession {
    let backend: FakeBackend
    func send(_ text: String, temperature: Double?) async throws(ModelError) -> String {
        try await backend.respond(system: "", prompt: text, temperature: temperature)
    }
}

@Suite(.serialized)
struct ModelRouterTests {
    @Test func everyTaskHasABackend() {
        for task in ModelTask.allCases {
            #expect(!ModelRouter.backend(for: task).identifier.isEmpty)
        }
        #expect(ModelRouter.backend(for: .intent).identifier == "apple.foundation")
        #expect(AppleFoundationBackend.shared.contextWindow == 4_096)
    }

    @Test func conversationGoesThroughTheRouter() async throws {
        let fake = FakeBackend()
        ModelRouter.use(fake)
        defer { ModelRouter.use(nil) }
        let reply = try await Conversation.scratch().reply(to: "I had a long day")
        #expect(reply == "Sounds like a long one.")
        #expect(fake.prompts.withLock { $0 } == ["I had a long day"])
    }

    @Test func errorsBecomeReadableFailures() {
        #expect(ModelError.refused.failure.message == "The model declined that request")
        #expect(ModelError.contextOverflow.failure.message.contains("too long"))
    }
}
