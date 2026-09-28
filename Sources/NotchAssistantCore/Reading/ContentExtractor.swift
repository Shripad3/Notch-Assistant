import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers
@preconcurrency import Vision

/// A document's text, split into its natural parts (pages, slides, sheets).
public struct ExtractedDocument: Sendable, Equatable {
    public struct Section: Sendable, Equatable {
        /// "Page 3", "Slide 2", "Sheet Budget"; nil for plain text.
        public let label: String?
        public let text: String
    }

    public let name: String
    public let sections: [Section]
    /// "pages", "slides", "sheets", or nil.
    public let unit: String?
    /// Rows in a spreadsheet or CSV.
    public let rows: Int?
    /// Pages read by text recognition (scanned PDFs, images).
    public let recognizedPages: Int

    public var text: String { sections.map(\.text).joined(separator: "\n\n") }
    public var wordCount: Int { text.split { $0.isWhitespace || $0.isNewline }.count }
    public var paragraphs: [String] {
        text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Reads the text out of a file, by type. Read-only: nothing here writes.
public enum ContentExtractor {
    /// Beyond this, Alfred offers to read a part instead.
    static let maximumBytes = 60_000_000
    /// Scanned pages recognised at most, to bound the wait.
    static let maximumRecognizedPages = 40

    public static func extract(_ url: URL) async throws -> ExtractedDocument {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        if let size = values?.fileSize, size > maximumBytes {
            throw ToolError("That file is too big to read in one go (\(size / 1_000_000) MB)")
        }
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        if type.conforms(to: .pdf) { return try await pdf(url, name: name) }
        if type.conforms(to: .image) { return try await image(url, name: name) }
        switch ext {
        case "docx", "doc", "odt", "rtf", "rtfd", "html", "htm", "webarchive":
            return try attributed(url, name: name, ext: ext)
        case "pptx": return try slides(url, name: name)
        case "xlsx": return try sheets(url, name: name)
        case "eml": return try email(url, name: name)
        case "pages", "numbers", "key":
            throw ToolError("I can't read Pages, Numbers or Keynote files yet. Export it as PDF or Word and I can")
        default:
            break
        }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json)
            || ["md", "csv", "tsv", "log", "yaml", "yml", "toml", "swift", "py", "js", "ts", "tex"].contains(ext) {
            return try plain(url, name: name, ext: ext)
        }
        throw ToolError("I can't read \(ext.isEmpty ? "that kind of" : ext.uppercased()) files")
    }

    // MARK: Plain text

    static func plain(_ url: URL, name: String, ext: String) throws -> ExtractedDocument {
        var encoding = String.Encoding.utf8
        let text: String
        if let decoded = try? String(contentsOf: url, usedEncoding: &encoding) {
            text = decoded
        } else {
            text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        }
        let rows = ["csv", "tsv"].contains(ext) ? text.split(whereSeparator: \.isNewline).count : nil
        return ExtractedDocument(name: name, sections: [.init(label: nil, text: text)], unit: nil, rows: rows, recognizedPages: 0)
    }

    // MARK: PDF

    static func pdf(_ url: URL, name: String) async throws -> ExtractedDocument {
        guard let document = PDFDocument(url: url) else { throw ToolError("That PDF won't open") }
        if document.isLocked { throw ToolError("That PDF is password-protected") }
        var sections: [ExtractedDocument.Section] = []
        var recognized = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // A scanned page has no text layer: recognise it.
            if text.count < 20, recognized < maximumRecognizedPages, let image = render(page) {
                text = (try? await recognize(image)) ?? text
                recognized += 1
            }
            sections.append(.init(label: "Page \(index + 1)", text: text))
        }
        return ExtractedDocument(name: name, sections: sections, unit: "pages", rows: nil, recognizedPages: recognized)
    }

    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    // MARK: Images

