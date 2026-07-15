import Cocoa
import WritParser

/// Editor syntax highlighter driven by `swift-markdown`'s AST (via
/// `SyntaxSpanExtractor`) plus a handful of cheap line-level regex scans for
/// constructs that aren't represented in the AST.
///
/// Compared to the original regex-only implementation:
/// - Honors block boundaries (a `*` inside a fenced code block stays plain).
/// - Recognizes block quotes, task markers, table separators, math, links.
/// - Apply path is unchanged: one `beginEditing` / `endEditing` pass over
///   the text storage that sets base attributes then overlays span attrs.
///
/// Per-edit cost: O(document size) for the AST walk + line scans. The
/// editor debounces this with an 80 ms throttle and skips highlighting on
/// documents larger than 500 KB (handled in `EditorViewController`).
final class MarkdownSyntaxHighlighter {
    private let extractor = SyntaxSpanExtractor()

    struct Style {
        let heading: NSColor
        let emphasis: NSColor
        let strong: NSColor
        let strike: NSColor
        let codeBackground: NSColor
        let codeForeground: NSColor
        let link: NSColor
        let math: NSColor
        let blockquote: NSColor
        let listMarker: NSColor
        let html: NSColor
        let thematicBreak: NSColor
        let frontMatter: NSColor
    }

