import AppKit
import ApplicationServices
import CoreServices
import FoundationModels

@Generable
struct ReadFileArguments: Sendable {
    @Guide(description: "What to do", .anyOf(["summarize", "ask", "part", "count", "search", "history"]))
    var action: String
    @Guide(description: "The file as the user referred to it, e.g. \"the contract\" or \"my invoice pdf\"; empty for \"this\"")
    var file: String?
    @Guide(description: "The question to answer (ask), or the words to look for (search)")
    var question: String?
    @Guide(description: "Which part, as said, e.g. \"page 3\", \"the second paragraph\", \"pages 1 to 10\"")
    var part: String?
    @Guide(description: "What to count", .anyOf(["pages", "words", "rows", "slides", "sheets", "paragraphs"]))
    var measure: String?
}

/// Reads files and answers about them: summaries, questions, a page or
/// paragraph, counts, and "which file mentions X". Everything happens on
/// this Mac. Only files in the allowed folders, never secrets or system
/// files (`ReadingAccess`), and nothing here can change a file.
struct ReadFileTool: AssistantTool {
    let name = "readFile"
    let title = "Read"
    let symbol = "doc.text.magnifyingglass"
    let keywords: Set<String> = ["summarise", "summarize", "summary", "read", "say", "says", "mention", "mentions", "pages", "words", "rows", "document", "pdf", "contract", "invoice", "report", "file"]
    let description = """
        Read a file and answer about it. "summarise the contract" → summarize, file "the contract". \
        "what does my invoice say about the total" → ask, file "my invoice", question. "read page 3 of the report" → part. \
        "how many pages in the thesis" → count, measure "pages". "find the file that mentions Hetzner" → search, question "Hetzner".
        """
    let requiresNetwork = false
    let permission = ToolPermission.files
    let reversibility = Reversibility.notApplicable

    func target(of arguments: ReadFileArguments) -> String {
        [arguments.file, arguments.part, arguments.question].compactMap { $0 }.first ?? "This document"
    }

    func execute(_ arguments: ReadFileArguments) async throws -> ToolResult {
        guard ReadingAccess.isEnabled else { throw ToolError("Reading files is turned off in Settings › Files") }
        switch arguments.action {
        case "history":
            let read = ReadLog.all.reversed().prefix(8).map(\.name)
            return ToolResult(read.isEmpty ? "I haven't read any files this session" : "This session I've read " + Self.list(read), isAnswer: true)
        case "search":
            return try await search(arguments.question ?? arguments.file ?? "")
        default:
            break
        }
        let url: URL
        switch try await Self.resolve(arguments.file) {
        case .file(let found): url = found
        case .ask(let question): return .ask(question)
        }
        switch ReadingAccess.check(url) {
        case .forbidden(let reason):
            throw ToolError(reason)
        case .outsideFolders(let folder):
            // Offer to allow the folder, then do what was asked.
            let token = PendingActions.park {
                ReadingAccess.setFolders(ReadingAccess.folders + [folder])
                return try await Self.perform(arguments, on: url).text
            }
            let item = ResultItem(id: token, title: folder.lastPathComponent, detail: folder.deletingLastPathComponent().path, symbol: "folder")
            return ToolResult("\(url.lastPathComponent) is in \(folder.lastPathComponent), which I'm not allowed to read. Allow that folder?", items: [item], confirmation: token)
        case .allowed(let allowed):
            return try await Self.perform(arguments, on: allowed)
        }
    }

    static func perform(_ arguments: ReadFileArguments, on url: URL) async throws -> ToolResult {
        CommandContext.report("Reading \(url.lastPathComponent)")
        var document = try await ContentExtractor.extract(url)
        ReadLog.record(url)
        let progress: @Sendable (String) -> Void = { CommandContext.report($0) }
        let answer: String
        switch arguments.action {
        case "count":
            answer = count(arguments.measure ?? "pages", in: document)
        case "part":
            guard let part = arguments.part, let text = Section.text(part, in: document) else {
                throw ToolError("Which part? Say “page 3” or “the second paragraph”")
            }
            answer = text.count > 1_500 ? String(text.prefix(1_500)) + "… That part goes on; ask me to summarise it." : text
        case "ask":
            guard let question = arguments.question ?? CommandContext.transcript else { throw ToolError("What would you like to know about it?") }
            if let part = arguments.part, let narrowed = Section.restricted(document, to: part) { document = narrowed }
            answer = try await DocumentReader.answer(question, in: document, progress: progress)
        default:
            if let part = arguments.part, let narrowed = Section.restricted(document, to: part) { document = narrowed }
            if ContentChunker.chunks(document).count > 1 { progress("That's a long document; summarising it in parts") }
            answer = try await DocumentReader.summarize(document, progress: progress)
        }
        // Never speak or show secrets found in a document.
        return ToolResult(SecretRedactor.redact(answer), isAnswer: true)
    }