    static func image(_ url: URL, name: String) async throws -> ExtractedDocument {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ToolError("That image won't open")
        }
        let text = try await recognize(image)
        return ExtractedDocument(name: name, sections: [.init(label: nil, text: text)], unit: nil, rows: nil, recognizedPages: 1)
    }

    /// Vision's text recognition, accurate mode, on this Mac.
    static func recognize(_ image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let lines = (request.results as? [VNRecognizedTextObservation] ?? []).compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: Word, RTF, HTML

    static func attributed(_ url: URL, name: String, ext: String) throws -> ExtractedDocument {
        let type: NSAttributedString.DocumentType = switch ext {
        case "docx": .officeOpenXML
        case "doc": .docFormat
        case "odt": .openDocument
        case "rtf": .rtf
        case "rtfd": .rtfd
        case "webarchive": .webArchive
        default: .html
        }
        let text = try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil).string
        return ExtractedDocument(name: name, sections: [.init(label: nil, text: text)], unit: nil, rows: nil, recognizedPages: 0)
    }

    // MARK: PowerPoint and Excel (zip packages of XML)

    static func slides(_ url: URL, name: String) throws -> ExtractedDocument {
        guard let zip = ZipReader(data: try Data(contentsOf: url)) else { throw ToolError("That presentation won't open") }
        let slideFiles = zip.names.filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted { number(in: $0) < number(in: $1) }
        let sections = slideFiles.enumerated().map { index, file in
            ExtractedDocument.Section(label: "Slide \(index + 1)", text: zip.file(file).map { XMLText.runs(in: $0, element: "a:t").joined(separator: " ") } ?? "")
        }
        return ExtractedDocument(name: name, sections: sections, unit: "slides", rows: nil, recognizedPages: 0)
    }

    static func sheets(_ url: URL, name: String) throws -> ExtractedDocument {
        guard let zip = ZipReader(data: try Data(contentsOf: url)) else { throw ToolError("That spreadsheet won't open") }
        let shared = zip.file("xl/sharedStrings.xml").map(XMLText.sharedStrings) ?? []
        let sheetNames = zip.file("xl/workbook.xml").map { XMLText.attributes(in: $0, element: "sheet", attribute: "name") } ?? []
        let sheetFiles = zip.names.filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
            .sorted { number(in: $0) < number(in: $1) }
        var rows = 0
        let sections = sheetFiles.enumerated().map { index, file -> ExtractedDocument.Section in
            let table = zip.file(file).map { XMLText.rows(in: $0, shared: shared) } ?? []
            rows += table.count
            let label = index < sheetNames.count ? "Sheet \(sheetNames[index])" : "Sheet \(index + 1)"
            return .init(label: label, text: table.map { $0.joined(separator: "\t") }.joined(separator: "\n"))
        }
        return ExtractedDocument(name: name, sections: sections, unit: "sheets", rows: rows, recognizedPages: 0)
    }

    private static func number(in path: String) -> Int {
        Int(path.filter(\.isNumber)) ?? 0
    }

    // MARK: Email

    static func email(_ url: URL, name: String) throws -> ExtractedDocument {
        let raw = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        return ExtractedDocument(name: name, sections: [.init(label: nil, text: MIMEText.readable(raw))], unit: nil, rows: nil, recognizedPages: 0)
    }
}

/// Just enough XML reading for Office files.
enum XMLText {
    /// The text inside every `<element>…</element>`.
    static func runs(in data: Data, element: String) -> [String] {
        let collector = Collector(element: element)
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.parse()
        return collector.values
    }

    static func attributes(in data: Data, element: String, attribute: String) -> [String] {
        let collector = Collector(element: element, attribute: attribute)
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.parse()
        return collector.values
    }

    /// Excel's shared strings: each `<si>` may hold several `<t>` runs.
    static func sharedStrings(_ data: Data) -> [String] {
        let collector = SharedStrings()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.parse()
        return collector.strings
    }

    /// A worksheet's rows as cell text.
    static func rows(in data: Data, shared: [String]) -> [[String]] {
        let collector = SheetRows(shared: shared)
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.parse()
        return collector.rows.filter { !$0.allSatisfy(\.isEmpty) }
    }

    private final class Collector: NSObject, XMLParserDelegate {
        let element: String
        let attribute: String?
        var values: [String] = []
        private var current: String?

        init(element: String, attribute: String? = nil) {
            self.element = element
            self.attribute = attribute
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            guard name == element else { return }
            if let attribute {
                if let value = attributes[attribute] { values.append(value) }
            } else {
                current = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            current? += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard name == element, let text = current else { return }
            values.append(text)
            current = nil
        }
    }