    private static let darkStyle = Style(
        heading: NSColor(calibratedRed: 0.65, green: 0.78, blue: 1.0, alpha: 1),
        emphasis: NSColor(calibratedRed: 0.85, green: 0.85, blue: 0.85, alpha: 1),
        strong: NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.95, alpha: 1),
        strike: NSColor(calibratedRed: 0.70, green: 0.70, blue: 0.70, alpha: 1),
        codeBackground: NSColor(calibratedWhite: 0.16, alpha: 1),
        codeForeground: NSColor(calibratedRed: 0.95, green: 0.78, blue: 0.55, alpha: 1),
        link: NSColor(calibratedRed: 0.55, green: 0.75, blue: 1.0, alpha: 1),
        math: NSColor(calibratedRed: 0.7, green: 0.95, blue: 0.8, alpha: 1),
        blockquote: NSColor(calibratedRed: 0.65, green: 0.65, blue: 0.7, alpha: 1),
        listMarker: NSColor(calibratedRed: 0.7, green: 0.7, blue: 0.95, alpha: 1),
        html: NSColor(calibratedRed: 0.55, green: 0.85, blue: 0.95, alpha: 1),
        thematicBreak: NSColor(calibratedWhite: 0.55, alpha: 1),
        frontMatter: NSColor(calibratedWhite: 0.50, alpha: 1)
    )

    private static let lightStyle = Style(
        heading: NSColor(calibratedRed: 0.15, green: 0.35, blue: 0.75, alpha: 1),
        emphasis: NSColor(calibratedRed: 0.25, green: 0.25, blue: 0.30, alpha: 1),
        strong: NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.15, alpha: 1),
        strike: NSColor(calibratedRed: 0.55, green: 0.55, blue: 0.60, alpha: 1),
        codeBackground: NSColor(calibratedWhite: 0.94, alpha: 1),
        codeForeground: NSColor(calibratedRed: 0.55, green: 0.30, blue: 0.10, alpha: 1),
        link: NSColor(calibratedRed: 0.05, green: 0.40, blue: 0.78, alpha: 1),
        math: NSColor(calibratedRed: 0.15, green: 0.55, blue: 0.25, alpha: 1),
        blockquote: NSColor(calibratedRed: 0.45, green: 0.45, blue: 0.52, alpha: 1),
        listMarker: NSColor(calibratedRed: 0.40, green: 0.30, blue: 0.65, alpha: 1),
        html: NSColor(calibratedRed: 0.05, green: 0.45, blue: 0.60, alpha: 1),
        thematicBreak: NSColor(calibratedWhite: 0.55, alpha: 1),
        frontMatter: NSColor(calibratedWhite: 0.60, alpha: 1)
    )

    @MainActor
    private static var current: Style {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? darkStyle : lightStyle
    }

    /// Side-channel return: the ranges of code-block spans found in the
    /// most recent highlight pass. The editor hands these to its
    /// `CodeBlockBackgroundDelegate` so the full-width background drawing
    /// can target the right fragments.
    private(set) var codeBlockRanges: [NSRange] = []

    /// All code ranges from the most recent highlight pass — inline
    /// code (`` `…` ``) plus block code (` ``` `). Distinct from
    /// `codeBlockRanges` because the spell-check filter (issue #1)
    /// wants to skip checking inside any code, not just blocks.
    private(set) var allCodeRanges: [NSRange] = []

    @MainActor
    func applyHighlight(
        to storage: NSTextStorage?,
        source: String,
        baseAttributes: [NSAttributedString.Key: Any],
        editedRange: NSRange? = nil
    ) async {
        guard let storage else { return }
        let style = Self.current
        let allSpans = extractor.extract(from: source)
        let fullRange = NSRange(location: 0, length: (source as NSString).length)
        // Honor `math: false` in front matter (#27) — when the
        // document has opted out of math, the source editor should
        // also stop tinting `$…$` / `$$…$$` ranges as math. The
        // renderer already respects the flag via `MarkdownParser`;
        // this just lines the editor up with the same view.
        let mathDisabled = FrontMatterExtractor.extract(source)
            .flatMap { $0.0["math"]?.lowercased() == "false" } ?? false
        let newSpans: [SyntaxSpan]
        if mathDisabled {
            newSpans = allSpans.filter { span in
                switch span.kind {
                case .mathInline, .mathBlock, .mathFence:
                    return false
                default:
                    return true
                }
            }
        } else {
            newSpans = allSpans
        }
        codeBlockRanges = newSpans.compactMap { $0.kind == .codeBlock ? $0.range : nil }
        allCodeRanges = newSpans.compactMap { span in
            switch span.kind {
            case .inlineCode, .codeBlock, .codeBlockFence, .codeBlockLang:
                return span.range
            default:
                return nil
            }
        }

        // Decide the storage range that needs re-styling. For the first
        // highlight (or any full refresh) we touch everything; for an
        // edit-driven pass we restrict to the minimal range that covers:
        //   • the paragraph(s) containing the edit
        //   • any span from the new parse that crosses that scope
        //   • any range with stale highlighter styling that touches
        //     the scope (read directly from storage so we don't have to
        //     translate cached span positions across the edit's
        //     coordinate shift — NSTextStorage auto-translates attribute
        //     ranges for us)
        let scope: NSRange
        if let edited = editedRange {
            scope = computeIncrementalScope(
                editedRange: edited,
                fullRange: fullRange,
                source: source,
                newSpans: newSpans,
                storage: storage,
                baseAttributes: baseAttributes
            )
        } else {
            scope = fullRange
        }

        storage.beginEditing()
        // Reset the styling attributes the highlighter manages — within
        // the scope only.
        storage.removeAttribute(.foregroundColor, range: scope)
        storage.removeAttribute(.backgroundColor, range: scope)
        storage.removeAttribute(.strikethroughStyle, range: scope)
        storage.removeAttribute(.underlineStyle, range: scope)
        if let baseFont = baseAttributes[.font] {
            storage.addAttribute(.font, value: baseFont, range: scope)
        }
        if let baseColor = baseAttributes[.foregroundColor] {
            storage.addAttribute(.foregroundColor, value: baseColor, range: scope)
        }
        // Reassert the locked-line-height paragraph style too. It lives
        // on every range from setSource, but attributed text can still
        // sneak in around the plain-text paste guard (e.g. rich-text
        // drag-and-drop) carrying hanging indents and foreign line
        // heights; re-adding the base style makes each highlight pass
        // self-healing for paragraph attributes the same way it already
        // is for fonts and colors.
        if let baseParagraphStyle = baseAttributes[.paragraphStyle] {
            storage.addAttribute(.paragraphStyle, value: baseParagraphStyle, range: scope)
        }

        let baseFont = (baseAttributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 13)
        let boldFontDescriptor = baseFont.fontDescriptor.withSymbolicTraits(.bold)
        let italicFontDescriptor = baseFont.fontDescriptor.withSymbolicTraits(.italic)
        let boldFont = NSFont(descriptor: boldFontDescriptor, size: baseFont.pointSize) ?? baseFont
        let italicFont = NSFont(descriptor: italicFontDescriptor, size: baseFont.pointSize) ?? baseFont

        for span in newSpans {
            let range = NSIntersectionRange(span.range, scope)
            guard range.length > 0 else { continue }
            switch span.kind {
            case .heading, .headingMarker:
                storage.addAttribute(.foregroundColor, value: style.heading, range: range)
                storage.addAttribute(.font, value: boldFont, range: range)
            case .strong:
                storage.addAttribute(.foregroundColor, value: style.strong, range: range)
                storage.addAttribute(.font, value: boldFont, range: range)
            case .emphasis:
                storage.addAttribute(.foregroundColor, value: style.emphasis, range: range)
                storage.addAttribute(.font, value: italicFont, range: range)
            case .strikethrough:
                storage.addAttribute(.foregroundColor, value: style.strike, range: range)
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case .inlineCode, .codeBlock, .codeBlockFence, .codeBlockLang:
                storage.addAttribute(.foregroundColor, value: style.codeForeground, range: range)
                storage.addAttribute(.backgroundColor, value: style.codeBackground, range: range)
            case .mathInline, .mathBlock, .mathFence:
                storage.addAttribute(.foregroundColor, value: style.math, range: range)
            case .link, .linkURL, .image:
                storage.addAttribute(.foregroundColor, value: style.link, range: range)
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case .blockquote:
                storage.addAttribute(.foregroundColor, value: style.blockquote, range: range)
            case .listMarker, .taskMarker:
                storage.addAttribute(.foregroundColor, value: style.listMarker, range: range)
            case .htmlBlock:
                storage.addAttribute(.foregroundColor, value: style.html, range: range)
            case .thematicBreak, .tableSeparator:
                storage.addAttribute(.foregroundColor, value: style.thematicBreak, range: range)
            case .frontMatter:
                storage.addAttribute(.foregroundColor, value: style.frontMatter, range: range)
                storage.addAttribute(.font, value: italicFont, range: range)
            }
        }
        storage.endEditing()
    }

    /// Expand the user's edited range to the minimal scope that covers
    /// all styling that needs to change. Iterates between two
    /// expansion sources:
    ///   1. Spans from the new parse that cross the current scope —
    ///      ensures we apply styling for any new construct that begins
    ///      outside the edit but extends into it (or vice versa).
    ///   2. Ranges with current styled attributes in the storage that
    ///      touch the current scope — catches stale highlighter
    ///      attributes that need resetting (e.g. you deleted the
    ///      closing `**` of a strong span, the styled prefix above
    ///      still has bold font that needs to come off). Reading from
    ///      storage avoids the coordinate-translation problem of
    ///      cached pre-edit spans: NSTextStorage auto-translates
    ///      attribute range positions when text shifts.
    private func computeIncrementalScope(
        editedRange: NSRange,
        fullRange: NSRange,
        source: String,
        newSpans: [SyntaxSpan],
        storage: NSTextStorage,
        baseAttributes: [NSAttributedString.Key: Any]
    ) -> NSRange {
        let ns = source as NSString
        var scope = ns.lineRange(for: NSIntersectionRange(editedRange, fullRange))

        for _ in 0..<8 {
            let oldScope = scope
            // Absorb new-parse spans that cross the scope.
            let scopeStart = scope.location
            let scopeEnd = scope.location + scope.length
            var widened = scope
            for span in newSpans {
                let spanStart = span.range.location
                let spanEnd = spanStart + span.range.length
                guard spanEnd > scopeStart, spanStart < scopeEnd else { continue }
                widened = NSUnionRange(widened, span.range)
            }
            // Absorb existing-storage styled runs that touch the scope.
            widened = expandScopeViaStorage(
                scope: widened,
                storage: storage,
                baseAttributes: baseAttributes,
                fullRange: fullRange
            )
            scope = ns.lineRange(for: NSIntersectionRange(widened, fullRange))
            if scope == oldScope { break }
        }
        return NSIntersectionRange(scope, fullRange)
    }

    /// Walk the storage's attribute runs; absorb any run whose value
    /// differs from base (i.e. was applied by the highlighter on a
    /// previous pass) and that touches the current scope. Robust to
    /// edit-induced coordinate shifts because we read the storage
    /// directly.
    private func expandScopeViaStorage(
        scope: NSRange,
        storage: NSTextStorage,
        baseAttributes: [NSAttributedString.Key: Any],
        fullRange: NSRange
    ) -> NSRange {
        var union = scope
        let baseFont = baseAttributes[.font] as? NSFont
        let baseColor = baseAttributes[.foregroundColor] as? NSColor

        storage.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
            var isStyled = false
            if let font = attrs[.font] as? NSFont, font != baseFont { isStyled = true }
            if let color = attrs[.foregroundColor] as? NSColor, color != baseColor { isStyled = true }
            if attrs[.backgroundColor] != nil { isStyled = true }
            if attrs[.strikethroughStyle] != nil { isStyled = true }
            if attrs[.underlineStyle] != nil { isStyled = true }
            guard isStyled else { return }
            let scopeEnd = union.location + union.length
            let rangeEnd = range.location + range.length
            // Touches or overlaps the scope?
            if rangeEnd >= union.location && range.location <= scopeEnd {
                union = NSUnionRange(union, range)
            }
        }
        return union
    }
}
