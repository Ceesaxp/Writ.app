import Foundation
import Markdown
import WritCore

/// Walks a `swift-markdown` AST and emits preview HTML.
///
/// Goals:
/// - Stable per-block IDs (`data-writ-id`) for scroll sync.
/// - Technical fenced blocks (`mermaid`, `plantuml`, `math`) become opaque
///   placeholders; their source travels via `collectedBlocks` so the preview
///   JS can render them asynchronously.
/// - Code blocks emit `<pre><code class="language-foo">` for preview-side
///   syntax highlighting in M2.
struct HTMLEmitter: MarkupWalker {
    var out = ""
    var collectedBlocks: [TechnicalBlock] = []
    private var blockCounter = 0
    private let mathBlocks: [MathPreprocessor.Extracted]
    private let frontMatter: FrontMatter?
    /// Tracks whether the current `emitInline` recursion is inside a
    /// `Link` node. Used to suppress autolink transformation on Text
    /// children so we don't double-link the same span (the parent
    /// `<a>` already wraps them).
    private var insideLink = false

    init(mathBlocks: [MathPreprocessor.Extracted], frontMatter: FrontMatter? = nil) {
        self.mathBlocks = mathBlocks
        self.frontMatter = frontMatter
    }

    mutating func visit(_ document: Document) -> String {
        out = ""
        out.reserveCapacity(document.format().count)
        if let fm = frontMatter, !fm.entries.isEmpty {
            emitFrontMatter(fm)
        }
        for child in document.children {
            visitChild(child)
        }
        return out
    }

    private mutating func emitFrontMatter(_ fm: FrontMatter) {
        let id = nextBlockID("fm")
        let formatLabel = fm.format == .yaml ? "YAML" : "TOML"
        out.append("<dl data-writ-id=\"\(id)\" class=\"writ-front-matter writ-front-matter-\(fm.format == .yaml ? "yaml" : "toml")\">\n")
        out.append("<dt class=\"writ-front-matter-format\">\(formatLabel) front matter</dt>\n")
        out.append("<dd>\n<table>\n")
        for entry in fm.entries {
            out.append("<tr><th>\(escape(entry.key))</th><td>\(escape(entry.value))</td></tr>\n")
        }
        out.append("</table>\n</dd>\n</dl>\n")
    }

    private mutating func nextBlockID(_ prefix: String) -> String {
        defer { blockCounter += 1 }
        return "\(prefix)_\(blockCounter)"
    }