    private final class SharedStrings: NSObject, XMLParserDelegate {
        var strings: [String] = []
        private var item: String?
        private var inText = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            if name == "si" { item = "" }
            if name == "t" { inText = true }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { item? += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "t" { inText = false }
            if name == "si" {
                strings.append(item ?? "")
                item = nil
            }
        }
    }

    private final class SheetRows: NSObject, XMLParserDelegate {
        let shared: [String]
        var rows: [[String]] = []
        private var row: [String] = []
        private var cellType: String?
        private var value: String?
        private var inline = false

        init(shared: [String]) { self.shared = shared }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            switch name {
            case "row": row = []
            case "c": cellType = attributes["t"]; value = nil
            case "v": value = ""
            case "t" where cellType == "inlineStr": inline = true; value = value ?? ""
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if value != nil { value? += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "c":
                var text = value ?? ""
                if cellType == "s", let index = Int(text), shared.indices.contains(index) { text = shared[index] }
                row.append(text)
                inline = false
            case "row":
                rows.append(row)
            default: break
            }
        }
    }
}

/// An email's headers and its readable text part.
enum MIMEText {
    static func readable(_ raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let parts = normalized.components(separatedBy: "\n\n")
        let headerBlock = parts.first ?? ""
        let headers = unfold(headerBlock)
        let wanted = ["From", "To", "Date", "Subject"].compactMap { key in headers[key.lowercased()].map { "\(key): \($0)" } }
        let body = String(normalized.dropFirst(headerBlock.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        let text = textPart(body, contentType: headers["content-type"] ?? "text/plain", encoding: headers["content-transfer-encoding"])
        return (wanted + ["", text]).joined(separator: "\n")
    }

    private static func unfold(_ block: String) -> [String: String] {
        var headers: [String: String] = [:]
        var last: String?
        for line in block.components(separatedBy: "\n") {
            if line.first == " " || line.first == "\t", let last {
                headers[last, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].lowercased()
                headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                last = key
            }
        }
        return headers
    }

    private static func textPart(_ body: String, contentType: String, encoding: String?) -> String {
        if contentType.lowercased().contains("multipart"), let range = contentType.range(of: "boundary=") {
            let boundary = contentType[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "\"; "))
                .components(separatedBy: ";").first ?? ""
            let parts = body.components(separatedBy: "--" + boundary)
            // Prefer text/plain; fall back to HTML stripped of tags.
            for preferred in ["text/plain", "text/html"] {
                for part in parts {
                    let pieces = part.components(separatedBy: "\n\n")
                    let headers = unfold(pieces.first?.trimmingCharacters(in: .newlines) ?? "")
                    guard (headers["content-type"] ?? "").lowercased().contains(preferred) else { continue }
                    let content = pieces.dropFirst().joined(separator: "\n\n")
                    let decoded = decode(content, encoding: headers["content-transfer-encoding"])
                    return preferred == "text/html" ? stripTags(decoded) : decoded
                }
            }
            return ""
        }
        let decoded = decode(body, encoding: encoding)
        return contentType.lowercased().contains("html") ? stripTags(decoded) : decoded
    }

    static func decode(_ text: String, encoding: String?) -> String {
        switch encoding?.lowercased() {
        case "base64"?:
            return Data(base64Encoded: text.filter { !$0.isWhitespace }).map { String(decoding: $0, as: UTF8.self) } ?? text
        case "quoted-printable"?:
            var bytes: [UInt8] = []
            let soft = text.replacingOccurrences(of: "=\n", with: "")
            var index = soft.startIndex
            while index < soft.endIndex {
                let char = soft[index]
                if char == "=", let end = soft.index(index, offsetBy: 3, limitedBy: soft.endIndex), let byte = UInt8(soft[soft.index(after: index)..<end], radix: 16) {
                    bytes.append(byte)
                    index = end
                } else {
                    bytes.append(contentsOf: Array(String(char).utf8))
                    index = soft.index(after: index)
                }
            }
            return String(decoding: bytes, as: UTF8.self)
        default:
            return text
        }
    }

    private static func stripTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
    }
}
