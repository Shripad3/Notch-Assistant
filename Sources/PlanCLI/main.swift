import Foundation
import NotchAssistantCore

// Dry run of the intelligence layer: prints the plan for each transcript
// without executing anything. Usage:
//   swift run plan-cli "open spotify" "open youtube in arc"
//   swift run plan-cli - < transcripts.txt

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
