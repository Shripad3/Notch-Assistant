import Foundation

/// A row in a result list, such as a found file. `id` is an opaque token
/// (spec §9): the UI never holds a path, and selecting a row goes back
/// through the executor, which validates again before acting.
public struct ResultItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String
    public let symbol: String

    public init(id: String, title: String, detail: String, symbol: String) {
        self.id = id
        self.title = title
        self.detail = detail
        self.symbol = symbol
    }
}

/// What a tool reports: a one-line outcome, and optionally items to choose
/// from. A string literal is a plain outcome, so most tools just return text.
public struct ToolResult: Sendable, Equatable, ExpressibleByStringInterpolation {
    public var text: String
    public var items: [ResultItem]

    public init(_ text: String, items: [ResultItem] = []) {
        self.text = text
        self.items = items
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public init(stringInterpolation: DefaultStringInterpolation) {
        self.init(String(stringInterpolation: stringInterpolation))
    }
}
