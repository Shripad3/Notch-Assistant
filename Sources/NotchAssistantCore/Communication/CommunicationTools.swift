import AppKit
import ApplicationServices
import FoundationModels

/// Shared by calling, texting and emailing.
enum Recipients {
    /// The person the user means, or what to ask.
    enum Resolution { case person(Person), ask(String), notFound(String) }

    static func resolve(_ spoken: String, book: ContactBook) async -> Resolution {
        // The model can't choose someone the user didn't name.
        guard wasSaid(spoken) else { return .notFound("Who do you mean? Say their name") }
        if !book.isLoaded { await book.load(ask: true) }
        guard book.isLoaded else { return .notFound("Notch Assistant needs access to Contacts; allow it in Settings › Messages & Email") }
        // An answer to "Which Sam?" arrives appended: "sam sam smith". Try
        // the whole phrase, then without its first words.
        let words = spoken.split(separator: " ").map(String.init)
        for start in 0..<max(1, words.count) {
            switch book.find(words[start...].joined(separator: " ")) {
            case .one(let person): return .person(person)
            case .several(let people):
                if start == words.count - 1 || words.count == 1 {
                    return .ask("Which \(spoken): " + people.prefix(3).map(\.name).joined(separator: ", or ") + "?")
                }
                continue
            case .none: continue
            }
        }
        if case .several(let people) = book.find(spoken) {
            return .ask("Which one: " + people.prefix(3).map(\.name).joined(separator: ", or ") + "?")
        }
        return .notFound("I couldn't find “\(spoken)” in Contacts")
    }

    /// "+31 6 1234 5678" → "+31612345678".
    static func dialable(_ number: String) -> String {
        String(number.filter { $0.isNumber || $0 == "+" })
    }

    /// The message's words must all have been said.
    static func wasSaid(_ text: String) -> Bool {
        guard let transcript = CommandContext.transcript else { return true }
        return Set(SpokenWords(text).lower).isSubset(of: SpokenWords(transcript).lower)
    }

    /// Splits "Sam I'm running late" into ("Sam", "I'm running late"):
    /// "that"/"saying" if present, else the longest start that is a contact,
    /// else the first word.
    static func split(_ rest: String, book: ContactBook) -> (person: String, text: String) {
        var words = rest.split(separator: " ").map(String.init)
        while let first = words.first, ["to", "my"].contains(first.lowercased()) { words.removeFirst() }
        if let index = words.firstIndex(where: { ["that", "saying", "say", "telling"].contains($0.lowercased()) }), index > 0 {
            return (words[..<index].joined(separator: " "), words[(index + 1)...].joined(separator: " "))
        }
        // Exact names first (longest first), then names that sound alike.
        for exactOnly in [true, false] {
            for length in stride(from: min(3, words.count - 1), through: 1, by: -1) where length > 0 {
                let candidate = words[..<length].joined(separator: " ")
                if case .none = book.find(candidate, exactOnly: exactOnly) { continue }
                return (candidate, words[length...].joined(separator: " "))
            }
        }
        guard let first = words.first else { return ("", "") }
        return (first, words.dropFirst().joined(separator: " "))
    }

    /// The part of the transcript after a spoken prefix, keeping the
    /// user's own capitalisation and punctuation.
    static func rest(of original: String, after pattern: String) -> String? {
        guard let range = original.range(of: pattern, options: [.regularExpression, .caseInsensitive, .anchored]) else { return nil }
        return original[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!")))
    }

    static let opening = #"^\s*(?:please\s+|can you\s+|could you\s+)?"#
}

// MARK: - Calls

@Generable
struct CallArguments: Sendable {
    @Guide(description: "Who to call, as the user said it, e.g. \"Amma\" or \"Sam\"")
    var person: String
    @Guide(description: "How", .anyOf(["phone", "facetime", "facetimeAudio"]))
    var via: String
}

/// Calls someone from Contacts: a phone call through the iPhone
/// ("Calls from iPhone"), or FaceTime video or audio. Always asks first.
struct CallTool: AssistantTool {
    let name = "call"
    let title = "Call"
    let symbol = "phone.fill"
    let keywords: Set<String> = ["call", "phone", "ring", "facetime", "dial"]
    let description = """
        Call a contact. "call Amma" → person "Amma", via "phone". "FaceTime Sam" → via "facetime". "FaceTime audio Sam" → via "facetimeAudio".
        """
    let requiresNetwork = true
    let permission = ToolPermission.contacts
    let reversibility = Reversibility.notApplicable

