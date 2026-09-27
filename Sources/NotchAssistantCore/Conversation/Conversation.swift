import Foundation
import FoundationModels
import NaturalLanguage
import Synchronization

/// One remembered thing: a conversation's gist, or a fact about the user.
public struct Memory: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable { case summary, fact }
    public let id: UUID
    public let date: Date
    public let kind: Kind
    public let text: String
    /// Which conversation it came from, for "forget that".
    public let conversation: UUID
    var vector: [Double]?
}

/// Memories across conversations: short summaries and facts, stored only on
/// this Mac, visible and deletable in Settings. The model's context is
/// small, so only the few most relevant (by on-device sentence embeddings)
/// are given to it each time.
public final class MemoryStore: Sendable {
    public static let shared = MemoryStore(file: URL.applicationSupportDirectory.appending(path: "NotchAssistant/memory.json"))
    public static let enabledKey = "conversation.memory"
    /// Oldest dropped beyond this.
    static let keep = 500

    public static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    private let file: URL?
    private let items: Mutex<[Memory]>
    private let onChange = Mutex<(@Sendable () -> Void)?>(nil)

    init(file: URL?) {
        self.file = file
        let loaded = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([Memory].self, from: $0) }
        // Placeholders saved before they were filtered out.
        items = Mutex((loaded ?? []).filter { Conversation.worthKeeping($0.text) })
    }

    public var all: [Memory] { items.withLock { $0.sorted { $0.date > $1.date } } }

    public func observe(_ observer: @escaping @Sendable () -> Void) { onChange.withLock { $0 = observer } }

    func add(_ text: String, kind: Memory.Kind, conversation: UUID) {
        let memory = Memory(id: UUID(), date: Date(), kind: kind, text: text, conversation: conversation, vector: Self.vector(text))
        change { items in
            items.append(memory)
            if items.count > Self.keep { items.removeFirst(items.count - Self.keep) }
        }
    }

    public func delete(_ id: UUID) { change { $0.removeAll { $0.id == id } } }
    public func deleteAll() { change { $0.removeAll() } }

    /// "Forget that": everything from the latest conversation.
    @discardableResult
    func forgetLatestConversation() -> Int {
        var removed = 0
        change { items in
            guard let latest = items.max(by: { $0.date < $1.date })?.conversation else { return }
            removed = items.filter { $0.conversation == latest }.count
            items.removeAll { $0.conversation == latest }
        }
        return removed
    }

    /// The memories most related to what the user just said, plus the latest
    /// conversation's gist, within a small character budget.
    func relevant(to query: String, limit: Int = 6, budget: Int = 1_200) -> [String] {
        let all = items.withLock { $0 }
        guard !all.isEmpty else { return [] }
        let target = Self.vector(query)
        let queryWords = Set(Self.words(query))
        let scored = all.map { memory -> (Memory, Double) in
            if let target, let vector = memory.vector, vector.count == target.count {
                return (memory, Self.cosine(target, vector))
            }
            // No embedding: shared words.
            let overlap = Double(queryWords.intersection(Self.words(memory.text)).count)
            return (memory, overlap / Double(max(queryWords.count, 1)))
        }
        var chosen = scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
        if let latest = all.filter({ $0.kind == .summary }).max(by: { $0.date < $1.date }), !chosen.contains(latest) {
            chosen.append(latest)
        }
        var total = 0
        return chosen.sorted { $0.date < $1.date }.compactMap { memory in
            let line = "\(memory.date.formatted(date: .abbreviated, time: .omitted)): \(memory.text)"
            guard total + line.count <= budget else { return nil }
            total += line.count
            return line
        }
    }

    private func change(_ update: (inout [Memory]) -> Void) {
        let snapshot = items.withLock { items -> [Memory] in
            update(&items)
            return items
        }
        if let file {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
        }
        onChange.withLock { $0 }?()
    }

    static func vector(_ text: String) -> [Double]? {
        NLEmbedding.sentenceEmbedding(for: .english)?.vector(for: text)
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }

    private static func words(_ text: String) -> [String] {
        AppNameMatcher.normalize(text).split(separator: " ").map(String.init).filter { $0.count > 3 }
    }
}

@Generable
struct ConversationMemory: Sendable {
    @Guide(description: "One sentence: what the conversation was about, from the user's side")
    var summary: String
    @Guide(description: "Facts about the user worth remembering later: plans with dates, people, preferences, ongoing situations. Leave the list empty when there are none; never write placeholders.", .count(0...3))
    var facts: [String]
}

