import FoundationModels

public struct PlannedStep: Sendable {
    public let tool: AnyAssistantTool
    public let arguments: GeneratedContent
    /// What the user said, so the tool can ground its arguments in it.
    public let transcript: String

    public func target() -> String {
        (try? tool.target(of: arguments)) ?? ""
    }

    public func execute() async throws -> ToolResult {
        try await CommandContext.$transcript.withValue(transcript) {
            try await tool.execute(arguments)
        }
    }
}

/// The model's output: an explicit, ordered list of steps (spec §8,
/// "decompose compound commands explicitly"). Empty means no tool fits.
public struct Plan: Sendable {
    public var steps: [PlannedStep]
    /// True when matched without the model (`DirectMatcher`).
    public var isDirect = false
    /// A text-only answer, with no steps (`SmallTalk`).
    public var reply: String?
}

/// Builds the structured-output schema from whichever tools are registered,
/// so adding a tool never touches this file. Each step is one of the tools,
/// discriminated by a `tool` field that can only take that tool's name.
public enum PlanSchema {
    public static let maximumSteps = 5

    public static func make(for tools: [AnyAssistantTool]) throws -> GenerationSchema {
        let steps = tools.map { tool in
            DynamicGenerationSchema(
                name: "\(tool.name)Step",
                description: tool.description,
                properties: [
                    .init(name: "tool", schema: DynamicGenerationSchema(name: "\(tool.name)Name", anyOf: [tool.name])),
                    .init(name: "arguments", schema: tool.argumentsSchema),
                ]
            )
        }
        let plan = DynamicGenerationSchema(
            name: "Plan",
            properties: [
                .init(
                    name: "steps",
                    description: "Actions in the order they should run. Empty if no tool fits.",
                    schema: DynamicGenerationSchema(
                        arrayOf: DynamicGenerationSchema(name: "Step", anyOf: steps),
                        minimumElements: 0,
                        maximumElements: maximumSteps
                    )
                ),
            ]
        )
        return try GenerationSchema(root: plan, dependencies: [])
    }

    public static func decode(_ content: GeneratedContent, tools: [AnyAssistantTool], transcript: String) throws -> Plan {
        let steps = try content.value([GeneratedContent].self, forProperty: "steps")
        return Plan(steps: try steps.map { step in
            let name = try step.value(String.self, forProperty: "tool")
            // Constrained decoding makes this unreachable, but model output is
            // untrusted input: never execute a name that was not registered.
            guard let tool = tools.first(where: { $0.name == name }) else {
                throw AssistantFailure("The model asked for an unknown tool \"\(name)\"")
            }
            let arguments = try step.value(GeneratedContent.self, forProperty: "arguments")
            return PlannedStep(tool: tool, arguments: arguments, transcript: transcript)
        })
    }
}