    static func count(_ measure: String, in document: ExtractedDocument) -> String {
        let name = document.name
        switch measure {
        case "words": return "\(name) has about \(document.wordCount.formatted()) words"
        case "rows":
            guard let rows = document.rows else { return "\(name) isn't a spreadsheet" }
            return "\(name) has \(rows.formatted()) rows"
        case "paragraphs": return "\(name) has \(document.paragraphs.count) paragraphs"
        default:
            guard let unit = document.unit else { return "\(name) has about \(document.wordCount.formatted()) words; it isn't split into pages" }
            return "\(name) has \(document.sections.count) \(document.sections.count == 1 ? String(unit.dropLast()) : unit)"
        }
    }

    // MARK: Which file

    enum Resolution { case file(URL), ask(String) }

    private static let thisWords: Set<String> = ["", "this", "it", "that", "this document", "this file", "this pdf", "the document", "this one", "that one", "that file", "that document"]

    /// "this" → the document in front (else the last one read); a
    /// screenshot → the latest; otherwise a name search in the allowed
    /// folders.
    static func resolve(_ spoken: String?) async throws -> Resolution {
        let text = AppNameMatcher.normalize(spoken ?? "")
        if thisWords.contains(text) {
            if let front = await frontDocument() { return .file(front) }
            if let last = ReadLog.last { return .file(last) }
            return .ask("Which file? Open it, or say its name")
        }
        var query = FileQuery(spoken: text) ?? FileQuery(text: text, kind: nil, period: nil)
        if query.words.isEmpty, query.kind == nil { query = FileQuery(text: text, kind: nil, period: nil) }
        guard query.isSpecific else { return .ask("Which file?") }
        let roots = Array(Set(ReadingAccess.folders + FileAccess.scopedRoots))
        let found = try await SpotlightSearch.run(query, limit: 5, roots: roots)
        guard let best = found.first else { throw ToolError("I couldn't find “\(spoken ?? "")” in \(Self.list(ReadingAccess.folders.map(\.lastPathComponent)))") }
        return .file(best.url)
    }

