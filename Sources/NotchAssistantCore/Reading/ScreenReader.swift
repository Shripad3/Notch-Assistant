import AppKit
import ApplicationServices
import FoundationModels
@preconcurrency import ScreenCaptureKit

/// A node of an app's accessibility tree, as the screen reader sees it.
/// Abstract so the walk can be tested without a real app.
protocol TextNode: Sendable {
    var role: String { get }
    var subrole: String { get }
    var texts: [String] { get }
    var children: [any TextNode] { get }
}

/// The front window's text, from Accessibility first (the app's own text:
/// exact and cheap) and screen text recognition only when an app exposes
/// too little (Electron apps, games, video, remote desktops). Only on an
/// explicit command; nothing read here is stored anywhere.
enum ScreenText {
    struct Reading: Sendable, Equatable {
        let app: String
        let text: String
        let usedRecognition: Bool
    }

    /// Below this many characters of text, the tree is too thin to trust.
    static let minimumCharacters = 120
    static let maximumCharacters = 20_000
    private static let textRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXTextField", "AXHeading", "AXLink", "AXButton", "AXCell", "AXMenuButton", "AXCheckBox", "AXRadioButton"]

    /// Text in reading order; password fields are skipped entirely.
    static func collect(_ node: any TextNode, depth: Int = 0, into lines: inout [String], budget: inout Int) {
        guard depth < 40, budget > 0 else { return }
        if node.role == "AXSecureTextField" || node.subrole == "AXSecureTextField" { return }
        if textRoles.contains(node.role) || node.role == "AXWindow" || node.role == "AXSheet" {
            for text in node.texts {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, lines.last != trimmed else { continue }
                lines.append(trimmed)
                budget -= trimmed.count
            }
        }
        for child in node.children { collect(child, depth: depth + 1, into: &lines, budget: &budget) }
    }

    static func text(of root: any TextNode) -> String {
        var lines: [String] = []
        var budget = maximumCharacters
        collect(root, into: &lines, budget: &budget)
        return lines.joined(separator: "\n")
    }

    /// Accessibility text, or recognition when there's too little of it.
    static func read(root: (any TextNode)?, app: String, recognize: () async throws -> String) async throws -> Reading {
        let tree = root.map(text(of:)) ?? ""
        if tree.count >= minimumCharacters {
            return Reading(app: app, text: SecretRedactor.redact(tree), usedRecognition: false)
        }
        let recognized = try await recognize()
        let best = recognized.count > tree.count ? recognized : tree
        return Reading(app: app, text: SecretRedactor.redact(best), usedRecognition: recognized.count > tree.count)
    }

    /// The front app's focused window, read for real.
    static func frontWindow() async throws -> Reading {
        try SystemKeys.ensureTrusted()
        let (root, app, selection) = await MainActor.run { () -> ((any TextNode)?, String, String?) in
            guard let front = NSWorkspace.shared.frontmostApplication else { return (nil, "", nil) }
            let element = AXUIElementCreateApplication(front.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.25)
            // Electron and Chromium only build their tree when asked.
            AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            var window: CFTypeRef?
            let root: (any TextNode)? = AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success
                ? window.map { AXTextNode(snapshot: $0 as! AXUIElement) } : nil
            return (root, front.localizedName ?? "the app", selectedText(in: element))
        }
        if let selection, !selection.isEmpty {
            return Reading(app: app, text: SecretRedactor.redact(selection), usedRecognition: false)
        }
        return try await read(root: root, app: app) {
            let content = try await ScreenCapture.content()
            let window = try await ScreenCapture.frontWindow(of: nil, in: content)
            let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2 }
            let image = try await ScreenCapture.image(SCContentFilter(desktopIndependentWindow: window),
                                                      width: Int(window.frame.width * scale), height: Int(window.frame.height * scale))
            return try await ContentExtractor.recognize(image)
        }
    }

    /// Text the user has selected, if any ("read this to me").
    @MainActor
    private static func selectedText(in app: AXUIElement) -> String? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let focused else { return nil }
        let element = focused as! AXUIElement
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        guard (role as? String) != "AXSecureTextField" else { return nil }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success else { return nil }
        return selected as? String
    }
}

/// A copied snapshot of an AX element's subtree (so the walk needs no
/// further calls, and nothing crosses actors).
struct AXTextNode: TextNode {
    let role: String
    let subrole: String
    let texts: [String]
    let children: [any TextNode]

    /// Nodes and time a reading may take: big web pages have tens of
    /// thousands of elements, and one call per attribute took 40 seconds.
    static let maximumNodes = 1_500
    static let timeBudget: TimeInterval = 2