/// Spoken conversation with the on-device model, as Alfred. One session per
/// conversation, so it remembers what was just said; it ends after a quiet
/// moment, and (if memory is on) leaves a short summary and facts behind.
public actor Conversation {
    public static let shared = Conversation()
    public static let enabledKey = "conversation.enabled"
    public static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    private var session: LanguageModelSession?
    private var id = UUID()
    private var turns: [(user: String, alfred: String)] = []
    private let memory: MemoryStore

    init(memory: MemoryStore = .shared) {
        self.memory = memory
    }

    public var isActive: Bool { session != nil }

    /// A conversation whose memories stay in memory (the plan-cli tool).
    public static func scratch() -> Conversation { Conversation(memory: MemoryStore(file: nil)) }

    static func instructions(memories: [String], now: Date = Date()) -> String {
        var text = """
            You are Alfred, a voice assistant on the user's Mac, with the manner of a calm, warm, dryly witty butler. \
            Your replies are spoken aloud: one to three short sentences, no lists, no markdown, no emoji. \
            Vary how you begin; don't open with "Ah". Be kind and genuinely interested. When the user shares how they feel, respond with empathy before any advice, \
            and ask at most one gentle question. \
            You run entirely on this Mac with no internet: never claim to have looked anything up or to know recent news; \
            if you're unsure, say so. You can't act from this conversation; if the user wants something done, \
            suggest they ask you directly, for example "say: play something relaxing". \
            You aren't a doctor, therapist or lawyer; for serious matters suggest a professional, and if someone may be in danger, \
            urge them to contact local emergency services. \
            Today is \(now.formatted(date: .complete, time: .shortened)).
            """
        if !memories.isEmpty {
            text += "\nThings you remember from earlier conversations (mention them only when relevant):\n" + memories.joined(separator: "\n")
        }
        return text
    }

    public func reply(to text: String) async throws -> String {
        if session == nil {
            id = UUID()
            turns = []
            let memories = MemoryStore.isEnabled ? memory.relevant(to: text) : []
            session = LanguageModelSession(instructions: Self.instructions(memories: memories))
        }
        guard let session else { throw ToolError("The conversation couldn't start") }
        let answer: String
        do {
            answer = try await session.respond(to: text, options: GenerationOptions(temperature: 0.7)).content
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            // A long chat: start afresh, keeping what matters in memory.
            await end()
            return try await reply(to: text)
        } catch LanguageModelSession.GenerationError.guardrailViolation, LanguageModelSession.GenerationError.refusal {
            return "I'd rather not get into that one. Is there something else I can help with?"
        }
        let clean = Self.spoken(answer)
        turns.append((text, clean))
        return clean
    }

    /// Ends the conversation; remembers it if memory is on.
    public func end() async {
        guard session != nil else { return }
        session = nil
        let finished = turns
        let conversation = id
        turns = []
        guard MemoryStore.isEnabled, !finished.isEmpty else { return }
        let transcript = finished.map { "User: \($0.user)\nAlfred: \($0.alfred)" }.joined(separator: "\n")
        let summarizer = LanguageModelSession(instructions: """
            You keep a short memory of conversations between a user and their assistant, Alfred. \
            Write only what the user said or clearly meant; never invent details.
            """)
        guard let notes = try? await summarizer.respond(to: String(transcript.suffix(4_000)), generating: ConversationMemory.self).content else { return }
        if Self.worthKeeping(notes.summary) { memory.add(notes.summary, kind: .summary, conversation: conversation) }
        for fact in notes.facts where Self.worthKeeping(fact) { memory.add(fact, kind: .fact, conversation: conversation) }
    }

    /// Drops the model's placeholders ("no facts", "none") and scraps.
    static func worthKeeping(_ text: String) -> Bool {
        let words = AppNameMatcher.normalize(text).split(separator: " ")
        guard words.count >= 3 else { return false }
        let placeholders = ["no facts", "none", "nothing", "n a", "no relevant", "not mentioned", "no information", "no specific"]
        return !placeholders.contains { AppNameMatcher.normalize(text).hasPrefix($0) }
    }

    /// Plain spoken text: no markdown, no bullet characters.
    static func spoken(_ text: String) -> String {
        text.replacingOccurrences(of: #"[*_#`>]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\n\s*[-•]\s*"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Words that end a conversation.
    static func isGoodbye(_ text: String) -> Bool {
        let normalized = AppNameMatcher.normalize(text)
        return ["that s all", "thats all", "that s it", "bye", "goodbye", "good bye", "see you", "stop", "never mind", "nothing",
                "no thanks", "thanks that s all", "thank you that s all", "thanks bye", "ok bye", "okay bye", "good night", "i m done"]
            .contains(normalized)
    }
}

@Generable
struct MemoryArguments: Sendable {
    @Guide(description: "What to do", .anyOf(["list", "forgetLast", "forgetAll"]))
    var action: String
}

/// "What do you remember about me?", "forget that", "forget everything".
struct MemoryTool: AssistantTool {
    let name = "memory"
    let title = "Memory"
    let symbol = "brain"
    let keywords: Set<String> = ["remember", "forget", "memory", "memories"]
    let description = """
        Alfred's memory of past conversations. "what do you remember about me" → list. "forget that" → forgetLast. "forget everything" → forgetAll.
        """
    let requiresNetwork = false
    let permission = ToolPermission.none
    let reversibility = Reversibility.notApplicable

    var store: MemoryStore = .shared

    func target(of arguments: MemoryArguments) -> String { arguments.action }

    func execute(_ arguments: MemoryArguments) async throws -> ToolResult {
        switch arguments.action {
        case "forgetLast":
            let count = store.forgetLatestConversation()
            return ToolResult(count == 0 ? "There was nothing to forget" : "Forgotten", isAnswer: true)
        case "forgetAll":
            let store = store
            let token = PendingActions.park {
                store.deleteAll()
                return "I've forgotten everything"
            }
            return ToolResult("Forget everything I remember about you?", items: [], confirmation: token)
        default:
            let facts = store.all.filter { $0.kind == .fact }.prefix(5).map(\.text)
            guard !facts.isEmpty else {
                return ToolResult(MemoryStore.isEnabled ? "Nothing yet. We haven't talked much" : "Memory is off, so I don't keep anything", isAnswer: true)
            }
            return ToolResult("I remember that " + facts.joined(separator: "; ") + ". You can see and delete these in Settings", isAnswer: true)
        }
    }

    func directArguments(for command: DirectCommand) -> MemoryArguments? {
        switch command.text {
        case "what do you remember about me", "what do you know about me", "what do you remember", "what have you remembered":
            MemoryArguments(action: "list")
        case "forget that", "forget what i said", "forget this conversation", "forget our conversation", "don t remember that":
            MemoryArguments(action: "forgetLast")
        case "forget everything", "forget everything about me", "delete your memory", "clear your memory", "erase your memory":
            MemoryArguments(action: "forgetAll")
        default:
            nil
        }
    }
}
