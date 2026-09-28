import AppKit
import Compression
import CoreText
import Foundation
@testable import NotchAssistantCore
import PDFKit
import Testing

/// Builds small documents for the extractors.
enum Fixtures {
    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "reading-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A zip with the given entries, deflated when `deflate` (CRCs are left
    /// zero: the reader doesn't check them).
    static func zip(_ entries: [(String, String)], deflate: Bool = true) -> Data {
        var body = Data(), directory = Data()
        func u16(_ v: Int) -> Data { Data([UInt8(v & 0xff), UInt8(v >> 8 & 0xff)]) }
        func u32(_ v: Int) -> Data { Data((0..<4).map { UInt8(v >> (8 * $0) & 0xff) }) }
        for (name, text) in entries {
            let raw = Data(text.utf8)
            var stored = raw
            if deflate {
                var out = [UInt8](repeating: 0, count: raw.count + 1024)
                let n = raw.withUnsafeBytes { compression_encode_buffer(&out, out.count, $0.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_ZLIB) }
                stored = Data(out.prefix(n))
            }
            let offset = body.count
            let nameData = Data(name.utf8)
            body += u32(0x04034b50) + u16(20) + u16(0) + u16(deflate ? 8 : 0) + u32(0) + u32(0)
            body += u32(stored.count) + u32(raw.count) + u16(nameData.count) + u16(0) + nameData + stored
            directory += u32(0x02014b50) + u16(20) + u16(20) + u16(0) + u16(deflate ? 8 : 0) + u32(0) + u32(0)
            directory += u32(stored.count) + u32(raw.count) + u16(nameData.count) + u16(0) + u16(0) + u16(0) + u16(0) + u32(0) + u32(offset) + nameData
        }
        let end = u32(0x06054b50) + u16(0) + u16(0) + u16(entries.count) + u16(entries.count) + u32(directory.count) + u32(body.count) + u16(0)
        return body + directory + end
    }

    /// A PDF with one line of text per page; `scanned` draws each page as a
    /// picture of its text, with no text layer.
    static func pdf(_ pages: [String], scanned: Bool = false, to url: URL) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for text in pages {
            context.beginPDFPage(nil)
            if scanned {
                let image = picture(of: text)
                context.draw(image, in: CGRect(x: 36, y: 600, width: 540, height: 120))
            } else {
                draw(text, in: context, at: CGPoint(x: 72, y: 700))
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    private static func draw(_ text: String, in context: CGContext, at point: CGPoint, size: CGFloat = 14) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black]))
        context.textPosition = point
        CTLineDraw(line, context)
    }

    private static func picture(of text: String) -> CGImage {
        let context = CGContext(data: nil, width: 1800, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: 1800, height: 400))
        draw(text, in: context, at: CGPoint(x: 40, y: 180), size: 64)
        return context.makeImage()!
    }
}

