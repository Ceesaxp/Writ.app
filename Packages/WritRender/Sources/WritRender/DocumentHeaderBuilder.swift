import Foundation
import WritParser

/// Builds an export-only `<header class="writ-doc-header">` block from
/// front-matter `title` / `description` / `author` / `date` (or
/// `date_created`). The preview pane keeps its dimmed
/// `<dl class="writ-front-matter">` card unchanged — this header is
/// emitted into HTML / PDF exports in addition to that card, with CSS
/// hiding the card whenever `body.writ-export` is set.
///
/// Returns `nil` when none of the four fields are present, so the
/// caller can omit the block entirely (no empty `<header>` in the
/// output).
public enum DocumentHeaderBuilder {
    public struct Rendered: Sendable, Equatable {
        public let html: String
        public let tags: [String]
        public init(html: String, tags: [String]) {
            self.html = html
            self.tags = tags
        }
    }

    public static func render(frontMatter: FrontMatter?) -> Rendered? {
        guard let fm = frontMatter else { return nil }

        let title = fm["title"]?.nonEmpty
        let description = fm["description"]?.nonEmpty
        let author = fm["author"]?.nonEmpty
        let date = (fm["date"] ?? fm["date_created"])?.nonEmpty

        if title == nil, description == nil, author == nil, date == nil {
            return nil
        }

        var out = ""
        let tagsAttr: String
        if fm.tags.isEmpty {
            tagsAttr = ""
        } else {
            tagsAttr = #" data-writ-tags="\#(escape(fm.tags.joined(separator: ",")))""#
        }
        out.append("<header class=\"writ-doc-header\"\(tagsAttr)>\n")

        if let title { out.append("  <h1 class=\"writ-doc-title\">\(escape(title))</h1>\n") }

        let metaParts: [String] = [author, date].compactMap { $0 }.map(escape)
        if !metaParts.isEmpty {
            out.append("  <p class=\"writ-doc-meta\">\(metaParts.joined(separator: " · "))</p>\n")
        }
        if let description {
            out.append("  <p class=\"writ-doc-description\">\(escape(description))</p>\n")
        }
        out.append("  <hr/>\n")
        out.append("</header>\n")
        return Rendered(html: out, tags: fm.tags)
    }

    private static func escape(_ s: String) -> String {
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

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
