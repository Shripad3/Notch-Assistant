@preconcurrency import Contacts
import Foundation
import Synchronization

/// A person from the Contacts app, reduced to what calling, texting and
/// emailing need.
public struct Person: Sendable, Equatable, Identifiable {
    public struct Handle: Sendable, Equatable {
        /// "mobile", "home", "work", "iPhone"…
        public let label: String
        public let value: String
    }

    public let id: String
    public let name: String
    /// Every way the person may be called: first, last, full name,
    /// nickname, plus relations from the user's own card ("Amma").
    let spokenNames: [String]
    public let phones: [Handle]
    public let emails: [Handle]

    /// The number for calls and texts: a mobile first.
    public var bestPhone: Handle? {
        phones.first { ["mobile", "iphone", "cell"].contains($0.label.lowercased()) } ?? phones.first
    }
}

/// The user's contacts, loaded once permission is granted, matched by name
/// with tolerance for how speech recognition spells names ("Sri pad" for
/// Shripad, "Adithya" for Aditya). Nothing leaves the Mac.
public final class ContactBook: Sendable {
    public static let shared = ContactBook()

    private let people = Mutex<[Person]>([])
    private let loaded = Mutex(false)

    init(_ people: [Person] = []) {
        self.people.withLock { $0 = people }
        loaded.withLock { $0 = !people.isEmpty }
    }

    public var isLoaded: Bool { loaded.withLock { $0 } }

    public static var isAllowed: Bool {
        CNContactStore.authorizationStatus(for: .contacts) == .authorized
    }

    /// Names to prime speech recognition with (at most `limit`).
    public func namesForRecognition(limit: Int = 150) -> [String] {
        Array(Set(people.withLock { $0.flatMap(\.spokenNames) }.filter { $0.count > 2 })).sorted().prefix(limit).map { $0 }
    }