    var book: ContactBook = .shared

    func target(of arguments: CallArguments) -> String { arguments.person }

    func execute(_ arguments: CallArguments) async throws -> ToolResult {
        let person: Person
        switch await Recipients.resolve(arguments.person, book: book) {
        case .person(let found): person = found
        case .ask(let question): return .ask(question)
        case .notFound(let message): throw ToolError(message)
        }
        let handle: Person.Handle
        let url: URL
        switch arguments.via {
        case "facetime", "facetimeAudio":
            guard let found = person.bestPhone ?? person.emails.first else { throw ToolError("\(person.name) has no number or email for FaceTime") }
            handle = found
            let value = found.value.contains("@") ? found.value : Recipients.dialable(found.value)
            url = URL(string: (arguments.via == "facetime" ? "facetime://" : "facetime-audio://") + value)!
        default:
            guard let phone = person.bestPhone else { throw ToolError("\(person.name) has no phone number in Contacts") }
            handle = phone
            url = URL(string: "tel://" + Recipients.dialable(phone.value))!
        }
        let how = arguments.via == "facetime" ? "FaceTime" : arguments.via == "facetimeAudio" ? "FaceTime audio" : "Call"
        let token = PendingActions.park {
            _ = await MainActor.run { NSWorkspace.shared.open(url) }
            // macOS asks once more before a call from a link; the user has
            // already said yes to Alfred, so press its Call button.
            let pressed = await CallPrompt.pressCall()
            return "\(how == "Call" ? "Calling" : how + " to") \(person.name)" + (pressed ? "" : ". Click Call in FaceTime")
        }
        let item = ResultItem(id: token, title: person.name, detail: "\(handle.label) · \(handle.value)", symbol: "phone.fill")
        return ToolResult("\(how) \(person.name)?", items: [item], confirmation: token)
    }

