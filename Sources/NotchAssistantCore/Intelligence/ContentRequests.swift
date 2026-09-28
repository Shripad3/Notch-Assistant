/// Requests to read a file's contents, declined before the model sees them
/// (spec §1: "No file contents, ever"). Given "read me what's in my notes
/// file", the model searched the web instead of saying no.
enum ContentRequests {
    static let refusal = "I can read files, but I never change what's inside them. I can rename, move, copy or trash them."

    /// Changing a file's contents stays impossible (spec §9); reading is a
    /// tool (`readFile`).
    static func refusal(for transcript: String) -> String? {
        let text = " " + AppNameMatcher.normalize(transcript) + " "
        let patterns = [" edit my ", " edit the ", " change the text ", " rewrite my ", " rewrite the ", " write to my ", " write into my ",
                        " add a line to ", " delete the line ", " remove the line ", " fix the typo ", " fix the typos ", " modify my ",
                        " modify the ", " update the text ", " replace the word ", " append to my "]
        return patterns.contains(where: text.contains) ? refusal : nil
    }
}