    @MainActor
    init(snapshot element: AXUIElement, depth: Int = 0, count: inout Int, deadline: Date) {
        // One request for all six attributes instead of six.
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute, kAXChildrenAttribute] as CFArray
        var values: CFArray?
        let fetched = AXUIElementCopyMultipleAttributeValues(element, names, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success
        let list = fetched ? (values as? [AnyObject] ?? []) : []
        func value(_ index: Int) -> AnyObject? { index < list.count ? list[index] : nil }
        role = value(0) as? String ?? ""
        subrole = value(1) as? String ?? ""
        count += 1
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" {
            // Never keep a password field's value.
            texts = []
            children = []
            return
        }
        texts = [value(2), value(3), value(4)].compactMap { $0 as? String }
        guard depth < 40, count < Self.maximumNodes, Date() < deadline,
              let kids = value(5) as? [AXUIElement] else {
            children = []
            return
        }
        var built: [any TextNode] = []
        for child in kids where count < Self.maximumNodes && Date() < deadline {
            built.append(AXTextNode(snapshot: child, depth: depth + 1, count: &count, deadline: deadline))
        }
        children = built
    }

    @MainActor
    init(snapshot element: AXUIElement) {
        var count = 0
        self.init(snapshot: element, count: &count, deadline: Date().addingTimeInterval(Self.timeBudget))
    }
}

@Generable
struct ScreenArguments: Sendable {
    @Guide(description: "What the user wants", .anyOf(["describe", "error", "read", "asking", "summarize", "question"]))
    var action: String
    @Guide(description: "The user's question about the screen, only for question")
    var question: String?
}

/// "What's on my screen", "what does this error say", "read this to me",
/// "what's this app asking me", "summarise this page".
struct ScreenReadTool: AssistantTool {
    let name = "readScreen"
    let title = "Reading the screen"
    let symbol = "text.viewfinder"
    let keywords: Set<String> = ["screen", "error", "window", "page", "dialog", "asking", "says", "this"]
    let description = """
        Read the front window and explain it. "what's on my screen" → describe. "what does this error say" → error. \
        "read this to me" → read. "what's this app asking me" → asking. "summarise this page" → summarize.
        """
    let requiresNetwork = false
    let permission = ToolPermission.accessibility
    let reversibility = Reversibility.notApplicable

    func target(of arguments: ScreenArguments) -> String { "Front window" }

    func execute(_ arguments: ScreenArguments) async throws -> ToolResult {
        CommandContext.report("Reading the screen")
        let reading = try await ScreenText.frontWindow()
        guard !reading.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError("I couldn't find any text in \(reading.app)")
        }
        if arguments.action == "read" {
            let text = reading.text.count > 1_500 ? String(reading.text.prefix(1_500)) + "… It goes on; ask me to summarise it." : reading.text
            return ToolResult(text, isAnswer: true)
        }
        let task: String = switch arguments.action {
        case "error": "The user has an error or warning on screen. Say in one or two sentences what it means, then one sentence on what to do about it."
        case "asking": "The app is asking the user something. Say plainly what it is asking and what each choice would do, in two or three sentences."
        case "summarize": "Summarise the main content of this window (e.g. the article or page) in three to five sentences, ignoring menus and buttons."
        case "question": "Answer the user's question about what's on their screen: \(arguments.question ?? CommandContext.transcript ?? "")"
        default: "Describe briefly what's on the screen: which app, what the user is looking at, and anything that needs attention. Two or three sentences."
        }
        let backend = ModelRouter.backend(for: reading.text.count > ContentChunker.chunkCharacters ? .analysis : .summarize)
        let prompt = "\(task) Speak to the user as \"you\".\n\nApp: \(reading.app)\nText in the window:\n\(String(reading.text.prefix(ContentChunker.chunkCharacters + 1_500)))"
        do {
            let answer = try await backend.respond(system: DocumentReader.system, prompt: prompt, temperature: 0.2)
            return ToolResult(SecretRedactor.redact(Conversation.spoken(answer)), isAnswer: true)
        } catch {
            throw error.failure
        }
    }

    func directArguments(for command: DirectCommand) -> ScreenArguments? {
        switch command.text {
        case "what s on my screen", "whats on my screen", "what is on my screen", "what am i looking at", "describe my screen", "describe the screen",
             "what s on the screen", "what is on the screen", "look at my screen":
            ScreenArguments(action: "describe")
        case "what does this error say", "what does this error mean", "what s this error", "what is this error", "what does the error say",
             "explain this error", "what does this warning say", "what s this warning", "what went wrong":
            ScreenArguments(action: "error")
        case "read this to me", "read this", "read this out", "read that to me", "read it to me", "read the screen", "read my screen", "read this out loud":
            ScreenArguments(action: "read")
        case "what s this app asking me", "what is this app asking me", "what s it asking me", "what is it asking", "what does it want",
             "what does this dialog say", "what s this dialog", "what does this popup say", "what is this asking me":
            ScreenArguments(action: "asking")
        case "summarise this page", "summarize this page", "summarise this web page", "summarize this web page", "summarise this website",
             "summarize this website", "summarise this article", "summarize this article", "summarise my screen", "summarize my screen",
             "summarise the page", "summarize the page", "summarise this site", "summarize this site":
            ScreenArguments(action: "summarize")
        default:
            nil
        }
    }
}