    func directArguments(for command: DirectCommand) -> CallArguments? {
        let original = command.original
        let patterns: [(String, String)] = [
            (Recipients.opening + #"facetime\s+audio\s+(?:call\s+)?"#, "facetimeAudio"),
            (Recipients.opening + #"(?:facetime|video\s+call)\s+"#, "facetime"),
            (Recipients.opening + #"(?:call|phone|ring|dial)\s+"#, "phone"),
        ]
        for (pattern, via) in patterns {
            guard var person = Recipients.rest(of: original, after: pattern), !person.isEmpty else { continue }
            var how = via
            for (suffix, method) in [(" on facetime audio", "facetimeAudio"), (" on facetime", "facetime"), (" on video", "facetime"), (" on my phone", "phone"), (" on the phone", "phone")]
            where person.lowercased().hasSuffix(suffix) {
                person.removeLast(suffix.count)
                how = method
            }
            // "call me a taxi", "call it a day": not a person.
            guard person.split(separator: " ").count <= 4, !["me", "it", "him", "her", "them", "back"].contains(person.lowercased().split(separator: " ").first.map(String.init) ?? "") else { return nil }
            return CallArguments(person: person, via: how)
        }
        return nil
    }
}

// MARK: - Messages

@Generable
struct MessageArguments: Sendable {
    @Guide(description: "Who to message, as the user said it")
    var person: String
    @Guide(description: "The message, in the user's words, e.g. \"I'm running 10 minutes late\"")
    var text: String
    @Guide(description: "Which app", .anyOf(["messages", "whatsapp"]))
    var app: String
}

/// Texts someone from Contacts: iMessage or SMS through Messages (shown
/// first, sent on "yes"), or WhatsApp, which opens the chat with the text
/// typed in for the user to send.
struct MessageTool: AssistantTool {
    let name = "sendMessage"
    let title = "Message"
    let symbol = "message.fill"
    let keywords: Set<String> = ["text", "message", "tell", "whatsapp", "imessage", "sms", "send"]
    let description = """
        Send a text message. "tell Sam I'm running late" → person "Sam", text "I'm running late", app "messages". \
        "WhatsApp Amma that I'll call later" → app "whatsapp".
        """
    let requiresNetwork = true
    let permission = ToolPermission.contacts
    let reversibility = Reversibility.notApplicable

    public static let defaultAppKey = "messages.defaultApp"
    var book: ContactBook = .shared

    func target(of arguments: MessageArguments) -> String { arguments.person }

    func execute(_ arguments: MessageArguments) async throws -> ToolResult {
        let text = arguments.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .ask("What should it say?", join: "saying") }
        guard Recipients.wasSaid(text) else { throw ToolError("What should the message say?") }
        let person: Person
        switch await Recipients.resolve(arguments.person, book: book) {
        case .person(let found): person = found
        case .ask(let question): return .ask(question)
        case .notFound(let message): throw ToolError(message)
        }
        let body = text.prefix(1).uppercased() + text.dropFirst()

        if arguments.app == "whatsapp" {
            guard let phone = person.bestPhone else { throw ToolError("\(person.name) has no phone number for WhatsApp") }
            let digits = Recipients.dialable(phone.value).replacingOccurrences(of: "+", with: "")
            var components = URLComponents(string: "whatsapp://send")!
            components.queryItems = [.init(name: "phone", value: digits), .init(name: "text", value: body)]
            let opened = await MainActor.run { NSWorkspace.shared.open(components.url!) }
            guard opened else { throw ToolError("WhatsApp isn't installed") }
            return ToolResult("WhatsApp is open with your message to \(person.name). Press Return to send")
        }

        guard let handle = person.bestPhone.map({ Recipients.dialable($0.value) }) ?? person.emails.first?.value else {
            throw ToolError("\(person.name) has no number or email for Messages")
        }
        let token = PendingActions.park {
            try await Self.send(body, to: handle)
            return "Sent to \(person.name)"
        }
        let item = ResultItem(id: token, title: "To \(person.name)", detail: "“\(body)”", symbol: "message.fill")
        return ToolResult("Send to \(person.name): “\(body)”?", items: [item], confirmation: token)
    }

    /// iMessage first, then SMS through the iPhone. If Messages refuses
    /// both, the message is left typed in for the user to send.
    static func send(_ text: String, to handle: String) async throws {
        for service in ["iMessage", "SMS"] {
            do {
                try await AppleScript.run("""
                    tell application "Messages"
                        set targetService to 1st account whose service type = \(service)
                        set targetBuddy to participant \(AppleScript.quoted(handle)) of targetService
                        send \(AppleScript.quoted(text)) to targetBuddy
                    end tell
                    """, controlling: "Messages")
                return
            } catch let failure as AssistantFailure {
                throw failure // Not allowed to control Messages.
            } catch {
                continue
            }
        }
        var components = URLComponents()
        components.scheme = "sms"
        components.path = handle
        components.queryItems = [.init(name: "body", value: text)]
        _ = await MainActor.run { NSWorkspace.shared.open(components.url!) }
        throw ToolError("Messages wouldn't send it automatically; it's typed in, ready for you to send")
    }

    func directArguments(for command: DirectCommand) -> MessageArguments? {
        let original = command.original
        let defaultApp = UserDefaults.standard.string(forKey: Self.defaultAppKey) ?? "messages"
        let patterns: [(String, String?)] = [
            (Recipients.opening + #"(?:send\s+(?:a\s+)?whatsapp\s+(?:message\s+)?to|whatsapp)\s+"#, "whatsapp"),
            (Recipients.opening + #"(?:send\s+(?:a\s+)?(?:text|message|imessage)\s+to|text|message|imessage)\s+"#, nil),
            (Recipients.opening + #"tell\s+"#, nil),
        ]
        for (pattern, forcedApp) in patterns {
            guard var rest = Recipients.rest(of: original, after: pattern), !rest.isEmpty else { continue }
            var app = forcedApp ?? defaultApp
            for suffix in [" on whatsapp", " via whatsapp", " on WhatsApp"] where rest.lowercased().contains(suffix.lowercased()) {
                rest = rest.replacingOccurrences(of: suffix, with: "", options: .caseInsensitive)
                app = "whatsapp"
            }
            let (person, text) = Recipients.split(rest, book: book)
            guard !person.isEmpty, person.split(separator: " ").count <= 3 else { return nil }
            // "tell me a joke", "tell me about…": not a message.
            if ["me", "us", "him", "her", "them", "it"].contains(person.lowercased()) { return nil }
            return MessageArguments(person: person, text: text, app: app)
        }
        return nil
    }
}

// MARK: - Email

@Generable
struct EmailArguments: Sendable {
    @Guide(description: "Who to email, as the user said it")
    var person: String
    @Guide(description: "The subject, only if the user gave one (\"about …\")")
    var subject: String?
    @Guide(description: "What the email says, in the user's words")
    var body: String
    @Guide(description: "Which account", .anyOf(["gmail", "outlook", "default"]))
    var account: String
}

/// Emails someone from Contacts: opens a ready-made draft in Gmail or
/// Outlook on the web. For Gmail, "send it" then sends it from here
/// (Gmail API, `gmail.send`); Outlook drafts are sent by the user.
struct EmailTool: AssistantTool {
    let name = "email"
    let title = "Email"
    let symbol = "envelope.fill"
    let keywords: Set<String> = ["email", "mail", "gmail", "outlook", "send"]
    let description = """
        Write an email to a contact. "email Professor Jansen that I'll miss Tuesday's lecture" → person "Professor Jansen", \
        body "I'll miss Tuesday's lecture", account "default". "…from my uni account" → account "outlook".
        """
    let requiresNetwork = true
    let permission = ToolPermission.contacts
    let reversibility = Reversibility.notApplicable

    public static let defaultAccountKey = "email.defaultAccount"
    var book: ContactBook = .shared

    func target(of arguments: EmailArguments) -> String { arguments.person }

    func execute(_ arguments: EmailArguments) async throws -> ToolResult {
        let body = arguments.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return .ask("What should it say?", join: "saying") }
        guard Recipients.wasSaid(body) else { throw ToolError("What should the email say?") }
        let person: Person
        switch await Recipients.resolve(arguments.person, book: book) {
        case .person(let found): person = found
        case .ask(let question): return .ask(question)
        case .notFound(let message): throw ToolError(message)
        }
        guard let address = person.emails.first?.value else { throw ToolError("\(person.name) has no email address in Contacts") }
        let account = arguments.account == "default"
            ? (UserDefaults.standard.string(forKey: Self.defaultAccountKey) ?? "gmail")
            : arguments.account
        let text = body.prefix(1).uppercased() + body.dropFirst()
        let subject = arguments.subject.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? Self.subject(from: text)

        let draft = account == "outlook"
            ? Self.url("https://outlook.office.com/mail/deeplink/compose", ["to": address, "subject": subject, "body": text])
            : Self.url("https://mail.google.com/mail/", ["view": "cm", "fs": "1", "to": address, "su": subject, "body": text])
        _ = await MainActor.run { NSWorkspace.shared.open(draft) }

        guard account == "gmail", GoogleCalendar.session.isSignedIn else {
            return ToolResult("Draft to \(person.name) is open in \(account == "outlook" ? "Outlook" : "Gmail"). Press Send when it's ready")
        }
        let token = PendingActions.park {
            try await Self.sendWithGmail(to: address, subject: subject, body: text)
            return "Sent to \(person.name). Close the draft in your browser without sending"
        }
        let item = ResultItem(id: token, title: "To \(person.name) · \(subject)", detail: address, symbol: "envelope.fill")
        return ToolResult("Draft open in Gmail. Say “send it” to send it from here", items: [item], confirmation: token)
    }

    /// The first sentence, shortened: "I'll miss Tuesday's lecture".
    static func subject(from body: String) -> String {
        let sentence = body.split(whereSeparator: { ".!?\n".contains($0) }).first.map(String.init) ?? body
        return sentence.count <= 60 ? sentence : String(sentence.prefix(57)) + "…"
    }

    private static func url(_ base: String, _ query: [String: String]) -> URL {
        var components = URLComponents(string: base)!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    static func sendWithGmail(to address: String, subject: String, body: String) async throws {
        let encodedSubject = "=?UTF-8?B?\(Data(subject.utf8).base64EncodedString())?="
        let message = "To: \(address)\r\nSubject: \(encodedSubject)\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n\(body)\r\n"
        _ = try await GoogleCalendar.session.request(
            "POST", URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!,
            json: ["raw": Data(message.utf8).base64URLEncoded]
        )
    }

    func directArguments(for command: DirectCommand) -> EmailArguments? {
        let original = command.original
        let pattern = Recipients.opening + #"(?:send\s+(?:an\s+)?(?:e-?mail|mail)\s+to|write\s+(?:an\s+)?(?:e-?mail|mail)\s+to|e-?mail|mail)\s+"#
        guard var rest = Recipients.rest(of: original, after: pattern), !rest.isEmpty else { return nil }
        var account = "default"
        let accounts: [(String, String)] = [
            (#"\s+(?:from|on|with|using)\s+(?:my\s+)?(?:uni|university|school|college|student|work|outlook|office)(?:\s+(?:account|email|mail|id))?"#, "outlook"),
            (#"\s+(?:from|on|with|using)\s+(?:my\s+)?(?:gmail|google|personal)(?:\s+(?:account|email|mail|id))?"#, "gmail"),
        ]
        for (pattern, name) in accounts {
            if let range = rest.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                rest.removeSubrange(range)
                account = name
            }
        }
        var subject: String?
        var words = rest.split(separator: " ").map(String.init)
        // "about <subject> saying <body>", "about <subject>".
        if let about = words.firstIndex(where: { $0.lowercased() == "about" }), about > 0 {
            let person = words[..<about].joined(separator: " ")
            let after = Array(words[(about + 1)...])
            if let say = after.firstIndex(where: { ["saying", "that"].contains($0.lowercased()) }) {
                subject = after[..<say].joined(separator: " ")
                return EmailArguments(person: person, subject: subject, body: after[(say + 1)...].joined(separator: " "), account: account)
            }
            return EmailArguments(person: person, subject: after.joined(separator: " "), body: "", account: account)
        }
        let (person, body) = Recipients.split(words.joined(separator: " "), book: book)
        guard !person.isEmpty, person.split(separator: " ").count <= 4 else { return nil }
        return EmailArguments(person: person, subject: subject, body: body, account: account)
    }
}

/// FaceTime's "Call" confirmation for calls started from a link. Found and
/// pressed through Accessibility, after the user has confirmed in Alfred.
enum CallPrompt {
    private static let titles = ["Call", "FaceTime", "FaceTime Audio", "Audio"]

    /// Waits up to 6 s for FaceTime's prompt; true once Call is pressed.
    static func pressCall() async -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let deadline = ContinuousClock.now + .seconds(6)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            // Found and pressed on the main actor: Accessibility elements
            // can't cross actors.
            let pressed: String? = await MainActor.run {
                guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.FaceTime").first else { return nil }
                let root = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(root, 0.5)
                var buttons: [(AXUIElement, String)] = []
                collectButtons(root, depth: 0, into: &buttons)
                // "Call" first; the others only when it's the prompt's only choice.
                for title in titles {
                    if let match = buttons.first(where: { $0.1 == title }),
                       AXUIElementPerformAction(match.0, kAXPressAction as CFString) == .success {
                        return title
                    }
                }
                return nil
            }
            if let pressed {
                Log.tools.notice("call: pressed FaceTime's \(pressed, privacy: .public) button")
                return true
            }
        }
        Log.tools.notice("call: FaceTime's call button wasn't found")
        return false
    }

    @MainActor
    private static func collectButtons(_ element: AXUIElement, depth: Int, into buttons: inout [(AXUIElement, String)]) {
        guard depth < 9, buttons.count < 60 else { return }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if (role as? String) == "AXButton" {
            for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let text = value as? String, !text.isEmpty {
                    buttons.append((element, text))
                    break
                }
            }
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return }
        for child in list { collectButtons(child, depth: depth + 1, into: &buttons) }
    }
}
