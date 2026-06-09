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
    private let lineTable: LineTable

    init(source: String) {
        self.source = source
        self.nsSource = source as NSString
        self.lineTable = LineTable(source: source)
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

        // swift-markdown returns 1-indexed line/column. Columns come from
        // cmark, which counts UTF-8 bytes; NSTextStorage uses UTF-16 units.
        let startOffset = utf16Offset(line: startLine, column: startColumn)
        let endOffset = utf16Offset(line: endLine, column: endColumn)
        guard startOffset >= 0, endOffset >= startOffset else { return nil }
        return NSRange(location: startOffset, length: endOffset - startOffset)
    }

    private func utf16Offset(line: Int, column: Int) -> Int {
        // cmark reports `column` as a 1-based UTF-8 byte position within
        // the line; NSTextStorage indexes by UTF-16 code units. The line
        // table pre-computes UTF-16 offsets of each line start (O(N) once
        // per Walker), so this lookup is O(1) jump + a short walk that
        // stays inside one line — replacing the previous O(doc) per-call
        // scan that was 54% of typing-hang time on a 1000-line doc.
        return lineTable.utf16Offset(line: line, column: column)
    }
}

/// Maps cmark-style (line, UTF-8 byte column) coordinates to UTF-16
/// offsets without re-walking the document on every call.
///
/// `Walker.utf16Offset` used to scan all scalars from the document start
/// on every lookup. With many markdown nodes that becomes O(nodes × doc)
/// per highlight pass — the dominant cost in the typing-latency hunt of
/// 2026-06-09. The table is constructed once per parse: one O(N) walk
/// records the UTF-16 offset and scalar index of each line start. Each
/// subsequent lookup jumps to the right line in O(1) and walks only that
/// line's bytes/scalars to refine the column.
struct LineTable {
    private let source: String
    private let lineStartUtf16: [Int]
    private let lineStartScalar: [String.UnicodeScalarView.Index]

    init(source: String) {
        self.source = source
        var startsUtf16: [Int] = [0]
        var startsScalar: [String.UnicodeScalarView.Index] = [source.unicodeScalars.startIndex]
        var utf16 = 0
        var idx = source.unicodeScalars.startIndex
        let end = source.unicodeScalars.endIndex
        while idx < end {
            let scalar = source.unicodeScalars[idx]
            utf16 += scalar.utf16.count
            idx = source.unicodeScalars.index(after: idx)
            if scalar == "\n" {
                startsUtf16.append(utf16)
                startsScalar.append(idx)
            }
        }
        self.lineStartUtf16 = startsUtf16
        self.lineStartScalar = startsScalar
    }

    func utf16Offset(line: Int, column: Int) -> Int {
        guard !lineStartUtf16.isEmpty else { return 0 }
        let clampedLine = max(1, min(line, lineStartUtf16.count))
        let lineIdx = clampedLine - 1
        var utf16 = lineStartUtf16[lineIdx]
        if column <= 1 { return utf16 }
        var byteCol = 1
        var idx = lineStartScalar[lineIdx]
        let end = source.unicodeScalars.endIndex
        while idx < end && byteCol < column {
            let scalar = source.unicodeScalars[idx]
            if scalar == "\n" { return utf16 }
            byteCol += scalar.utf8.count
            utf16 += scalar.utf16.count
            idx = source.unicodeScalars.index(after: idx)
        }
        return utf16
    }
}
