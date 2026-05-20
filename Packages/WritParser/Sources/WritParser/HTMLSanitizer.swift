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
        "meta", "link", "base",
        // SVG-specific vectors. `foreignObject` can host arbitrary
        // HTML+JS inside an otherwise-safe-looking <svg>. Handler
        // elements (set/animate/animateTransform) can drive script
        // execution via SMIL when given an `attributeName="onload"`
        // and `to="..."` pair — strip those entirely. `use` and
        // `image` can pull in remote/javascript resources; we drop
        // them to be safe rather than trying to argue with hrefs.
        "foreignobject", "animate", "animatetransform", "animatemotion",
        "set", "use", "image", "feimage"
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
        // Strip javascript: / vbscript: URLs from href / src / xlink:href.
        // The xlink form is SVG's legacy resource pointer; modern SVG
        // uses plain `href`, but both ship in the wild.
        result = result.replacingOccurrences(
            of: #"(?i)(xlink:href|href|src)\s*=\s*"\s*(javascript|vbscript):[^"]*""#,
            with: "$1=\"#\"",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?i)(xlink:href|href|src)\s*=\s*'\s*(javascript|vbscript):[^']*'"#,
            with: "$1='#'",
            options: .regularExpression
        )
        // Strip `data:` from href / xlink:href specifically — it can
        // carry text/html with embedded JS in an <a href> context.
        // Note: data: stays allowed in `<img src=>` and similar
        // resource-only sinks since those don't execute markup.
        result = result.replacingOccurrences(
            of: #"(?i)(xlink:href|href)\s*=\s*"\s*data:[^"]*""#,
            with: "$1=\"#\"",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?i)(xlink:href|href)\s*=\s*'\s*data:[^']*'"#,
            with: "$1='#'",
            options: .regularExpression
        )
        return result
    }
}
