import Foundation

/// Defense-in-depth sanitiser for raw HTML embedded in Markdown source.
///
/// swift-markdown emits `HTMLBlock` and `InlineHTML` nodes verbatim; if a
/// user pasted a `<script>` into their markdown it would currently land in
/// the preview pane and execute. The preview also routes plenty of trusted
/// HTML through (everything our own HTMLEmitter emits), so we don't apply
/// the sanitiser to *that*. We only strip things that come from raw HTML
/// inside the source document.
///
/// Strategy:
///   - Block list of dangerous tags (`script`, `style`, `iframe`, etc.)
///     entire element (open + content + close) is removed.
///   - Block list of dangerous attributes (`on*` event handlers,
///     `javascript:` URLs) inside any retained tag.
///
/// Not an HTML parser — this is a focused regex sweep meant as a final
/// guard, not a complete defence. M4 should replace with a proper parser.
public enum HTMLSanitizer {
    private static let dangerousTags = [
        "script", "style", "iframe", "object", "embed", "applet",
        "form", "input", "button", "textarea", "select", "option",
        "meta", "link", "base"
    ]

    public static func sanitize(_ html: String) -> String {
        var result = html
        for tag in dangerousTags {
            // Remove <tag …>…</tag> as a whole, plus self-closing variants.
            let paired = #"(?is)<\#(tag)\b[^>]*>.*?</\#(tag)>"#
            result = result.replacingOccurrences(of: paired, with: "", options: .regularExpression)
            let selfClosing = #"(?is)<\#(tag)\b[^>]*/?>"#
            result = result.replacingOccurrences(of: selfClosing, with: "", options: .regularExpression)
        }
        // Strip on* event-handler attributes inside any remaining tag.
        result = result.replacingOccurrences(
            of: #"(?i)\s+on[a-z]+\s*=\s*"[^"]*""#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?i)\s+on[a-z]+\s*=\s*'[^']*'"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?i)\s+on[a-z]+\s*=\s*[^\s>]+"#,
            with: "",
            options: .regularExpression
        )
        // Strip javascript: URLs from href / src.
        result = result.replacingOccurrences(
            of: #"(?i)(href|src)\s*=\s*"\s*javascript:[^"]*""#,
            with: "$1=\"#\"",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?i)(href|src)\s*=\s*'\s*javascript:[^']*'"#,
            with: "$1='#'",
            options: .regularExpression
        )
        return result
    }
}