    /// The file open in the front window (Preview, Word, TextEdit…), from
    /// Accessibility's AXDocument.
    @MainActor
    static func frontDocument() -> URL? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success, let window else { return nil }
        var document: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, "AXDocument" as CFString, &document) == .success,
              let value = document as? String, let url = URL(string: value), url.isFileURL else { return nil }
        return url
    }

    // MARK: Content search

    /// Files in the allowed folders whose text contains the words, from
    /// Spotlight's index (so no file is opened to search).
    func search(_ phrase: String) async throws -> ToolResult {
        let words = SpokenWords(phrase).lower.filter { $0.count > 1 && !["the", "a", "an", "about", "that", "which", "file", "files", "document"].contains($0) }
        guard !words.isEmpty else { return .ask("What should the file mention?") }
        let folders = ReadingAccess.folders
        let found = await Self.spotlightContent(words, in: folders)
            .filter { if case .allowed = ReadingAccess.check($0.url) { true } else { false } }
        let scope = Self.list(folders.map(\.lastPathComponent))
        guard !found.isEmpty else { return ToolResult("No file in \(scope) mentions “\(phrase)”", isAnswer: true) }
        let shown = Array(found.prefix(FindFilesTool.limit))
        return ToolResult("\(found.count > shown.count ? "\(shown.count)+" : "\(found.count)") in \(scope) mention “\(phrase)” — click one to open", items: FileTokens.register(shown))
    }

    static func spotlightContent(_ words: [String], in folders: [URL]) async -> [FoundFile] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let clauses = words.map { "kMDItemTextContent == \"*\($0)*\"cd" }.joined(separator: " && ")
                guard let query = MDQueryCreate(kCFAllocatorDefault, clauses as CFString, nil, nil) else {
                    continuation.resume(returning: [])
                    return
                }
                MDQuerySetSearchScope(query, folders.map { $0.path(percentEncoded: false) } as CFArray, 0)
                MDQuerySetMaxCount(query, 50)
                guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else {
                    continuation.resume(returning: [])
                    return
                }
                let files: [FoundFile] = (0..<MDQueryGetResultCount(query)).compactMap { index in
                    guard let raw = MDQueryGetResultAtIndex(query, index) else { return nil }
                    let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
                    guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { return nil }
                    let date = MDItemCopyAttribute(item, kMDItemFSContentChangeDate) as? Date ?? .distantPast
                    return FoundFile(url: URL(filePath: path), name: URL(filePath: path).lastPathComponent, date: date)
                }
                continuation.resume(returning: files.sorted { $0.date > $1.date })
            }
        }
    }

    static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    // MARK: Direct phrasings

    /// Words that make a phrase a file reference ("that invoice").
    static let fileNouns: Set<String> = [
        "file", "document", "doc", "pdf", "contract", "invoice", "report", "essay", "paper", "thesis", "receipt", "statement", "letter",
        "notes", "slides", "presentation", "deck", "spreadsheet", "sheet", "cv", "resume", "screenshot", "email", "article", "chapter",
        "assignment", "manual", "agreement", "proposal", "brief", "memo", "transcript", "book", "form", "lease", "policy", "syllabus",
    ]

    static func looksLikeFile(_ text: String) -> Bool {
        let words = AppNameMatcher.normalize(text).split(separator: " ").map(String.init)
        guard !words.isEmpty, words.count <= 8 else { return false }
        if thisWords.contains(words.joined(separator: " ")) { return true }
        if words.contains(where: fileNouns.contains) { return true }
        if let last = words.last, OpenFileTool.extensions.contains(last) { return true }
        return FileQuery(spoken: text) != nil
    }

    private static func match(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<found.numberOfRanges).map { index in
            Range(found.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    func directArguments(for command: DirectCommand) -> ReadFileArguments? {
        let text = command.text
        let original = command.original.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".?!")))

        if ["what have you read", "which files have you read", "what files have you read", "what did you read", "what have you read today"].contains(text) {
            return ReadFileArguments(action: "history")
        }
        // "find the file that mentions X", "which file mentions X", "search my files for X".
        if let m = Self.match(#"^(?:find|show me|which|what|search for)\s+(?:the\s+|a\s+|my\s+)?(?:file|files|document|documents|pdf|pdfs)\s+(?:that\s+|which\s+)?(?:mentions?|contains?|says?|talks? about|is about)\s+(.+)$"#, original)
            ?? Self.match(#"^search (?:inside )?my (?:files|documents) for\s+(.+)$"#, original) {
            return ReadFileArguments(action: "search", question: m[1])
        }
        // "how many pages are in the thesis", "word count of my essay".
        if let m = Self.match(#"^how many (pages|words|rows|slides|sheets|paragraphs) (?:are there |are )?(?:in|does|has)\s+(.+?)(?:\s+have)?$"#, original),
           Self.looksLikeFile(m[2]) {
            return ReadFileArguments(action: "count", file: m[2], measure: m[1].lowercased())
        }
        if let m = Self.match(#"^(?:what'?s the |what is the )?word count (?:of|for|in)\s+(.+)$"#, original), Self.looksLikeFile(m[1]) {
            return ReadFileArguments(action: "count", file: m[1], measure: "words")
        }
        // "summarise this", "summarise the contract", "give me a summary of my notes", "what's the report about".
        if let m = Self.match(#"^(?:summari[sz]e|sum up|give me a summary of|what'?s the gist of)\s*(.*)$"#, original) {
            var file = m[1]
            var part: String?
            // "summarise pages 1 to 10 of the report".
            if let p = Self.match(#"^((?:the )?(?:pages?|slides?|sections?|chapters?) .+?) of (.+)$"#, file) {
                part = p[1]
                file = p[2]
            }
            // "summarise this page" is the screen, not a file.
            if ["this page", "the page", "this web page", "this webpage", "this website", "this site", "my screen", "the screen", "this screen"].contains(AppNameMatcher.normalize(file)) { return nil }
            // The meeting transcript has its own tool.
            if ["meeting", "transcript", "recording", "call", "that"].contains(where: { AppNameMatcher.normalize(file).contains($0) }) && !Self.fileNouns.contains(where: file.lowercased().contains) { return nil }
            guard Self.looksLikeFile(file) || file.isEmpty else { return nil }
            return ReadFileArguments(action: "summarize", file: file, part: part)
        }
        if let m = Self.match(#"^what'?s (.+?) about$"#, original) ?? Self.match(#"^what is (.+?) about$"#, original), Self.looksLikeFile(m[1]) {
            return ReadFileArguments(action: "summarize", file: m[1])
        }
        // "read page 3 of the report", "read me the second paragraph of my essay", "read me the contract".
        if let m = Self.match(#"^read(?: me| out)?\s+(?:the\s+)?(.+?)\s+of\s+(.+)$"#, original),
           Section.parse(m[1]) != nil, Self.looksLikeFile(m[2]) {
            return ReadFileArguments(action: "part", file: m[2], part: m[1])
        }
        if let m = Self.match(#"^read(?: me| out)?\s+(.+)$"#, original), Self.looksLikeFile(m[1]),
           !["the time", "my messages", "my email", "my emails", "my notifications"].contains(AppNameMatcher.normalize(m[1])) {
            return ReadFileArguments(action: "part", file: m[1], part: "the beginning")
        }
        // "what does the contract say about notice", "does my lease mention pets".
        if let m = Self.match(#"^what does (.+?) say (?:about|on|regarding)\s+(.+)$"#, original), Self.looksLikeFile(m[1]) {
            return ReadFileArguments(action: "ask", file: m[1], question: original)
        }
        if let m = Self.match(#"^(?:does|do) (.+?) (?:mention|say anything about|talk about|cover)\s+(.+)$"#, original), Self.looksLikeFile(m[1]) {
            return ReadFileArguments(action: "ask", file: m[1], question: original)
        }
        // "what's the total on that invoice", "who signed the contract", "in my notes, what's the deadline".
        if let m = Self.match(#"^(?:what|who|when|where|how much|how many|which|is|are)\b.+?\b(?:on|in|of)\s+((?:this|that|the|my)\s+.+)$"#, original),
           Self.fileNouns.contains(where: { AppNameMatcher.normalize(m[1]).split(separator: " ").map(String.init).contains($0) }) {
            return ReadFileArguments(action: "ask", file: m[1], question: original)
        }
        return nil
    }
}

/// Parts of a document as people name them: "page 3", "pages 1 to 10",
/// "the second paragraph", "row 12", "slide 4", "the beginning".
enum Section {
    enum Part: Equatable {
        case pages(ClosedRange<Int>)
        case paragraph(Int)
        case row(Int)
        case beginning
    }

    private static let ordinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
        "last": -1,
    ]

    static func parse(_ spoken: String) -> Part? {
        let words = SpokenWords(spoken).lower.filter { $0 != "the" }
        guard !words.isEmpty else { return nil }
        if words.contains("beginning") || words.contains("start") { return .beginning }
        func number(_ word: String) -> Int? {
            if let ordinal = ordinals[word] { return ordinal }
            let digits = word.filter(\.isNumber)
            return Int(digits.isEmpty ? "" : digits) ?? SpokenWords(word).number(at: 0).map { Int($0.value) }
        }
        let unit = words.first { ["page", "pages", "slide", "slides", "paragraph", "row", "sheet", "section", "chapter"].contains($0) }
        guard let unit else { return nil }
        let numbers = words.compactMap(number)
        guard let first = numbers.first else { return nil }
        switch unit {
        case "paragraph": return .paragraph(first)
        case "row": return .row(first)
        default:
            let last = numbers.count > 1 ? numbers[1] : first
            return first > 0 && last >= first ? .pages(first...last) : (first == -1 ? .pages(-1 ... -1) : nil)
        }
    }

    /// The text of that part, or nil if the document doesn't have it.
    static func text(_ spoken: String, in document: ExtractedDocument) -> String? {
        guard let part = parse(spoken) else { return nil }
        switch part {
        case .beginning:
            return String(document.text.prefix(1_200))
        case .paragraph(let n):
            let paragraphs = document.paragraphs
            let index = n == -1 ? paragraphs.count - 1 : n - 1
            return paragraphs.indices.contains(index) ? paragraphs[index] : nil
        case .row(let n):
            let rows = document.text.components(separatedBy: "\n").filter { !$0.isEmpty }
            let index = n == -1 ? rows.count - 1 : n - 1
            return rows.indices.contains(index) ? rows[index].replacingOccurrences(of: "\t", with: ", ") : nil
        case .pages:
            return restricted(document, to: spoken)?.text
        }
    }

    /// The document narrowed to those pages, slides or sheets.
    static func restricted(_ document: ExtractedDocument, to spoken: String) -> ExtractedDocument? {
        guard case .pages(let range)? = parse(spoken), !document.sections.isEmpty else { return nil }
        let count = document.sections.count
        let lower = range.lowerBound == -1 ? count : range.lowerBound
        let upper = range.upperBound == -1 ? count : min(range.upperBound, count)
        guard lower >= 1, lower <= upper else { return nil }
        return ExtractedDocument(name: document.name, sections: Array(document.sections[(lower - 1)..<upper]), unit: document.unit,
                                 rows: document.rows, recognizedPages: document.recognizedPages)
    }
}

/// plan-cli --read: extract a file and summarise it or answer a question,
/// with the real model, outside the app.
public enum ReadingDebug {
    public static func run(path: String, question: String?) async throws -> String {
        let url = URL(filePath: (path as NSString).expandingTildeInPath)
        let document = try await ContentExtractor.extract(url)
        let header = "\(document.name): \(document.sections.count) section(s), \(document.wordCount) words, \(ContentChunker.chunks(document).count) chunk(s)\n"
        let progress: @Sendable (String) -> Void = { print("  … \($0)") }
        if let question {
            return header + (try await DocumentReader.answer(question, in: document, progress: progress))
        }
        return header + (try await DocumentReader.summarize(document, progress: progress))
    }
}
