import Foundation

/// A piece of a document small enough for the model, with where it came from.
struct DocumentChunk: Sendable, Equatable {
    /// "Pages 3–4", "Slide 2", or nil for a plain text file's part.
    let label: String?
    let text: String
}

/// Splits documents on their natural boundaries (sections, then
/// paragraphs), never mid-sentence at a fixed length when avoidable.
enum ContentChunker {
    /// About 1,500 tokens: room in a 4,096-token context for instructions,
    /// a question and the answer.
    static let chunkCharacters = 6_000

    static func chunks(_ document: ExtractedDocument, size: Int = chunkCharacters) -> [DocumentChunk] {
        var chunks: [DocumentChunk] = []
        var buffer = ""
        var labels: [String] = []

        func flush() {
            let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { chunks.append(DocumentChunk(label: combine(labels), text: text)) }
            buffer = ""
            labels = []
        }

        for section in document.sections where !section.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A section that fits joins the current chunk if there's room.
            if section.text.count <= size {
                if buffer.count + section.text.count > size { flush() }
                buffer += (buffer.isEmpty ? "" : "\n\n") + section.text
                if let label = section.label { labels.append(label) }
                continue
            }
            // A long section is split at paragraphs, then sentences.
            flush()
            for piece in split(section.text, size: size) {
                chunks.append(DocumentChunk(label: section.label, text: piece))
            }
        }
        flush()
        return chunks
    }

    private static func split(_ text: String, size: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        for paragraph in text.components(separatedBy: "\n") {
            let units = paragraph.count > size
                ? paragraph.components(separatedBy: ". ").map { $0 + ". " }
                : [paragraph + "\n"]
            for unit in units {
                if current.count + unit.count > size, !current.isEmpty {
                    pieces.append(current)
                    current = ""
                }
                // A single unit longer than the size is cut, as a last resort.
                var rest = Substring(unit)
                while rest.count > size {
                    pieces.append(String(rest.prefix(size)))
                    rest = rest.dropFirst(size)
                }
                current += rest
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { pieces.append(current) }
        return pieces
    }

    /// "Page 3", "Page 4", "Page 5" → "Pages 3–5".
    private static func combine(_ labels: [String]) -> String? {
        guard let first = labels.first else { return nil }
        guard labels.count > 1, let last = labels.last else { return first }
        let firstParts = first.split(separator: " "), lastParts = last.split(separator: " ")
        if firstParts.count == 2, lastParts.count == 2, firstParts[0] == lastParts[0] {
            return "\(firstParts[0])s \(firstParts[1])–\(lastParts[1])"
        }
        return "\(first) to \(last)"
    }

    /// The chunks most about the question, best first (term frequency ×
    /// rarity across the document's chunks).
    static func rank(_ chunks: [DocumentChunk], for question: String) -> [DocumentChunk] {
        let terms = Set(words(question).filter { $0.count > 2 && !stopWords.contains($0) })
        guard !terms.isEmpty else { return chunks }
        let chunkWords = chunks.map(words)
        let scores = chunkWords.map { tokens -> Double in
            terms.reduce(0) { total, term in
                let frequency = Double(tokens.filter { $0 == term || $0.hasPrefix(term) }.count)
                guard frequency > 0 else { return total }
                let containing = Double(chunkWords.filter { $0.contains { $0 == term || $0.hasPrefix(term) } }.count)
                return total + (1 + log(frequency)) * log(1 + Double(chunks.count) / containing)
            }
        }
        return zip(chunks, scores).sorted { $0.1 > $1.1 }.map(\.0)
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func words(_ chunk: DocumentChunk) -> [String] { words(chunk.text) }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "what", "does", "say", "about", "this", "that", "with", "from", "are", "was", "how", "much", "many",
        "which", "when", "where", "who", "its", "there", "their", "document", "file", "pdf", "tell", "me",
    ]
}

/// Summaries and answers about a document, with the model the router gives
/// for the task. Long documents are summarised in parts and then combined,
/// never cut off: a confident summary of half a document is worse than none.
enum DocumentReader {
    /// Beyond this many parts, Alfred offers to read a section instead.
    static let maximumChunks = 30

    static let system = """
        You read documents for the user of a Mac and report on them in plain spoken English. \
        Use only the text you are given; never invent names, numbers, dates or claims. \
        If the text doesn't contain the answer, say so. No markdown, no lists of more than a few items.
        """

    static func summarize(_ document: ExtractedDocument, progress: @Sendable (String) -> Void) async throws -> String {
        let chunks = ContentChunker.chunks(document)
        guard !chunks.isEmpty else { throw ToolError("\(document.name) has no text I can read") }
        guard chunks.count <= maximumChunks else {
            let units = document.unit.map { "\(document.sections.count) \($0)" } ?? "\(document.wordCount) words"
            throw ToolError("That's a very long document (\(units)). Ask for a part, like “summarise pages 1 to 10 of \(document.name)”")
        }
        let backend = ModelRouter.backend(for: chunks.count > 1 ? .analysis : .summarize)
        if chunks.count == 1 {
            return try await ask(backend, "Summarise this document in three to five sentences for someone about to read it.\n\n\(chunks[0].text)")
        }
        // Map: each part; reduce: the parts' summaries.
        var partial: [String] = []
        for (index, chunk) in chunks.enumerated() {
            progress("Long document: reading part \(index + 1) of \(chunks.count)")
            let label = chunk.label.map { " (\($0))" } ?? ""
            partial.append(try await ask(backend, "Summarise this part\(label) of a longer document in two or three sentences.\n\n\(chunk.text)"))
        }
        progress("Putting the summary together")
        let joined = partial.enumerated().map { "Part \($0.offset + 1): \($0.element)" }.joined(separator: "\n")
        return try await ask(backend, "These are summaries of consecutive parts of one document. Write one summary of the whole document in four to six sentences.\n\n\(String(joined.prefix(ContentChunker.chunkCharacters * 2)))")
    }

    static func answer(_ question: String, in document: ExtractedDocument, progress: @Sendable (String) -> Void) async throws -> String {
        let chunks = ContentChunker.chunks(document)
        guard !chunks.isEmpty else { throw ToolError("\(document.name) has no text I can read") }
        // The most relevant parts that fit in one request.
        var excerpts: [DocumentChunk] = []
        var used = 0
        for chunk in ContentChunker.rank(chunks, for: question) where used + chunk.text.count <= ContentChunker.chunkCharacters + 2_000 {
            excerpts.append(chunk)
            used += chunk.text.count
            if excerpts.count == 3 { break }
        }
        if excerpts.isEmpty, let first = chunks.first { excerpts = [DocumentChunk(label: first.label, text: String(first.text.prefix(ContentChunker.chunkCharacters)))] }
        if chunks.count > 1 { progress("Looking through \(document.name)") }
        let context = excerpts.map { chunk in (chunk.label.map { "[\($0)]\n" } ?? "") + chunk.text }.joined(separator: "\n\n")
        let backend = ModelRouter.backend(for: chunks.count > 1 ? .analysis : .summarize)
        return try await ask(backend, """
            Excerpts from \(document.name):
            \(context)

            Question: \(question)
            Answer in one to three sentences from the excerpts only. \(excerpts.contains { $0.label != nil }
                ? "Mention the page, slide or sheet in square brackets where the answer is."
                : "The text has no page numbers; don't mention any.")
            """)
    }

    private static func ask(_ backend: any ModelBackend, _ prompt: String) async throws -> String {
        do {
            return Conversation.spoken(try await backend.respond(system: system, prompt: prompt, temperature: 0.2))
        } catch {
            throw error.failure
        }
    }
}
