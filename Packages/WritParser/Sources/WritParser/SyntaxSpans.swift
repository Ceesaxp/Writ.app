import Foundation
import Markdown
import WritCore

/// A single styled range within the source.
///
/// Spans are produced by `SyntaxSpanExtractor` from a `swift-markdown` AST
/// and consumed by the editor's syntax highlighter to apply attributes.
/// Coordinates are measured in **UTF-16 code units** because NSTextStorage /
/// NSAttributedString use that range domain.
public struct SyntaxSpan: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case heading           // # … #####
        case headingMarker     // the leading # signs only
        case emphasis          // *italic* / _italic_
        case strong            // **bold**
        case strikethrough     // ~~text~~
        case inlineCode        // `code`
        case codeBlock         // ```...``` body
        case codeBlockFence    // ``` lines
        case codeBlockLang     // language tag after the opening fence
        case mathInline        // $...$
        case mathBlock         // $$...$$
        case mathFence         // the $$ / ``` `math` markers
        case link              // [text](url)
        case linkURL           // (url) part
        case image             // ![alt](url)
        case blockquote        // > line
        case listMarker        // -, *, +, 1.
        case taskMarker        // - [ ] / - [x]
        case htmlBlock         // raw inline / block HTML
        case thematicBreak     // ---
        case tableSeparator    // | --- | --- |
        case frontMatter       // YAML --- / TOML +++ block at document head
    }

    public let range: NSRange
    public let kind: Kind

    public init(range: NSRange, kind: Kind) {
        self.range = range
        self.kind = kind
    }
}

/// Produces `[SyntaxSpan]` for an entire source string by parsing with
/// `swift-markdown` and walking the resulting tree. Spans are merged-friendly:
/// the editor applies them in order, so later spans win if there is overlap.
public struct SyntaxSpanExtractor {
    public init() {}

    public func extract(from source: String) -> [SyntaxSpan] {
        // swift-markdown gives us source byte ranges only when we ask it to.
        let document = Document(parsing: source, options: [.parseBlockDirectives])
        var visitor = Walker(source: source)
        visitor.visit(document)
        // Front matter wins over everything else inside its range.
        // The apply loop is last-write-wins on overlap, so this goes
        // at the END — the AST walker will have emitted spans for
        // the `---` lines as thematic breaks (or a setext heading
        // for `+++`) which we want overwritten with the muted FM
        // styling.
        if let fmRange = frontMatterRange(in: source) {
            visitor.spans.append(SyntaxSpan(range: fmRange, kind: .frontMatter))
        }
        return visitor.spans
    }

    private func frontMatterRange(in source: String) -> NSRange? {
        // Reuse FrontMatterExtractor so the editor and the renderer
        // agree byte-for-byte on what counts as front matter.
        guard let (fm, _) = FrontMatterExtractor.extract(source) else { return nil }
        // FrontMatter.charCount is measured in Character units (the
        // extractor walks Swift Strings). Map back to NSRange / UTF-16
        // by taking the prefix and asking for its UTF-16 length.
        let prefix = source.prefix(fm.charCount)
        let utf16Length = (String(prefix) as NSString).length
        return NSRange(location: 0, length: utf16Length)
    }
}

private struct Walker: MarkupWalker {
    let source: String
    var spans: [SyntaxSpan] = []
    private let nsSource: NSString

    init(source: String) {
        self.source = source
        self.nsSource = source as NSString
    }

    mutating func visit(_ document: Document) {
        for child in document.children { visitChild(child) }
        scanLineLevelTokens()
    }

    private mutating func visitChild(_ markup: any Markup) {
        switch markup {
        case is Heading:
            if let range = utf16Range(of: markup) {
                spans.append(SyntaxSpan(range: range, kind: .heading))
            }
        case let code as CodeBlock:
            if let range = utf16Range(of: code) {
                spans.append(SyntaxSpan(range: range, kind: .codeBlock))
            }
        case is BlockQuote:
            // Children handled normally; the leading "> " is caught in line scan.
            break
        case let html as HTMLBlock:
            if let range = utf16Range(of: html) {
                spans.append(SyntaxSpan(range: range, kind: .htmlBlock))
            }
        case is ThematicBreak:
            if let range = utf16Range(of: markup) {
                spans.append(SyntaxSpan(range: range, kind: .thematicBreak))
            }
        default:
            break
        }
        // Inline traversal for non-leaf blocks.
        for child in markup.children { visitInline(child); visitChild(child) }
    }

