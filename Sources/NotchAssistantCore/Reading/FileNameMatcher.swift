import Foundation

/// Finds a file from a name as speech recognition heard it: "to XQ 40
/// assignment 12PDF" for 2XQ40-assignment12.pdf. Both sides become a
/// compact key of letters and digits, with number words as digits, then
/// the closest name wins if it is clearly the closest.
enum FileNameMatcher {
    static let threshold = 0.75

    private static let numberWords: [String: String] = [
        "zero": "0", "oh": "0", "one": "1", "won": "1", "two": "2", "to": "2", "too": "2", "three": "3", "four": "4", "for": "4",
        "five": "5", "six": "6", "seven": "7", "eight": "8", "ate": "8", "nine": "9", "ten": "10",
    ]
    /// Spoken filler around a name ("the file called …").
    private static let filler: Set<String> = ["the", "a", "my", "file", "called", "named", "document", "dot"]

    /// "12PDF" → "12 pdf": recognisers glue a spoken extension onto a number.
    static func separateExtension(_ spoken: String) -> String {
        let extensions = OpenFileTool.extensions.sorted { $0.count > $1.count }.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: "(\\d)(\(extensions))\\b", options: [.caseInsensitive]) else { return spoken }
        return regex.stringByReplacingMatches(in: spoken, range: NSRange(spoken.startIndex..., in: spoken), withTemplate: "$1 $2")
    }

    /// The spoken name as a key, and the extension said, if any.
    static func spokenKey(_ spoken: String) -> (key: String, extension: String?) {
        var words = AppNameMatcher.normalize(separateExtension(spoken)).split(separator: " ").map(String.init)
        var ext: String?
        if let last = words.last, OpenFileTool.extensions.contains(last) {
            ext = last
            words.removeLast()
        }
        while let first = words.first, filler.contains(first), words.count > 1 { words.removeFirst() }
        // "to" and "for" are numbers only in a name, not between words:
        // at the start, or next to a number.
        let key = words.enumerated().map { index, word -> String in
            guard let digit = numberWords[word] else { return word }
            if ["to", "too", "for", "won", "ate", "oh"].contains(word) {
                let neighbours = [index > 0 ? words[index - 1] : nil, index + 1 < words.count ? words[index + 1] : nil].compactMap { $0 }
                let nearCode = index == 0 || neighbours.contains { $0.contains(where: \.isNumber) }
                return nearCode ? digit : word
            }
            return digit
        }.joined()
        return (compact(key), ext)
    }

    /// A file name as a key: letters and digits of its stem.
    static func fileKey(_ name: String) -> String {
        compact((name as NSString).deletingPathExtension)
    }

    private static func compact(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// The best match if it is close enough and clearly ahead of the next.
    static func best(for spoken: String, among urls: [URL]) -> URL? {
        let (key, ext) = spokenKey(spoken)
        guard key.count >= 3 else { return nil }
        let candidates = urls.filter { ext == nil || $0.pathExtension.lowercased() == ext || (ext == "doc" && $0.pathExtension.lowercased() == "docx") }
        let scored = candidates.map { ($0, AppNameMatcher.similarity(key, fileKey($0.lastPathComponent))) }
            .sorted { $0.1 > $1.1 }
        guard let top = scored.first, top.1 >= threshold else { return nil }
        if scored.count > 1, scored[1].1 > top.1 - 0.05, fileKey(scored[1].0.lastPathComponent) != fileKey(top.0.lastPathComponent) { return nil }
        return top.0
    }

    /// Every file in the folders (from Spotlight's index, newest first), to
    /// compare names against.
    static func files(in folders: [URL], limit: Int = 5_000) async -> [URL] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let clause = "kMDItemContentTypeTree != \"public.folder\" && kMDItemFSName == \"*\""
                guard let query = MDQueryCreate(kCFAllocatorDefault, clause as CFString, nil, nil) else {
                    continuation.resume(returning: [])
                    return
                }
                MDQuerySetSearchScope(query, folders.map { $0.path(percentEncoded: false) } as CFArray, 0)
                MDQuerySetMaxCount(query, limit)
                guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else {
                    continuation.resume(returning: [])
                    return
                }
                let urls: [URL] = (0..<MDQueryGetResultCount(query)).compactMap { index in
                    guard let raw = MDQueryGetResultAtIndex(query, index) else { return nil }
                    let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
                    return (MDItemCopyAttribute(item, kMDItemPath) as? String).map { URL(filePath: $0) }
                }
                continuation.resume(returning: urls)
            }
        }
    }
}
