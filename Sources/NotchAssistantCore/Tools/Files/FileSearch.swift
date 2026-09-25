import Foundation

/// What a file request says: name words, an optional kind and time period.
/// Everything here is metadata; there is no way to express "a file that
/// mentions X", because the agent never reads file contents (spec §9).
struct FileQuery: Sendable, Equatable {
    var words: [String]
    var kind: FileKind?
    var period: FilePeriod?
    /// Restricts the search to one scoped root ("on my desktop").
    var folder: String?

    private static let stopWords: Set<String> = [
        "my", "the", "a", "an", "file", "files", "from", "of", "that", "this", "latest", "recent", "last",
        "called", "named", "list", "all", "every", "in", "on", "at", "folder", "s", "show", "me", "any",
        // "Everything in Downloads" is every file there, not one named "everything".
        "everything", "anything", "stuff", "things",
    ]

    /// Spoken folder names → scoped root folder names.
    static let folders: [String: String] = [
        "desktop": "Desktop", "documents": "Documents", "document folder": "Documents",
        "downloads": "Downloads", "download folder": "Downloads",
    ]

    init(words: [String], kind: FileKind? = nil, period: FilePeriod? = nil, folder: String? = nil) {
        self.words = words
        self.kind = kind
        self.period = period
        self.folder = folder
    }

    /// From the model's free-text query, e.g. "tax invoice". With a kind,
    /// words naming that kind are dropped: "screenshots" would not match
    /// files called "Screenshot …".
    init(text: String, kind: FileKind?, period: FilePeriod?, folder: String? = nil) {
        self.init(
            words: AppNameMatcher.normalize(text).split(separator: " ").map(String.init)
                .filter { $0.count >= 2 && !Self.stopWords.contains($0) }
                .filter { kind == nil || FileKind(spokenWord: $0) != kind },
            kind: kind,
            period: period,
            folder: folder
        )
    }

    /// True when there is anything to search by.
    var isSpecific: Bool {
        !words.isEmpty || kind != nil || period != nil || folder != nil
    }

    /// Parses a spoken description directly: "my invoice pdf from last month".
    /// Returns nil unless it clearly describes a file (a leading "my", a file
    /// kind or a time period), so "open spotify" is never mistaken for one.
    init?(spoken: String) {
        var text = " " + AppNameMatcher.normalize(spoken) + " "
        var folder: String?
        for (phrase, root) in Self.folders {
            for preposition in ["in my", "on my", "in the", "on the", "in", "on", "from my", "from the"]
            where text.contains(" \(preposition) \(phrase) ") {
                folder = root
                text = text.replacingOccurrences(of: " \(preposition) \(phrase) ", with: " ")
            }
        }
        var period: FilePeriod?
        for candidate in FilePeriod.allCases {
            for phrase in candidate.phrases where text.contains(" \(phrase) ") {
                period = candidate
                text = text.replacingOccurrences(of: " \(phrase) ", with: " ")
            }
        }
        var kind: FileKind?
        var words: [String] = []
        for word in text.split(separator: " ").map(String.init) {
            if kind == nil, let match = FileKind(spokenWord: word) {
                kind = match
            } else {
                words.append(word)
            }
        }
        let describesFile = words.first == "my" || words.contains("file") || words.contains("files")
            || kind != nil || period != nil || folder != nil
        guard describesFile else { return nil }
        self.init(text: words.joined(separator: " "), kind: kind, period: period, folder: folder)
        guard isSpecific else { return nil }
    }
}

enum FileKind: String, CaseIterable, Sendable {
    case document, pdf, image, screenshot, video, audio, spreadsheet, presentation, folder

    init?(spokenWord: String) {
        switch spokenWord {
        case "pdf", "pdfs": self = .pdf
        case "document", "documents", "doc", "docs": self = .document
        case "photo", "photos", "picture", "pictures", "image", "images": self = .image
        case "screenshot", "screenshots": self = .screenshot
        case "video", "videos", "movie", "movies", "recording": self = .video
        case "audio", "voice memo", "podcast": self = .audio
        case "spreadsheet", "spreadsheets", "excel", "sheet": self = .spreadsheet
        case "presentation", "presentations", "slides", "deck", "keynote", "powerpoint": self = .presentation
        case "folder", "folders": self = .folder
        default: return nil
        }
    }

    /// Uniform type for Spotlight's kMDItemContentTypeTree.
    var contentType: String {
        switch self {
        case .document: "public.content"
        case .pdf: "com.adobe.pdf"
        case .image, .screenshot: "public.image"
        case .video: "public.movie"
        case .audio: "public.audio"
        case .spreadsheet: "public.spreadsheet"
        case .presentation: "public.presentation"
        case .folder: "public.folder"
        }
    }
}

enum FilePeriod: String, CaseIterable, Sendable {
    case today, yesterday, thisWeek, lastWeek, thisMonth, lastMonth, thisYear, lastYear

    var phrases: [String] {
        switch self {
        case .today: ["from today", "today"]
        case .yesterday: ["from yesterday", "yesterday"]
        case .thisWeek: ["from this week", "this week"]
        case .lastWeek: ["from last week", "last week"]
        case .thisMonth: ["from this month", "this month"]
        case .lastMonth: ["from last month", "last month"]
        case .thisYear: ["from this year", "this year"]
        case .lastYear: ["from last year", "last year"]
        }
    }

    func range(now: Date = Date(), calendar: Calendar = .current) -> Range<Date> {
        func start(_ component: Calendar.Component, offset: Int) -> Date {
            let base = calendar.dateInterval(of: component, for: now)!.start
            return calendar.date(byAdding: component, value: offset, to: base)!
        }
        return switch self {
        case .today: start(.day, offset: 0)..<start(.day, offset: 1)
        case .yesterday: start(.day, offset: -1)..<start(.day, offset: 0)
        case .thisWeek: start(.weekOfYear, offset: 0)..<start(.weekOfYear, offset: 1)
        case .lastWeek: start(.weekOfYear, offset: -1)..<start(.weekOfYear, offset: 0)
        case .thisMonth: start(.month, offset: 0)..<start(.month, offset: 1)
        case .lastMonth: start(.month, offset: -1)..<start(.month, offset: 0)
        case .thisYear: start(.year, offset: 0)..<start(.year, offset: 1)
        case .lastYear: start(.year, offset: -1)..<start(.year, offset: 0)
        }
    }
}

/// One search result. The path never leaves the executor: the model and the
/// UI see only the name and date.
struct FoundFile: Sendable, Equatable {
    let url: URL
    let name: String
    let date: Date
}

enum FileRanking {
    /// Best first: how well the name matches the words, then most recent.
    static func rank(_ files: [FoundFile], for query: FileQuery) -> [FoundFile] {
        files
            .map { ($0, nameScore($0.name, query.words)) }
            .sorted { ($0.1, $0.0.date) > ($1.1, $1.0.date) }
            .map(\.0)
    }

    /// 3: the name is exactly the words. 2: every word is a whole word of the
    /// name. 1: the words appear inside the name. 0: no words to match.
    static func nameScore(_ name: String, _ words: [String]) -> Int {
        guard !words.isEmpty else { return 0 }
        let stem = (name as NSString).deletingPathExtension
        let nameWords = AppNameMatcher.normalize(stem).split(separator: " ").map(String.init)
        if nameWords == words { return 3 }
        if words.allSatisfy(nameWords.contains) { return 2 }
        return 1
    }
}