struct ExtractionTests {
    @Test func spreadsheetsReadCellsAndSheets() async throws {
        let folder = try Fixtures.folder()
        let url = folder.appending(path: "budget.xlsx")
        try Fixtures.zip([
            ("xl/workbook.xml", #"<workbook><sheets><sheet name="Budget"/></sheets></workbook>"#),
            ("xl/sharedStrings.xml", #"<sst><si><t>Rent</t></si><si><t>Food</t></si></sst>"#),
            ("xl/worksheets/sheet1.xml", #"<worksheet><sheetData><row><c t="s"><v>0</v></c><c><v>950</v></c></row><row><c t="s"><v>1</v></c><c><v>300</v></c></row></sheetData></worksheet>"#),
        ]).write(to: url)
        let document = try await ContentExtractor.extract(url)
        #expect(document.rows == 2)
        #expect(document.sections.first?.label == "Sheet Budget")
        #expect(document.text == "Rent\t950\nFood\t300")
    }

    @Test func presentationsReadSlidesInOrder() async throws {
        let folder = try Fixtures.folder()
        let url = folder.appending(path: "talk.pptx")
        try Fixtures.zip([
            ("ppt/slides/slide2.xml", #"<p:sld><a:t>Second</a:t><a:t>slide</a:t></p:sld>"#),
            ("ppt/slides/slide10.xml", #"<p:sld><a:t>Tenth</a:t></p:sld>"#),
            ("ppt/slides/slide1.xml", #"<p:sld><a:t>Title</a:t></p:sld>"#),
        ], deflate: false).write(to: url)
        let document = try await ContentExtractor.extract(url)
        #expect(document.sections.map(\.text) == ["Title", "Second slide", "Tenth"])
        #expect(document.unit == "slides")
    }

    @Test func wordDocumentsAndEmails() async throws {
        let folder = try Fixtures.folder()
        let rtf = folder.appending(path: "letter.rtf")
        try NSAttributedString(string: "Dear Sam, the lease ends in May.").rtf(from: NSRange(location: 0, length: 32))!.write(to: rtf)
        #expect(try await ContentExtractor.extract(rtf).text.contains("lease ends in May"))

        let eml = folder.appending(path: "mail.eml")
        try """
        From: Priya <priya@example.com>
        Subject: Friday
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        See you at 3 =E2=80=94 bring the slides.
        """.write(to: eml, atomically: true, encoding: .utf8)
        let mail = try await ContentExtractor.extract(eml).text
        #expect(mail.contains("Subject: Friday"))
        #expect(mail.contains("See you at 3 — bring the slides."))
    }

    @Test func aFiftyPagePDFFindsPageForty() async throws {
        let folder = try Fixtures.folder()
        let url = folder.appending(path: "thesis.pdf")
        let pages = (1...50).map { $0 == 40 ? "The reactor coolant limit is 42 degrees on page forty." : "Filler text about methods and results, page \($0). " + String(repeating: "More background. ", count: 30) }
        Fixtures.pdf(pages, to: url)
        let document = try await ContentExtractor.extract(url)
        #expect(document.sections.count == 50)
        let best = try #require(ContentChunker.rank(ContentChunker.chunks(document), for: "what is the reactor coolant limit").first)
        #expect(best.text.contains("42 degrees"))
        // Its label, e.g. "Pages 37–42", covers page 40.
        let bounds = (best.label ?? "").split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        #expect((bounds.first ?? 0) <= 40 && 40 <= (bounds.last ?? 0))
    }

    @Test func scannedPagesAreRecognised() async throws {
        let folder = try Fixtures.folder()
        let url = folder.appending(path: "scan.pdf")
        Fixtures.pdf(["Invoice total 1250 euros"], scanned: true, to: url)
        let document = try await ContentExtractor.extract(url)
        #expect(document.recognizedPages == 1)
        #expect(document.text.lowercased().contains("1250"))
    }

    @Test func iWorkIsExplained() async throws {
        let folder = try Fixtures.folder()
        let url = folder.appending(path: "plan.pages")
        try Data("x".utf8).write(to: url)
        await #expect(throws: ToolError.self) { try await ContentExtractor.extract(url) }
    }
}

struct ReadingAccessTests {
    let home = FileManager.default.homeDirectoryForCurrentUser
    var folders: [URL] { [home.appending(path: "Documents")] }

    @Test func secretsAndSystemFilesAreRefused() {
        for path in [".ssh/id_rsa", "Documents/id_ed25519", "Documents/server.pem", "Documents/app/.env", "Documents/tls.key",
                     "Library/Keychains/login.keychain-db", "Documents/.git/config", "Documents/Tool.app/Contents/Info.plist"] {
            guard case .forbidden = ReadingAccess.check(home.appending(path: path), folders: folders) else {
                Issue.record("\(path) should be refused")
                continue
            }
        }
        guard case .forbidden = ReadingAccess.check(URL(filePath: "/System/Library/CoreServices/SystemVersion.plist"), folders: folders) else {
            Issue.record("system files should be refused")
            return
        }
    }

    @Test func outsideTheFoldersIsOfferedNotRead() {
        let outside = home.appending(path: "Projects/notes.txt")
        guard case .outsideFolders(let folder) = ReadingAccess.check(outside, folders: folders) else {
            Issue.record("a file outside the folders should be offered")
            return
        }
        #expect(folder.lastPathComponent == "Projects")
        if case .allowed = ReadingAccess.check(home.appending(path: "Documents/Contract.pdf"), folders: folders) {} else {
            Issue.record("a document in Documents should be allowed")
        }
    }

    @Test func secretsAreNeverSpoken() {
        #expect(SecretRedactor.redact("wifi password: hunter2 please") == "wifi [hidden] please")
        #expect(SecretRedactor.redact("key sk-abcdefghijklmnopqrstuv") == "key [hidden]")
        #expect(SecretRedactor.redact("Meet at 3 about the budget") == "Meet at 3 about the budget")
    }
}

@Suite(.serialized)
struct DocumentReaderTests {
    @Test func longDocumentsAreSummarisedInPartsNotCutOff() async throws {
        let fake = FakeBackend(answer: "A part summary.")
        let sections = (1...9).map { ExtractedDocument.Section(label: "Page \($0)", text: String(repeating: "Sentence about page \($0). ", count: 150)) }
        let document = ExtractedDocument(name: "long.pdf", sections: sections, unit: "pages", rows: nil, recognizedPages: 0)
        let chunks = ContentChunker.chunks(document)
        #expect(chunks.count > 1)
        let progress = LockedList()
        let summary = try await ModelRouter.$override.withValue(fake) {
            try await DocumentReader.summarize(document) { progress.append($0) }
        }
        #expect(summary == "A part summary.")
        // One call per part, then one to combine: nothing skipped.
        #expect(fake.prompts.withLock { $0.count } == chunks.count + 1)
        #expect(progress.items.first?.hasPrefix("Long document") == true)
    }

    @Test func hugeDocumentsOfferAPart() async throws {
        let sections = (1...400).map { ExtractedDocument.Section(label: "Page \($0)", text: String(repeating: "Words. ", count: 700)) }
        let document = ExtractedDocument(name: "huge.pdf", sections: sections, unit: "pages", rows: nil, recognizedPages: 0)
        await #expect(throws: ToolError.self) { try await DocumentReader.summarize(document) { _ in } }
    }

    @Test(arguments: [
        ("page 3", Section.Part.pages(3...3)),
        ("pages 1 to 10", .pages(1...10)),
        ("the second paragraph", .paragraph(2)),
        ("row 12", .row(12)),
        ("the beginning", .beginning),
    ])
    func sectionsAreParsed(said: String, part: Section.Part) {
        #expect(Section.parse(said) == part)
    }
}

final class LockedList: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func append(_ item: String) { lock.lock(); list.append(item); lock.unlock() }
    var items: [String] { lock.lock(); defer { lock.unlock() }; return list }
}

struct ReadPhraseTests {
    func args(_ said: String) -> ReadFileArguments? {
        DirectCommand(said).flatMap { ReadFileTool().directArguments(for: $0) }
    }

    @Test(arguments: [
        ("summarise this", "summarize", ""),
        ("summarize the contract", "summarize", "the contract"),
        ("summarise pages 1 to 10 of the report", "summarize", "the report"),
        ("what does my lease say about pets", "ask", "my lease"),
        ("does the contract mention Hetzner", "ask", "the contract"),
        ("what's the total on that invoice", "ask", "that invoice"),
        ("read page 3 of the report", "part", "the report"),
        ("read me the second paragraph of my essay", "part", "my essay"),
        ("how many pages are in the thesis", "count", "the thesis"),
        ("how many rows does the budget spreadsheet have", "count", "the budget spreadsheet"),
        ("find the file that mentions Hetzner", "search", ""),
        ("what have you read", "history", ""),
    ])
    func phrasings(said: String, action: String, file: String) throws {
        let parsed = try #require(args(said), "no match for \(said)")
        #expect(parsed.action == action)
        if !file.isEmpty { #expect(parsed.file == file) }
    }

    @Test(arguments: ["summarise the meeting", "summarise this page", "what's the weather in Paris", "read this to me", "what's on my calendar tomorrow", "open my latest screenshot"])
    func leavesOthers(said: String) {
        #expect(args(said) == nil)
    }

    @Test(arguments: [
        ("summarise the contract", "readFile"),
        ("summarise the meeting", "transcribe"),
        ("what's the weather in Paris", "getWeather"),
        ("open my latest screenshot", "openFile"),
        ("find the file that mentions Hetzner", "readFile"),
        ("edit my essay", nil as String?),
    ])
    func routes(said: String, tool: String?) {
        #expect(DirectMatcher.plan(for: said, tools: ToolRegistry.standard.tools)?.steps.first?.tool.name == tool)
    }

    @Test func editingIsStillRefused() {
        #expect(ContentRequests.refusal(for: "edit my essay") != nil)
        #expect(ContentRequests.refusal(for: "summarise my essay") == nil)
    }
}

struct FileNameMatcherTests {
    let files = ["2XQ40-assignment12.pdf", "2XQ40-lecture03.pdf", "assignment-notes.docx", "Tax return 2025.pdf"]
        .map { URL(filePath: "/tmp/names/\($0)") }

    @Test(arguments: ["to XQ 40 assignment 12PDF", "two XQ40 assignment 12PDF", "2 XQ 40 assignment 12 pdf", "the file 2XQ40 assignment 12"])
    func heardNamesFindTheFile(_ spoken: String) {
        #expect(FileNameMatcher.best(for: spoken, among: files)?.lastPathComponent == "2XQ40-assignment12.pdf")
    }

    @Test func gluedExtensionsAreSeparated() {
        #expect(FileNameMatcher.separateExtension("assignment 12PDF") == "assignment 12 PDF")
    }

    @Test func toBetweenWordsStaysAWord() {
        #expect(FileNameMatcher.spokenKey("notes to self").key == "notestoself")
    }

    @Test func unrelatedNamesDontMatch() {
        #expect(FileNameMatcher.best(for: "holiday photos", among: files) == nil)
    }

    @Test(arguments: ["this", "the document which is open", "the open document", "my current pdf", "the document that s open", "the file on my screen"])
    func phrasesForTheOpenDocument(_ phrase: String) {
        #expect(ReadFileTool.refersToFront(AppNameMatcher.normalize(phrase)))
    }

    @Test func aNamedDocumentIsNotTheOpenOne() {
        #expect(!ReadFileTool.refersToFront("the lease document"))
    }

    @Test func fillersDontHideDirectPhrasings() {
        let command = DirectCommand("Can you summarise 2XQ40-assignment12.pdf")
        #expect(command?.original == "summarise 2XQ40-assignment12.pdf")
        let arguments = command.flatMap(ReadFileTool().directArguments(for:))
        #expect(arguments?.action == "summarize")
    }
}

struct TitledDocumentTests {
    @Test func windowTitlesSplitIntoNamePieces() {
        #expect(ReadFileTool.titlePieces("2XQ40-assignment12.pdf – Page 3 of 9") == ["2xq40-assignment12.pdf"])
        #expect(ReadFileTool.titlePieces("Lease Agreement — Edited") == ["lease agreement"])
        #expect(ReadFileTool.titlePieces("notes.txt (2 of 4)") == ["notes.txt"])
    }

    @Test func summarisingTheOpenDocumentIsNotTheMeeting() {
        let command = DirectCommand("Summarise the document that's open")!
        #expect(TranscribeTool().directArguments(for: command) == nil)
        #expect(ReadFileTool().directArguments(for: command)?.action == "summarize")
        #expect(TranscribeTool().directArguments(for: DirectCommand("summarise that meeting")!)?.action == "summarize")
    }
}