    /// Loads contacts, asking for permission the first time (`ask`).
    @discardableResult
    public func load(ask: Bool) async -> Bool {
        let store = CNContactStore()
        if CNContactStore.authorizationStatus(for: .contacts) != .authorized {
            guard ask, (try? await store.requestAccess(for: .contacts)) == true else { return false }
        }
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
            CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactRelationsKey, CNContactMiddleNameKey,
        ].map { $0 as CNKeyDescriptor } + [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
        let found: [Person] = await Task.detached(priority: .utility) {
            var contacts: [CNContact] = []
            try? store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in contacts.append(contact) }
            // Relations on the user's own card: "mother: Anjali Kulkarni".
            var relations: [String: [String]] = [:]
            if let me = try? store.unifiedMeContactWithKeys(toFetch: keys) {
                for relation in me.contactRelations {
                    let label = CNLabeledValue<CNContactRelation>.localizedString(forLabel: relation.label ?? "").lowercased()
                    relations[AppNameMatcher.normalize(relation.value.name), default: []] += Self.spokenRelations(for: label)
                }
            }
            return contacts.compactMap { Self.person(from: $0, relations: relations) }
        }.value
        people.withLock { $0 = found }
        loaded.withLock { $0 = true }
        return true
    }

    private static func person(from contact: CNContact, relations: [String: [String]]) -> Person? {
        let full = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
        let name = full.isEmpty ? contact.organizationName : full
        guard !name.isEmpty, !(contact.phoneNumbers.isEmpty && contact.emailAddresses.isEmpty) else { return nil }
        var spoken = [name, contact.givenName, contact.familyName, contact.nickname, contact.organizationName]
        spoken += relations[AppNameMatcher.normalize(name)] ?? []
        spoken += relations[AppNameMatcher.normalize(contact.givenName)] ?? []
        func label(_ raw: String?) -> String {
            raw.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? "other"
        }
        return Person(
            id: contact.identifier,
            name: name,
            spokenNames: spoken.filter { !$0.isEmpty },
            phones: contact.phoneNumbers.map { .init(label: label($0.label), value: $0.value.stringValue) },
            emails: contact.emailAddresses.map { .init(label: label($0.label), value: $0.value as String) }
        )
    }

    /// Words the user may say for a relation on their card.
    static func spokenRelations(for label: String) -> [String] {
        switch label {
        case "mother", "mom", "mum": ["mum", "mom", "mummy", "mother", "amma", "maa", "ma", "aai", "mommy"]
        case "father", "dad": ["dad", "father", "papa", "appa", "baba", "daddy", "pappa"]
        case "brother": ["brother", "bhaiya", "bhai", "dada", "anna"]
        case "sister": ["sister", "didi", "akka", "tai"]
        case "spouse", "wife": ["wife", "spouse"]
        case "husband": ["husband", "spouse"]
        case "partner": ["partner", "boyfriend", "girlfriend"]
        case "son": ["son"]
        case "daughter": ["daughter"]
        default: [label]
        }
    }

    // MARK: Matching

    public enum Match: Sendable, Equatable {
        case one(Person)
        case several([Person])
        case none
    }

    public func find(_ spoken: String, exactOnly: Bool = false) -> Match {
        Self.match(spoken, in: people.withLock { $0 }, exactOnly: exactOnly)
    }

    /// Exact names first, then names that sound the same once spellings
    /// are folded (see `phoneticKey`).
    static func match(_ spoken: String, in people: [Person], exactOnly: Bool = false) -> Match {
        var words = AppNameMatcher.normalize(spoken).split(separator: " ").map(String.init)
        words.removeAll { ["my", "the", "to"].contains($0) }
        guard !words.isEmpty else { return .none }
        let said = words.joined(separator: " ")

        func names(_ person: Person) -> [String] { person.spokenNames.map(AppNameMatcher.normalize) }
        let exact = people.filter { names($0).contains(said) }
        if !exact.isEmpty { return result(exact, said: said) }
        if exactOnly { return .none }

        let key = phoneticKey(said)
        let scored = people.compactMap { person -> (Person, Double)? in
            let best = names(person).map { AppNameMatcher.similarity(phoneticKey($0), key) }.max() ?? 0
            return best >= 0.8 ? (person, best) : nil
        }
        guard let top = scored.map(\.1).max() else { return .none }
        return result(scored.filter { $0.1 >= top - 0.05 }.map(\.0), said: said)
    }

    private static func result(_ people: [Person], said: String) -> Match {
        // The same person listed twice (e.g. iCloud and Google) counts once.
        var seen = Set<String>()
        let unique = people.filter { seen.insert($0.name.lowercased()).inserted }
        return unique.count == 1 ? .one(unique[0]) : .several(unique)
    }

    /// Folds spellings of the same sound, as recognisers and Indian names
    /// vary: "Shripad"/"Sri pad"/"Sripad", "Aditya"/"Adithya",
    /// "Vivek"/"Wiwek", "Deepa"/"Dipa". Spaces go too: "sri pad" = "sripad".
    static func phoneticKey(_ text: String) -> String {
        var s = AppNameMatcher.key(text)
        let rules: [(String, String)] = [
            ("shr", "sr"), ("sh", "s"), ("th", "t"), ("dh", "d"), ("bh", "b"), ("kh", "k"), ("gh", "g"), ("ph", "f"),
            ("ch", "c"), ("jh", "j"), ("w", "v"), ("z", "j"), ("ee", "i"), ("ii", "i"), ("oo", "u"), ("aa", "a"),
            ("y", "i"), ("q", "k"), ("ck", "k"), ("x", "ks"),
        ]
        for (from, to) in rules { s = s.replacingOccurrences(of: from, with: to) }
        // Doubled letters and a trailing "a" or "h" rarely matter.
        var folded = ""
        for char in s where folded.last != char { folded.append(char) }
        while folded.count > 3, let last = folded.last, last == "a" || last == "h" { folded.removeLast() }
        return folded
    }
}
