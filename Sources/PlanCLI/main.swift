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

// plan-cli --read <file> ["question"]: summarise a file, or answer about it.
if CommandLine.arguments.dropFirst().first == "--read", CommandLine.arguments.count > 2 {
    let question = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : nil
    let start = Date()
    print(try await ReadingDebug.run(path: CommandLine.arguments[2], question: question))
    print(String(format: "(%.1f s)", Date().timeIntervalSince(start)))
    exit(0)
}

// plan-cli --chat "…" "…": one conversation, Alfred's replies printed.
if CommandLine.arguments.dropFirst().first == "--chat" {
    let conversation = Conversation.scratch()
    for line in CommandLine.arguments.dropFirst(2) {
        let start = Date()
        let reply = try await conversation.reply(to: line)
        print("you:    \(line)\nalfred: \(reply)  (\(String(format: "%.1f", Date().timeIntervalSince(start))) s)")
    }
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
        if let chat = plan.chat {
            print("  → conversation: “\(chat)”")
        } else if let reply = plan.reply {
            print("  → reply: \(reply)")
        } else if plan.steps.isEmpty {
            print("  → (no steps)")
        }
        if plan.isDirect { print("  (direct match, model skipped)") }
        for step in plan.steps {
            print("  → \(step.tool.name) \(step.arguments.jsonString)")
        }
        print("  \(elapsed.formatted(.units(allowed: [.milliseconds])))")
    } catch {
        print("  ✗ \(AssistantFailure(error).message)")
    }
}
