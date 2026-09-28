@testable import NotchAssistantCore
import Testing

struct SpeechTextTests {
    @Test(arguments: [
        ("Alarm set for 07:00 on weekdays", "Alarm set for 7 A M on weekdays"),
        ("You have 2 alarms: 07:00 on weekdays, 08:00 at weekends", "You have 2 alarms: 7 A M on weekdays, 8 A M at weekends"),
        ("It's 18:30.", "It's 6 30 PM."),
        ("Alarm set for 7:05\u{202F}AM", "Alarm set for 7 oh 5 A M"),
        ("Snoozed until 12:00", "Snoozed until 12 noon"),
        ("tomorrow at 00:00", "tomorrow at midnight"),
        ("It's 3:45 PM", "It's 3 45 PM"),
        ("Reminder at 6 PM, alarm at 7 a.m.", "Reminder at 6 PM, alarm at 7 A M"),
        ("It's −3° and snowy. High 2°, low -5°. 40% chance of rain.", "It's minus 3 degrees and snowy. High 2 degrees, low minus 5 degrees. 40 percent chance of rain."),
        ("Stopwatch resumed at 1:23.4", "Stopwatch resumed at 1 minute 23.4 seconds"),
        ("Timer set for 10 minutes", "Timer set for 10 minutes"),
        ("pages 10-20", "pages 10-20"),
        ("I am here", "I am here"),
    ])
    func rewrites(display: String, spoken: String) {
        #expect(SpeechText.forNeuralVoice(display) == spoken)
    }
}

struct SpeechPiecesTests {
    @Test func longRepliesAreSplitForTheNaturalVoice() {
        let long = "This document describes a structured-output schema for a tool that can be used to generate a plan of action for a user, including every step, its arguments, and the order in which they run, which the assistant then executes. It has three parts. Done!"
        let pieces = SpeechText.pieces(long)
        #expect(pieces.allSatisfy { $0.count <= 180 })
        #expect(pieces.joined(separator: " ").split(separator: " ") == long.split(separator: " "))
        #expect(pieces.last == "Done!")
    }

    @Test func shortRepliesStayWhole() {
        #expect(SpeechText.pieces("Timer set for 10 minutes") == ["Timer set for 10 minutes"])
    }
}
