import Foundation
@testable import NotchAssistantCore
import Testing

struct CommunicationTests {
    static let people = [
        Person(id: "1", name: "Shripad Kulkarni", spokenNames: ["Shripad Kulkarni", "Shripad", "Kulkarni"],
               phones: [.init(label: "mobile", value: "+31 6 1234 5678")], emails: [.init(label: "home", value: "s@example.com")]),
        Person(id: "2", name: "Anjali Kulkarni", spokenNames: ["Anjali Kulkarni", "Anjali", "Kulkarni", "amma", "mum", "mom"],
               phones: [.init(label: "home", value: "+91 20 1234"), .init(label: "mobile", value: "+91 98 7654 3210")], emails: []),
        Person(id: "3", name: "Aditya Rao", spokenNames: ["Aditya Rao", "Aditya", "Rao"],
               phones: [.init(label: "iPhone", value: "+91 99 0000 1111")], emails: [.init(label: "work", value: "aditya@uni.example")]),
        Person(id: "4", name: "Sam Smith", spokenNames: ["Sam Smith", "Sam", "Smith"], phones: [.init(label: "mobile", value: "+44 7700 900000")], emails: []),
        Person(id: "5", name: "Sam Patel", spokenNames: ["Sam Patel", "Sam", "Patel"], phones: [.init(label: "mobile", value: "+44 7700 900001")], emails: []),
        Person(id: "6", name: "Vivek Sharma", spokenNames: ["Vivek Sharma", "Vivek", "Sharma"], phones: [.init(label: "mobile", value: "+91 1")], emails: []),
    ]
    let book = ContactBook(Self.people)

    @Test(arguments: [
        ("Shripad", "Shripad Kulkarni"),
        ("Sri pad", "Shripad Kulkarni"),
        ("sripad", "Shripad Kulkarni"),
        ("Adithya", "Aditya Rao"),
        ("aditya rao", "Aditya Rao"),
        ("Amma", "Anjali Kulkarni"),
        ("my mum", "Anjali Kulkarni"),
        ("Wiwek", "Vivek Sharma"),
        ("Sam Patel", "Sam Patel"),
    ])
    func findsPeople(said: String, name: String) {
        #expect(book.find(said) == .one(Self.people.first { $0.name == name }!))
    }

    @Test func ambiguousAndUnknown() {
        if case .several(let people) = book.find("Sam") { #expect(people.count == 2) } else { Issue.record("expected two Sams") }
        #expect(book.find("Gandalf") == .none)
    }

    @Test func prefersMobileNumbers() {
        #expect(Self.people[1].bestPhone?.value == "+91 98 7654 3210")
        #expect(Recipients.dialable("+91 98 7654 3210") == "+919876543210")
    }

    @Test(arguments: [
        ("call Amma", "Amma", "phone"),
        ("Call Sri pad.", "Sri pad", "phone"),
        ("FaceTime Aditya", "Aditya", "facetime"),
        ("facetime audio Sam Patel", "Sam Patel", "facetimeAudio"),
        ("call Sam on FaceTime", "Sam", "facetime"),
    ])
    func callPhrases(said: String, person: String, via: String) throws {
        let args = try #require(DirectCommand(said).flatMap { CallTool(book: book).directArguments(for: $0) })
        #expect(args.person == person)
        #expect(args.via == via)
    }

    @Test(arguments: [
        ("tell Sam Patel I'm running 10 minutes late", "Sam Patel", "I'm running 10 minutes late", "messages"),
        ("text Amma that I'll be home by 7", "Amma", "I'll be home by 7", "messages"),
        ("message Aditya saying see you at the library", "Aditya", "see you at the library", "messages"),
        ("WhatsApp Amma I'll call later", "Amma", "I'll call later", "whatsapp"),
        ("text Aditya on WhatsApp that the lecture moved", "Aditya", "the lecture moved", "whatsapp"),
        ("send a message to Shripad saying hello", "Shripad", "hello", "messages"),
    ])
    func messagePhrases(said: String, person: String, text: String, app: String) throws {
        let args = try #require(DirectCommand(said).flatMap { MessageTool(book: book).directArguments(for: $0) })
        #expect(args.person == person)
        #expect(args.text == text)
        #expect(args.app == app)
    }

    @Test(arguments: [
        ("email Aditya that I'll miss Tuesday's lecture", "Aditya", nil as String?, "I'll miss Tuesday's lecture", "default"),
        ("email Aditya from my uni account saying the report is attached", "Aditya", nil, "the report is attached", "outlook"),
        ("send an email to Shripad about dinner saying are you free Friday", "Shripad", "dinner", "are you free Friday", "default"),
        ("email Shripad from gmail that I'm home", "Shripad", nil, "I'm home", "gmail"),
    ])
    func emailPhrases(said: String, person: String, subject: String?, body: String, account: String) throws {
        let args = try #require(DirectCommand(said).flatMap { EmailTool(book: book).directArguments(for: $0) })
        #expect(args.person == person)
        #expect(args.subject == subject)
        #expect(args.body == body)
        #expect(args.account == account)
    }

    @Test(arguments: ["tell me the time", "tell me a joke", "call it a day", "call me later"])
    func notCommunication(said: String) {
        let command = DirectCommand(said)!
        #expect(CallTool(book: book).directArguments(for: command) == nil)
        #expect(MessageTool(book: book).directArguments(for: command) == nil)
    }

    @Test func messagesWaitForYes() async throws {
        let said = "tell Sam Patel I'm running late"
        let tool = MessageTool(book: book)
        let args = try #require(DirectCommand(said).flatMap { tool.directArguments(for: $0) })
        let result = try await CommandContext.$transcript.withValue(said) { try await tool.execute(args) }
        #expect(result.confirmation != nil)
        #expect(result.text == "Send to Sam Patel: “I'm running late”?")
        Confirmations.discard()
    }

    @Test func aMissingMessageIsAskedFor() async throws {
        let tool = MessageTool(book: book)
        let result = try await CommandContext.$transcript.withValue("text Amma") {
            try await tool.execute(MessageArguments(person: "Amma", text: "", app: "messages"))
        }
        #expect(result.followUp == "What should it say?")
        #expect(result.followUpJoin == "saying")
    }

    @Test func ambiguousNamesAreAsked() async throws {
        let tool = CallTool(book: book)
        let result = try await tool.execute(CallArguments(person: "Sam", via: "phone"))
        #expect(result.followUp?.hasPrefix("Which Sam") == true)
        // The answer comes back appended to the name.
        let answered = try await tool.execute(CallArguments(person: "Sam Sam Patel", via: "phone"))
        #expect(answered.text == "Call Sam Patel?")
        Confirmations.discard()
    }

    @Test func emailSubjects() {
        #expect(EmailTool.subject(from: "I'll miss Tuesday's lecture. Sorry!") == "I'll miss Tuesday's lecture")
    }
}
