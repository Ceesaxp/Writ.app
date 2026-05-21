import Foundation
import Markdown
import WritCore

/// Output of a parse pass over a `DocumentSnapshot`.
public struct ParsedDocument: Sendable {
    public let revision: DocumentRevision
    public let html: String
    public let blocks: [TechnicalBlock]
    public let parseDuration: Duration
    public let renderDuration: Duration
    /// Front-matter key/value pairs extracted from the head of the
    /// source, if any. Nil when the document has no `---`/`+++` block.
    /// Callers (HTML export, etc.) read this for `title`, etc.
    public let frontMatter: FrontMatter?

    public init(
        revision: DocumentRevision,
        html: String,
        blocks: [TechnicalBlock],
        parseDuration: Duration,
        renderDuration: Duration,
        frontMatter: FrontMatter? = nil
    ) {
        self.revision = revision
        self.html = html
        self.blocks = blocks
        self.parseDuration = parseDuration
        self.renderDuration = renderDuration
        self.frontMatter = frontMatter
    }
}

/// Parser protocol so the M0 spike can swap implementations.
public protocol MarkdownParser: Sendable {
    func parse(_ snapshot: DocumentSnapshot) throws -> ParsedDocument
}

public enum ParserKind: String, Sendable, CaseIterable {
    case swiftMarkdown
}

public enum WritParserFactory {
    public static func make(_ kind: ParserKind = .swiftMarkdown) -> any MarkdownParser {
        switch kind {
        case .swiftMarkdown:
            return SwiftMarkdownParser()
        }
    }
}

/// Adapter over `apple/swift-markdown` (which wraps cmark-gfm).
///
/// Walks the AST once, emits HTML, and pulls technical blocks (fenced code by
/// language) into a side list. Math is handled at the source level before
/// parsing — see ``MathPreprocessor`` — because cmark does not understand
/// dollar-delimited math.
public struct SwiftMarkdownParser: MarkdownParser {
    public init() {}

    public func parse(_ snapshot: DocumentSnapshot) throws -> ParsedDocument {
        let parseClock = ContinuousClock()
        let parseStart = parseClock.now

        // Strip leading YAML/TOML front matter before any markdown
        // processing — the body parser shouldn't see `---` lines as
        // thematic breaks, and the `key: value` lines must not become
        // setext-y paragraphs.
        let (frontMatter, bodySource): (FrontMatter?, String)
        if let extracted = FrontMatterExtractor.extract(snapshot.source) {
            frontMatter = extracted.0
            bodySource = extracted.remainder
        } else {
            frontMatter = nil
            bodySource = snapshot.source
        }

        let (preprocessed, mathBlocks) = MathPreprocessor.extract(bodySource)
        let document = Document(parsing: preprocessed, options: [.parseBlockDirectives])

        let parseDuration = parseClock.now - parseStart

        let renderStart = parseClock.now
        var visitor = HTMLEmitter(mathBlocks: mathBlocks, frontMatter: frontMatter)
        let html = visitor.visit(document)
        let renderDuration = parseClock.now - renderStart

        let blocks = visitor.collectedBlocks + mathBlocks.map(\.block)

        return ParsedDocument(
            revision: snapshot.revision,
            html: html,
            blocks: blocks,
            parseDuration: parseDuration,
            renderDuration: renderDuration,
            frontMatter: frontMatter
        )
    }
}
