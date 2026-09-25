/// Requests to read a file's contents, declined before the model sees them
/// (spec §1: "No file contents, ever"). Given "read me what's in my notes
/// file", the model searched the web instead of saying no.
enum ContentRequests {
    static let refusal = "I can't read what's inside files. I can find, open, rename, move or trash them."

    static func refusal(for transcript: String) -> String? {
        let text = " " + AppNameMatcher.normalize(transcript) + " "
        let patterns = [" read me ", " read my ", " read the ", " what s in my ", " what s inside ", " what is in my ",
                        " summarise my ", " summarize my ", " summarise the ", " summarize the ", " what does my "]
        return patterns.contains(where: text.contains) ? refusal : nil
    }
}