    private mutating func visitInline(_ markup: any Markup) {
        switch markup {
        case let strong as Strong:
            if let range = utf16Range(of: strong) {
                spans.append(SyntaxSpan(range: range, kind: .strong))
            }
        case let em as Emphasis:
            if let range = utf16Range(of: em) {
                spans.append(SyntaxSpan(range: range, kind: .emphasis))
            }
        case let strike as Strikethrough:
            if let range = utf16Range(of: strike) {
                spans.append(SyntaxSpan(range: range, kind: .strikethrough))
            }
        case let code as InlineCode:
            if let range = utf16Range(of: code) {
                spans.append(SyntaxSpan(range: range, kind: .inlineCode))
            }
        case let link as Link:
            if let range = utf16Range(of: link) {
                spans.append(SyntaxSpan(range: range, kind: .link))
            }
        case let image as Image:
            if let range = utf16Range(of: image) {
                spans.append(SyntaxSpan(range: range, kind: .image))
            }
        default:
            break
        }
        for child in markup.children { visitInline(child) }
    }

    /// Walks the source line-by-line and emits spans for constructs whose
    /// recognition is cheap from a text scan: math ($...$ and $$...$$),
    /// list/task markers, blockquote markers, table-separator rows.
    /// Doing this here lets us keep the AST walk focused on block-level
    /// constructs.
    private mutating func scanLineLevelTokens() {
        let length = nsSource.length
        let mathInline = try! NSRegularExpression(pattern: "(?<!\\\\)\\$[^\\$\\n]+?\\$")
        let mathBlock = try! NSRegularExpression(pattern: "\\$\\$[\\s\\S]*?\\$\\$")
        let listMarker = try! NSRegularExpression(pattern: "^\\s*([-*+]|\\d+\\.)\\s", options: [.anchorsMatchLines])
        let taskMarker = try! NSRegularExpression(pattern: "^\\s*[-*+]\\s+\\[[ xX]\\]", options: [.anchorsMatchLines])
        let blockquote = try! NSRegularExpression(pattern: "^>\\s.*$", options: [.anchorsMatchLines])
        let tableSep = try! NSRegularExpression(pattern: "^\\s*\\|?\\s*:?-+:?(\\s*\\|\\s*:?-+:?)+\\s*\\|?\\s*$", options: [.anchorsMatchLines])

        // Math (block) ranges across whole source.
        mathBlock.enumerateMatches(in: source, range: NSRange(location: 0, length: length)) { match, _, _ in
            guard let r = match?.range else { return }
            spans.append(SyntaxSpan(range: r, kind: .mathBlock))
        }
        // Math (inline) ranges across whole source. Cheap to do once globally.
        mathInline.enumerateMatches(in: source, range: NSRange(location: 0, length: length)) { match, _, _ in
            guard let r = match?.range else { return }
            spans.append(SyntaxSpan(range: r, kind: .mathInline))
        }
        // List, task, blockquote, table-separator markers (per-line).
        listMarker.enumerateMatches(in: source, options: [], range: NSRange(location: 0, length: length)) { match, _, _ in
            guard let r = match?.range else { return }
            spans.append(SyntaxSpan(range: r, kind: .listMarker))
        }
        taskMarker.enumerateMatches(in: source, options: [], range: NSRange(location: 0, length: length)) { match, _, _ in
            guard let r = match?.range else { return }
            spans.append(SyntaxSpan(range: r, kind: .taskMarker))
        }
        blockquote.enumerateMatches(in: source, options: [], range: NSRange(location: 0, length: length)) { match, _, _ in
            guard let r = match?.range else { return }
            spans.append(SyntaxSpan(range: r, kind: .blockquote))
        }
        tableSep.enumerateMatches(in: source, options: [], range: NSRange(location: 0, length: length)) { match, _, _ in
            guard let r = match?.range else { return }
            spans.append(SyntaxSpan(range: r, kind: .tableSeparator))
        }
    }

    private func utf16Range(of markup: any Markup) -> NSRange? {
        guard let sourceRange = markup.range else { return nil }
        let startLine = sourceRange.lowerBound.line
        let startColumn = sourceRange.lowerBound.column
        let endLine = sourceRange.upperBound.line
        let endColumn = sourceRange.upperBound.column

        // swift-markdown returns 1-indexed line/column in source-bytes; we
        // translate to UTF-16 offsets that NSTextStorage uses.
        let startOffset = utf16Offset(line: startLine, column: startColumn)
        let endOffset = utf16Offset(line: endLine, column: endColumn)
        guard startOffset >= 0, endOffset >= startOffset else { return nil }
        return NSRange(location: startOffset, length: endOffset - startOffset)
    }

    private func utf16Offset(line: Int, column: Int) -> Int {
        // 1-indexed line and column. Walk the UTF-16 view counting newlines.
        var currentLine = 1
        var currentColumn = 1
        var offset = 0
        let utf16 = source.utf16
        var idx = utf16.startIndex
        while idx < utf16.endIndex {
            if currentLine == line && currentColumn == column { return offset }
            if utf16[idx] == 0x0A {
                if currentLine == line { return offset } // end of target line
                currentLine += 1
                currentColumn = 1
            } else {
                currentColumn += 1
            }
            idx = utf16.index(after: idx)
            offset += 1
        }
        return offset
    }
}
