import Foundation
import FoundationModels
@testable import NotchAssistantCore
import Testing

struct ConversationTests {
    @Test func justTalkingBecomesChat() throws {
        let content = GeneratedContent(properties: ["justTalking": true, "steps": [GeneratedContent]()])
        let plan = try PlanSchema.decode(content, tools: [], transcript: "I had a long day at work")
        #expect(plan.chat == "I had a long day at work")
        #expect(plan.steps.isEmpty)
    }

    @Test func commandsStayCommands() throws {
        let content = GeneratedContent(properties: ["justTalking": false, "steps": [GeneratedContent]()])
        #expect(try PlanSchema.decode(content, tools: [], transcript: "x").chat == nil)
    }

    @Test(arguments: ["that's all", "bye", "Goodbye.", "never mind", "thanks, that's all"])
    func goodbyes(said: String) {
        #expect(Conversation.isGoodbye(said))
    }

    @Test(arguments: ["I'm fine", "tell me more", "that was a long meeting"])
    func notGoodbyes(said: String) {
        #expect(!Conversation.isGoodbye(said))
    }

    @Test func repliesAreSpokenText() {
        #expect(Conversation.spoken("**Sure.**\n- One thing\n- Another") == "Sure. One thing Another")
    }

    @Test func instructionsCarryMemories() {
        let text = Conversation.instructions(memories: ["27 Sep: presentation on Friday"])
        #expect(text.contains("presentation on Friday"))
        #expect(!Conversation.instructions(memories: []).contains("remember from earlier"))
    }

    @Test func memoriesAreRecalledAndForgotten() {
        let store = MemoryStore(file: nil)
        let first = UUID(), second = UUID()
        store.add("Has a presentation about climate policy on Friday", kind: .fact, conversation: first)
        store.add("Their sister Priya is visiting next week", kind: .fact, conversation: first)
        store.add("Likes jazz while working", kind: .fact, conversation: second)
        let recalled = store.relevant(to: "I'm nervous about my presentation", limit: 1)
        #expect(recalled.contains { $0.contains("presentation") })
        #expect(store.forgetLatestConversation() == 1)
        #expect(store.all.count == 2)
        store.deleteAll()
        #expect(store.all.isEmpty)
    }

    @Test(arguments: [
        ("what do you remember about me", "list"),
        ("forget that", "forgetLast"),
        ("forget everything", "forgetAll"),
    ])
    func memoryCommands(said: String, action: String) {
        #expect(DirectCommand(said).flatMap { MemoryTool().directArguments(for: $0) }?.action == action)
    }

    @Test func conversationFollowUpsAreKeptAsSaid() {
        #expect(WakeContext.followUp().isFollowUp)
        #expect(!WakeContext.gesture().isFollowUp)
        #expect(StateMachine.transition(from: .reply("Hello"), on: .activation) == .listening(partial: ""))
    }
}