    private mutating func visitChild(_ markup: any Markup) {
        let lineAttr = sourceLineAttribute(for: markup)
        switch markup {
        case let h as Heading:
            let id = nextBlockID("h")
            // Emit an HTML `id` derived from the heading text so the
            // exported document supports in-page anchor navigation
            // and TOC builds. Falls back to the block counter when
            // the slug would be empty (heading was punctuation or
            // pure markdown).
            let slug = HeadingSlug.make(h.plainText)
            // Unprefixed slugs so user-authored cross-references like
            // `[Foo](#foo)` resolve. Falls back to the block counter
            // when the slug would be empty (heading was punctuation or
            // pure markdown).
            let anchor = slug.isEmpty ? id : slug
            out.append("<h\(h.level) id=\"\(anchor)\" data-writ-id=\"\(id)\"\(lineAttr)>")
            emitInlines(h.children)
            out.append("</h\(h.level)>\n")
        case let p as Paragraph:
            let id = nextBlockID("p")
            out.append("<p data-writ-id=\"\(id)\"\(lineAttr)>")
            emitInlines(p.children)
            out.append("</p>\n")
        case let code as CodeBlock:
            let id = nextBlockID("code")
            let language = code.language?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            if language == "mermaid" {
                let blockID = "MERMAID_\(blockCounter - 1)"
                collectedBlocks.append(TechnicalBlock(id: blockID, kind: .mermaid, source: code.code))
                out.append("<div data-writ-id=\"\(id)\"\(lineAttr) data-writ-block=\"\(blockID)\" class=\"writ-mermaid\"></div>\n")
            } else if language == "plantuml" {
                let blockID = "PLANTUML_\(blockCounter - 1)"
                collectedBlocks.append(TechnicalBlock(id: blockID, kind: .plantuml, source: code.code))
                out.append("<div data-writ-id=\"\(id)\"\(lineAttr) data-writ-block=\"\(blockID)\" class=\"writ-plantuml\">")
                out.append("<div class=\"writ-plantuml-notice\">PlantUML rendering is not configured</div>")
                out.append("<pre><code>\(escape(code.code))</code></pre>")
                out.append("</div>\n")
            } else if language == "math" {
                let blockID = "MATH_FENCED_\(blockCounter - 1)"
                collectedBlocks.append(TechnicalBlock(id: blockID, kind: .math, source: code.code))
                out.append("<div data-writ-id=\"\(id)\"\(lineAttr) data-writ-block=\"\(blockID)\" class=\"writ-math-block\"></div>\n")
            } else {
                let langClass = language.isEmpty ? "" : " class=\"language-\(escape(language))\""
                out.append("<pre data-writ-id=\"\(id)\"\(lineAttr)><code\(langClass)>\(escape(code.code))</code></pre>\n")
            }
        case let html as HTMLBlock:
            let id = nextBlockID("html")
            out.append("<div data-writ-id=\"\(id)\"\(lineAttr)>\(HTMLSanitizer.sanitize(html.rawHTML))</div>\n")
        case let list as UnorderedList:
            let id = nextBlockID("ul")
            out.append("<ul data-writ-id=\"\(id)\"\(lineAttr)>\n")
            for item in list.listItems { emitListItem(item) }
            out.append("</ul>\n")
        case let list as OrderedList:
            let id = nextBlockID("ol")
            let startAttr = list.startIndex == 1 ? "" : " start=\"\(list.startIndex)\""
            out.append("<ol data-writ-id=\"\(id)\"\(lineAttr)\(startAttr)>\n")
            for item in list.listItems { emitListItem(item) }
            out.append("</ol>\n")
        case let quote as BlockQuote:
            // GFM-style alert (NOTE / TIP / IMPORTANT / WARNING / CAUTION):
            // first line of the blockquote reads `[!TYPE]` and the rest
            // is the alert body. Render as a typed callout instead of
            // a plain blockquote.
            if let alert = GFMAlert.detect(in: quote) {
                let id = nextBlockID("alert")
                emitAlert(alert, id: id, lineAttr: lineAttr)
            } else {
                let id = nextBlockID("bq")
                out.append("<blockquote data-writ-id=\"\(id)\"\(lineAttr)>\n")
                for child in quote.children { visitChild(child) }
                out.append("</blockquote>\n")
            }
        case is ThematicBreak:
            let id = nextBlockID("hr")
            out.append("<hr data-writ-id=\"\(id)\"\(lineAttr)>\n")
        case is Table:
            emitTable(markup as! Table, lineAttr: lineAttr)
        default:
            // Fallback: render via swift-markdown's debug-format then text only.
            let id = nextBlockID("block")
            out.append("<div data-writ-id=\"\(id)\"\(lineAttr)>")
            for child in markup.children {
                visitChild(child)
            }
            out.append("</div>\n")
        }
    }

    private func sourceLineAttribute(for markup: any Markup) -> String {
        if let line = markup.range?.lowerBound.line {
            return " data-writ-line=\"\(line)\""
        }
        return ""
    }

    private mutating func emitAlert(_ alert: GFMAlert, id: String, lineAttr: String) {
        let cls = "writ-alert writ-alert-\(alert.kind.rawValue)"
        out.append("<div data-writ-id=\"\(id)\"\(lineAttr) class=\"\(cls)\">\n")
        out.append("<div class=\"writ-alert-title\">")
        out.append(alert.kind.iconSVG)
        out.append("<span>\(alert.kind.label)</span>")
        out.append("</div>\n")
        out.append("<div class=\"writ-alert-body\">\n")
        // alert.bodyChildren is the BlockQuote's children minus the
        // marker line; emit them normally so nested markdown still
        // works inside the alert.
        for child in alert.bodyChildren { visitChild(child) }
        out.append("</div>\n</div>\n")
    }

