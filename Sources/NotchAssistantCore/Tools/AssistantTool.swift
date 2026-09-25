import Foundation
import FoundationModels

public enum ToolPermission: String, Sendable {
    case none, files, automation, accessibility, varies
}

/// Spec §9 "Adding a tool later": there is no separate destructive flag.
/// A mutating tool that cannot supply an inverse is `refused` and never
/// registered.
public enum Reversibility: String, Sendable {
    case notApplicable, reversible, refused
}

/// One capability. Adding a capability means writing one conformance and
/// listing it in `ToolRegistry` — nothing else.
protocol AssistantTool: Sendable {
    associatedtype Arguments: Generable & Sendable

    var name: String { get }
    /// Shown to the user: the Acting state and the Capabilities pane.
    var title: String { get }
    /// SF Symbol for the Acting state and the Capabilities pane.
    var symbol: String { get }
    /// Written for the model, not a human: concrete, with an example phrasing.
    var description: String { get }
    var requiresNetwork: Bool { get }
    var permission: ToolPermission { get }
    var reversibility: Reversibility { get }

    /// Short description of what the call acts on, shown in the Acting state.
    func target(of arguments: Arguments) -> String
    /// Returns a one-line outcome, optionally with items to choose from.
    /// Must honour cancellation.
    func execute(_ arguments: Arguments) async throws -> ToolResult

    /// Arguments for a command simple enough to recognise without the model
    /// ("open Spotify"), or nil to leave it to the model. Must be
    /// conservative: a wrong match skips the model entirely.
    func directArguments(for command: DirectCommand) -> Arguments?
}

extension AssistantTool {
    func directArguments(for command: DirectCommand) -> Arguments? { nil }
}

public struct ToolError: LocalizedError, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// What the UI needs to show a tool, without the tool itself.
public struct ToolLabel: Sendable, Equatable {
    public let name: String
    public let title: String
    public let symbol: String

    public init(name: String, title: String, symbol: String) {
        self.name = name
        self.title = title
        self.symbol = symbol
    }
}

/// Type-erased tool. The engine only sees these, so it never needs to know
/// which concrete tools exist.
public struct AnyAssistantTool: Sendable {
    public let name: String
    public let label: ToolLabel
    public let description: String
    public let requiresNetwork: Bool
    public let permission: ToolPermission
    public let reversibility: Reversibility
    let argumentsSchema: DynamicGenerationSchema
    private let directMatch: @Sendable (DirectCommand) -> GeneratedContent?
    private let describeTarget: @Sendable (GeneratedContent) throws -> String
    private let run: @Sendable (GeneratedContent) async throws -> ToolResult

    init<Tool: AssistantTool>(_ tool: Tool) {
        name = tool.name
        label = ToolLabel(name: tool.name, title: tool.title, symbol: tool.symbol)
        description = tool.description
        requiresNetwork = tool.requiresNetwork
        permission = tool.permission
        reversibility = tool.reversibility
        argumentsSchema = DynamicGenerationSchema(type: Tool.Arguments.self)
        directMatch = { tool.directArguments(for: $0)?.generatedContent }
        describeTarget = { try tool.target(of: Tool.Arguments($0)) }
        run = { try await tool.execute(Tool.Arguments($0)) }
    }

    func directArguments(for command: DirectCommand) -> GeneratedContent? {
        directMatch(command)
    }

    public func target(of arguments: GeneratedContent) throws -> String {
        try describeTarget(arguments)
    }

    public func execute(_ arguments: GeneratedContent) async throws -> ToolResult {
        try await run(arguments)
    }
}
