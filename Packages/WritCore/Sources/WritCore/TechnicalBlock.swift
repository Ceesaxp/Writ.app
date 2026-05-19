import Foundation

/// Kinds of preview-rendered blocks that benefit from caching by content hash.
public enum TechnicalBlockKind: String, Sendable, Hashable, CaseIterable {
    case math
    case mathInline
    case mermaid
    case plantuml
    case code
    case svgInline
}

/// A technical block extracted from the Markdown source.
///
/// Holds the original source text, a stable block identifier (used for the
/// preview DOM and scroll sync), and the kind. The renderer pipeline turns
/// these into placeholders during HTML generation and fills them in
/// asynchronously.
public struct TechnicalBlock: Sendable, Hashable {
    public let id: String
    public let kind: TechnicalBlockKind
    public let source: String
    public let language: String?
    public let sourceRange: Range<Int>?

    public init(
        id: String,
        kind: TechnicalBlockKind,
        source: String,
        language: String? = nil,
        sourceRange: Range<Int>? = nil
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.language = language
        self.sourceRange = sourceRange
    }

    public var contentHash: ContentHash {
        ContentHash.combining([kind.rawValue, language ?? "", source])
    }
}
