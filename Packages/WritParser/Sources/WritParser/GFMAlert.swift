import Foundation
import Markdown

/// GitHub-Flavored Markdown alerts (the `> [!NOTE]` / `> [!TIP]` /
/// `> [!IMPORTANT]` / `> [!WARNING]` / `> [!CAUTION]` blocks).
///
/// Render shape:
///
///     > [!NOTE]
///     > Useful information.
///
/// becomes a callout with a type-coloured title row (icon + label) and
/// the remaining blockquote body rendered as normal markdown.
public struct GFMAlert {
    public enum Kind: String, Sendable, CaseIterable {
        case note, tip, important, warning, caution

        public var label: String {
            switch self {
            case .note:      return "Note"
            case .tip:       return "Tip"
            case .important: return "Important"
            case .warning:   return "Warning"
            case .caution:   return "Caution"
            }
        }

        /// Inline SVG icon. Material-style monoline glyphs at 16×16 so
        /// the title row reads at any preview font size without
        /// dragging in an icon-font dependency.
        public var iconSVG: String {
            // The currentColor stroke + role="img" pattern lets the
            // CSS colour each alert's icon via the surrounding
            // `.writ-alert-<kind>` rule.
            switch self {
            case .note:
                return svg("<circle cx='8' cy='8' r='7'/><line x1='8' y1='5' x2='8' y2='5.01'/><line x1='8' y1='8' x2='8' y2='12'/>")
            case .tip:
                return svg("<path d='M8 1.5 a5 5 0 0 1 3 9 v2 h-6 v-2 a5 5 0 0 1 3-9z'/><line x1='6' y1='14' x2='10' y2='14'/>")
            case .important:
                return svg("<path d='M2 3 h12 v8 h-5 l-3 3 v-3 h-4 z'/><line x1='8' y1='5.5' x2='8' y2='8.5'/><circle cx='8' cy='10.5' r='0.6' fill='currentColor'/>")
            case .warning:
                return svg("<path d='M8 1.5 L15 14 H1 z'/><line x1='8' y1='6' x2='8' y2='9.5'/><circle cx='8' cy='11.5' r='0.6' fill='currentColor'/>")
            case .caution:
                return svg("<circle cx='8' cy='8' r='6.5'/><line x1='4' y1='4' x2='12' y2='12'/>")
            }
        }

        private func svg(_ inner: String) -> String {
            #"<svg class="writ-alert-icon" role="img" aria-hidden="true" viewBox="0 0 16 16" width="16" height="16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">"# + inner + "</svg>"
        }
    }

    public let kind: Kind
    public let bodyChildren: [Markup]

    /// Inspects a `BlockQuote` and returns a `GFMAlert` if it opens with
    /// a `[!TYPE]` marker as the first inline of the first paragraph.
    /// Subsequent inlines (after the soft break) become the first body
    /// paragraph; further block children of the quote follow.
    public static func detect(in quote: BlockQuote) -> GFMAlert? {
        let children = Array(quote.children)
        guard let firstParagraph = children.first as? Paragraph else { return nil }
        let inlines = Array(firstParagraph.children)
        guard let firstText = inlines.first as? Text else { return nil }

        let trimmed = firstText.string.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[!"), trimmed.hasSuffix("]") else { return nil }
        let typeRaw = String(trimmed.dropFirst(2).dropLast()).lowercased()
        guard let kind = Kind(rawValue: typeRaw) else { return nil }

        // The next inline must be a line break (Soft or hard) — the
        // marker has to be on its own line, otherwise it's just text
        // that happens to look like one.
        let rest = Array(inlines.dropFirst())
        guard let firstAfter = rest.first,
              firstAfter is SoftBreak || firstAfter is LineBreak else {
            return nil
        }
        let bodyInlines = Array(rest.dropFirst())

        // Rebuild the body. The trailing inlines on the marker
        // paragraph (lines 2..end of the original first paragraph)
        // become a fresh paragraph; the rest of the blockquote's
        // children come after unchanged.
        var body: [Markup] = []
        if !bodyInlines.isEmpty {
            // Serialize the trailing inlines back to markdown and
            // reparse — gives us a real Paragraph node the emitter
            // can walk, rather than wrestling with raw inline arrays.
            let serialized = bodyInlines.map(serializeInline).joined()
            if !serialized.trimmingCharacters(in: .whitespaces).isEmpty {
                let extra = Document(parsing: serialized)
                body.append(contentsOf: extra.children)
            }
        }
        body.append(contentsOf: children.dropFirst())
        return GFMAlert(kind: kind, bodyChildren: body)
    }

    private static func serializeInline(_ markup: Markup) -> String {
        switch markup {
        case let t as Text: return t.string
        case is SoftBreak: return "\n"
        case is LineBreak: return "\n"
        case let code as InlineCode: return "`\(code.code)`"
        case let em as Emphasis: return "*" + em.children.map(serializeInline).joined() + "*"
        case let strong as Strong: return "**" + strong.children.map(serializeInline).joined() + "**"
        case let strike as Strikethrough: return "~~" + strike.children.map(serializeInline).joined() + "~~"
        case let link as Link:
            let inner = link.children.map(serializeInline).joined()
            return "[\(inner)](\(link.destination ?? ""))"
        default:
            return markup.children.map(serializeInline).joined()
        }
    }
}
