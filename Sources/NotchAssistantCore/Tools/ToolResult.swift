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
    /// Set when the change waits for the user's yes (a batch of files).
    public var confirmation: String?
    /// A file change that "undo" can reverse; its result stays up longer.
    public var undoable: Bool

    public init(_ text: String, items: [ResultItem] = [], confirmation: String? = nil, undoable: Bool = false) {
        self.text = text
        self.items = items
        self.confirmation = confirmation
        self.undoable = undoable
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public init(stringInterpolation: DefaultStringInterpolation) {
        self.init(String(stringInterpolation: stringInterpolation))
    }
}
