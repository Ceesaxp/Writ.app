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

    init(mathBlocks: [MathPreprocessor.Extracted]) {
        self.mathBlocks = mathBlocks
    }

    mutating func visit(_ document: Document) -> String {
        out = ""
        out.reserveCapacity(document.format().count)
        for child in document.children {
            visitChild(child)
        }
        return out
    }

    private mutating func nextBlockID(_ prefix: String) -> String {
        defer { blockCounter += 1 }
        return "\(prefix)_\(blockCounter)"
    }

    private mutating func visitChild(_ markup: any Markup) {
        switch markup {
        case let h as Heading:
            let id = nextBlockID("h")
            out.append("<h\(h.level) data-writ-id=\"\(id)\">")
            emitInlines(h.children)
            out.append("</h\(h.level)>\n")
        case let p as Paragraph:
            let id = nextBlockID("p")
            out.append("<p data-writ-id=\"\(id)\">")
            emitInlines(p.children)
            out.append("</p>\n")
        case let code as CodeBlock:
            let id = nextBlockID("code")
            let language = code.language?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            if language == "mermaid" {
                let blockID = "MERMAID_\(blockCounter - 1)"
                collectedBlocks.append(TechnicalBlock(id: blockID, kind: .mermaid, source: code.code))
                out.append("<div data-writ-id=\"\(id)\" data-writ-block=\"\(blockID)\" class=\"writ-mermaid\"></div>\n")
            } else if language == "plantuml" {
                let blockID = "PLANTUML_\(blockCounter - 1)"
                collectedBlocks.append(TechnicalBlock(id: blockID, kind: .plantuml, source: code.code))
                out.append("<div data-writ-id=\"\(id)\" data-writ-block=\"\(blockID)\" class=\"writ-plantuml\">")
                out.append("<div class=\"writ-plantuml-notice\">PlantUML rendering is not configured</div>")
                out.append("<pre><code>\(escape(code.code))</code></pre>")
                out.append("</div>\n")
            } else if language == "math" {
                let blockID = "MATH_FENCED_\(blockCounter - 1)"
                collectedBlocks.append(TechnicalBlock(id: blockID, kind: .math, source: code.code))
                out.append("<div data-writ-id=\"\(id)\" data-writ-block=\"\(blockID)\" class=\"writ-math-block\"></div>\n")
            } else {
                let langClass = language.isEmpty ? "" : " class=\"language-\(escape(language))\""
                out.append("<pre data-writ-id=\"\(id)\"><code\(langClass)>\(escape(code.code))</code></pre>\n")
            }
        case let html as HTMLBlock:
            let id = nextBlockID("html")
            out.append("<div data-writ-id=\"\(id)\">\(html.rawHTML)</div>\n")
        case let list as UnorderedList:
            let id = nextBlockID("ul")
            out.append("<ul data-writ-id=\"\(id)\">\n")
            for item in list.listItems { emitListItem(item) }
            out.append("</ul>\n")
        case let list as OrderedList:
            let id = nextBlockID("ol")
            let startAttr = list.startIndex == 1 ? "" : " start=\"\(list.startIndex)\""
            out.append("<ol data-writ-id=\"\(id)\"\(startAttr)>\n")
            for item in list.listItems { emitListItem(item) }
            out.append("</ol>\n")
        case let quote as BlockQuote:
            let id = nextBlockID("bq")
            out.append("<blockquote data-writ-id=\"\(id)\">\n")
            for child in quote.children { visitChild(child) }
            out.append("</blockquote>\n")
        case is ThematicBreak:
            let id = nextBlockID("hr")
            out.append("<hr data-writ-id=\"\(id)\">\n")
        case let table as Table:
            emitTable(table)
        default:
            // Fallback: render via swift-markdown's debug-format then text only.
            let id = nextBlockID("block")
            out.append("<div data-writ-id=\"\(id)\">")
            for child in markup.children {
                visitChild(child)
            }
            out.append("</div>\n")
        }
    }

    private mutating func emitListItem(_ item: ListItem) {
        if let checkbox = item.checkbox {
            let checked = checkbox == .checked ? " checked" : ""
            out.append("<li class=\"task-list-item\"><input type=\"checkbox\" disabled\(checked)> ")
        } else {
            out.append("<li>")
        }
        for child in item.children { visitChild(child) }
        out.append("</li>\n")
    }

    private mutating func emitTable(_ table: Table) {
        let id = nextBlockID("table")
        out.append("<table data-writ-id=\"\(id)\">\n<thead><tr>")
        for cell in table.head.cells {
            out.append("<th>")
            emitInlines(cell.children)
            out.append("</th>")
        }
        out.append("</tr></thead>\n<tbody>\n")
        for row in table.body.rows {
            out.append("<tr>")
            for cell in row.cells {
                out.append("<td>")
                emitInlines(cell.children)
                out.append("</td>")
            }
            out.append("</tr>\n")
        }
        out.append("</tbody></table>\n")
    }

    private mutating func emitInlines(_ inlines: MarkupChildren) {
        for child in inlines { emitInline(child) }
    }

    private mutating func emitInline(_ markup: any Markup) {
        switch markup {
        case let text as Text:
            out.append(escape(text.string))
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
            for child in link.children { emitInline(child) }
            out.append("</a>")
        case let image as Image:
            let src = escape(image.source ?? "")
            let alt = image.plainText
            out.append("<img src=\"\(src)\" alt=\"\(escape(alt))\">")
        case let html as InlineHTML:
            out.append(html.rawHTML)
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
