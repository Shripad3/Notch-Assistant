import FoundationModels
@testable import NotchAssistantCore
import Testing

struct PlanSchemaTests {
    let tools = ToolRegistry(tools: ToolRegistry.standard.tools, isEnabled: { _ in true }).enabledTools()

    @Test func schemaBuildsForRegisteredTools() throws {
        _ = try PlanSchema.make(for: tools)
        _ = try PlanSchema.make(for: [tools[0]])
    }

    @Test func decodesOrderedSteps() throws {
        let content = GeneratedContent(properties: [
            "steps": [
                GeneratedContent(properties: [
                    "tool": "openApp",
                    "arguments": GeneratedContent(properties: ["appName": "Arc"]),
                ]),
                GeneratedContent(properties: [
                    "tool": "openURL",
                    "arguments": GeneratedContent(properties: ["url": "https://www.youtube.com", "browser": "Arc"]),
                ]),
            ],
        ])
        let plan = try PlanSchema.decode(content, tools: tools, transcript: "open arc and youtube")
        #expect(plan.steps.map(\.tool.name) == ["openApp", "openURL"])
        #expect(plan.steps.map { $0.target() } == ["Arc", "www.youtube.com"])
    }

    @Test func emptyStepsMeansNoTool() throws {
        let content = GeneratedContent(properties: ["steps": [GeneratedContent]()])
        #expect(try PlanSchema.decode(content, tools: tools, transcript: "").steps.isEmpty)
    }

    @Test func unregisteredToolIsRejected() {
        let content = GeneratedContent(properties: [
            "steps": [GeneratedContent(properties: ["tool": "runCommand", "arguments": GeneratedContent(properties: [:])])],
        ])
        #expect(throws: AssistantFailure.self) { try PlanSchema.decode(content, tools: tools, transcript: "") }
    }

    @Test func disabledToolIsNotRegistered() {
        let registry = ToolRegistry(tools: ToolRegistry.standard.tools, isEnabled: { $0 != "openURL" })
        #expect(!registry.enabledTools().map(\.name).contains("openURL"))
        #expect(registry.enabledTools().count == ToolRegistry.standard.tools.count - 1)
    }
}