    private mutating func emitListItem(_ item: ListItem) {
        if let checkbox = item.checkbox {
            let checked = checkbox == .checked ? " checked" : ""
            out.append("<li class=\"task-list-item\"><input type=\"checkbox\" disabled\(checked)> ")
        } else {
            out.append("<li>")
        }
        // Tight-list rendering: if the item has a single Paragraph
        // child (the common case — including every task-list item),
        // emit its inlines directly so the checkbox and label stay on
        // the same visual line. Otherwise fall back to full block
        // rendering so nested lists / quotes / code still display.
        let childArray = Array(item.children)
        if childArray.count == 1, let paragraph = childArray[0] as? Paragraph {
            emitInlines(paragraph.children)
        } else {
            for child in childArray { visitChild(child) }
        }
        out.append("</li>\n")
    }

    private mutating func emitTable(_ table: Table, lineAttr: String = "") {
        let id = nextBlockID("table")
        let alignments = table.columnAlignments
        out.append("<table data-writ-id=\"\(id)\"\(lineAttr)>\n<thead><tr>")
        for (index, cell) in table.head.cells.enumerated() {
            let attr = alignAttribute(for: index, in: alignments)
            out.append("<th\(attr)>")
            emitInlines(cell.children)
            out.append("</th>")
        }
        out.append("</tr></thead>\n<tbody>\n")
        for row in table.body.rows {
            out.append("<tr>")
            for (index, cell) in row.cells.enumerated() {
                let attr = alignAttribute(for: index, in: alignments)
                out.append("<td\(attr)>")
                emitInlines(cell.children)
                out.append("</td>")
            }
            out.append("</tr>\n")
        }
        out.append("</tbody></table>\n")
    }

    private func alignAttribute(for column: Int, in alignments: [Table.ColumnAlignment?]) -> String {
        guard column < alignments.count, let alignment = alignments[column] else { return "" }
        switch alignment {
        case .left: return " style=\"text-align:left\""
        case .center: return " style=\"text-align:center\""
        case .right: return " style=\"text-align:right\""
        }
    }

    private mutating func emitInlines(_ inlines: MarkupChildren) {
        for child in inlines { emitInline(child) }
    }

    private mutating func emitInline(_ markup: any Markup) {
        switch markup {
        case let text as Text:
            // Post-process the text: substitute `:shortcode:` emoji
            // and autolink bare URLs. Autolinking is suppressed when
            // we're inside a `Link` already (`insideLink == true`) so
            // we don't double-wrap.
            InlineTextTransform.emit(
                text: text.string,
                allowAutolink: !insideLink,
                into: &out,
                escape: escape
            )
        case let em as Emphasis:
            out.append("<em>")
            for child in em.children { emitInline(child) }
            out.append("</em>")
        case let strong as Strong:
            out.append("<strong>")
            for child in strong.children { emitInline(child) }
            out.append("</strong>")
        case let strike as Strikethrough:
            out.append("<del>")
            for child in strike.children { emitInline(child) }
            out.append("</del>")
        case let code as InlineCode:
            out.append("<code>\(escape(code.code))</code>")
        case let link as Link:
            let dest = escape(link.destination ?? "")
            out.append("<a href=\"\(dest)\">")
            let priorInsideLink = insideLink
            insideLink = true
            for child in link.children { emitInline(child) }
            insideLink = priorInsideLink
            out.append("</a>")
        case let image as Image:
            let src = escape(image.source ?? "")
            let alt = image.plainText
            out.append("<img src=\"\(src)\" alt=\"\(escape(alt))\">")
        case let html as InlineHTML:
            out.append(HTMLSanitizer.sanitize(html.rawHTML))
        case is LineBreak:
            out.append("<br>\n")
        case is SoftBreak:
            out.append("\n")
        default:
            for child in markup.children { emitInline(child) }
        }
    }

    private func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out.append("&amp;")
            case "<": out.append("&lt;")
            case ">": out.append("&gt;")
            case "\"": out.append("&quot;")
            case "'": out.append("&#39;")
            default: out.append(ch)
            }
        }
        return out
    }
}
