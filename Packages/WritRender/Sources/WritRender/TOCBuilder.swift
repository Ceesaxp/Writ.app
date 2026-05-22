import Foundation
import WritParser

/// Builds a table-of-contents HTML fragment from a document's headings.
///
/// Anchors target the unprefixed `id="<slug>"` form that `HTMLEmitter`
/// writes on each heading element. Levels are nested via `<ol>` to give
/// the export a readable hierarchy without inline-level CSS hacks.
public enum TOCBuilder {
    /// Emits a `<nav class="writ-toc">` block. Returns the empty string
    /// when the document has no headings — the caller can prepend
    /// unconditionally and get the right result either way.
    public static func render(from source: String, title: String = "Contents") -> String {
        let headings = OutlineExtractor.extract(from: source)
        guard !headings.isEmpty else { return "" }

        var out = "<nav class=\"writ-toc\" aria-label=\"Table of contents\">\n"
        out.append("<h2 class=\"writ-toc-title\">\(escapeHTML(title))</h2>\n")

        var currentLevel = headings[0].level
        out.append("<ol>\n")
        for (idx, heading) in headings.enumerated() {
            // Open/close <ol> as the level changes. The starting level
            // is anchored on the first heading so a document that
            // starts at H2 still produces a single-rooted tree.
            if heading.level > currentLevel {
                for _ in 0..<(heading.level - currentLevel) { out.append("<ol>\n") }
                currentLevel = heading.level
            } else if heading.level < currentLevel {
                for _ in 0..<(currentLevel - heading.level) {
                    out.append("</li>\n</ol>\n")
                }
                currentLevel = heading.level
                out.append("</li>\n")
            } else if idx > 0 {
                out.append("</li>\n")
            }
            let slug = HeadingSlug.make(heading.title)
            let anchor = slug.isEmpty ? "" : "#\(slug)"
            out.append("<li><a href=\"\(anchor)\">\(escapeHTML(heading.title))</a>")
        }
        // Close out any open levels.
        out.append("</li>\n")
        while currentLevel > headings[0].level {
            out.append("</ol>\n</li>\n")
            currentLevel -= 1
        }
        out.append("</ol>\n</nav>\n")
        return out
    }

    private static func escapeHTML(_ s: String) -> String {
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
