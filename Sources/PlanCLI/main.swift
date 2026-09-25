import Foundation
import NotchAssistantCore

// Dry run of the intelligence layer: prints the plan for each transcript
// without executing anything. Usage:
//   swift run plan-cli "open spotify" "open youtube in arc"
//   swift run plan-cli - < transcripts.txt

import FoundationModels

// plan-cli --tokens: how much of the model's context each tool's schema takes.
if CommandLine.arguments.dropFirst().first == "--tokens", #available(macOS 26.4, *) {
    let tools = ToolRegistry.standard.enabledTools()
    let model = SystemLanguageModel.default
    let total = try await model.tokenCount(for: PlanSchema.make(for: tools))
    print("all \(tools.count) tools: \(total) tokens")
    for tool in tools {
        print("  \(tool.name): \(try await model.tokenCount(for: PlanSchema.make(for: [tool]))) tokens (alone)")
    }
    // The router sends at most this many: the worst case is the four largest.
    var sizes: [(String, Int)] = []
    for tool in tools { sizes.append((tool.name, try await model.tokenCount(for: PlanSchema.make(for: [tool])))) }
    let largest = sizes.sorted { $0.1 > $1.1 }.prefix(ToolRouter.maximum).map(\.0)
    let worst = try await model.tokenCount(for: PlanSchema.make(for: tools.filter { largest.contains($0.name) }))
    print("worst case the router sends (\(largest.joined(separator: ", "))): \(worst) tokens")
    exit(0)
}

var transcripts = Array(CommandLine.arguments.dropFirst())
if transcripts == ["-"] {
    transcripts = []
    while let line = readLine() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, !trimmed.hasPrefix("#") { transcripts.append(trimmed) }
    }
}
guard !transcripts.isEmpty else {
    print("usage: plan-cli \"<transcript>\" [...]   or   plan-cli - < file")
    exit(2)
}

let engine = FoundationModelsEngine()
if let reason = engine.unavailableReason() {
    print("model unavailable: \(reason.message)")
    exit(1)
}

let tools = ToolRegistry.standard.enabledTools()
for transcript in transcripts {
    print("\"\(transcript)\"")
    let started = ContinuousClock.now
    do {
        let plan = try await engine.plan(for: transcript, tools: tools)
        let elapsed = started.duration(to: .now)
        if plan.steps.isEmpty { print("  → (no steps)") }
        if plan.isDirect { print("  (direct match, model skipped)") }
        for step in plan.steps {
            print("  → \(step.tool.name) \(step.arguments.jsonString)")
        }
        print("  \(elapsed.formatted(.units(allowed: [.milliseconds])))")
    } catch {
        print("  ✗ \(AssistantFailure(error).message)")
    }
}
