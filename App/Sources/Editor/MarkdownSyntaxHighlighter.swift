import Cocoa

/// Lightweight regex-based Markdown highlighter for the editor surface.
///
/// M0 baseline. M3 will replace with an incremental, range-aware highlighter
/// driven by `swift-markdown` tokens. For now this paints attributes over an
/// already-loaded string and is rate-limited by the editor so it does not run
/// on every keystroke for large documents.
final class MarkdownSyntaxHighlighter {
    struct Style {
        let heading: NSColor
        let emphasis: NSColor
        let codeBackground: NSColor
        let codeForeground: NSColor
        let link: NSColor
        let math: NSColor
        let blockquote: NSColor
        let listMarker: NSColor
    }

    private static let darkStyle = Style(
        heading: NSColor(calibratedRed: 0.65, green: 0.78, blue: 1.0, alpha: 1),
        emphasis: NSColor(calibratedRed: 0.85, green: 0.85, blue: 0.85, alpha: 1),
        codeBackground: NSColor(calibratedWhite: 0.16, alpha: 1),
        codeForeground: NSColor(calibratedRed: 0.95, green: 0.78, blue: 0.55, alpha: 1),
        link: NSColor(calibratedRed: 0.55, green: 0.75, blue: 1.0, alpha: 1),
        math: NSColor(calibratedRed: 0.7, green: 0.95, blue: 0.8, alpha: 1),
        blockquote: NSColor(calibratedRed: 0.65, green: 0.65, blue: 0.7, alpha: 1),
        listMarker: NSColor(calibratedRed: 0.7, green: 0.7, blue: 0.95, alpha: 1)
    )

    private static let lightStyle = Style(
        heading: NSColor(calibratedRed: 0.15, green: 0.35, blue: 0.75, alpha: 1),
        emphasis: NSColor(calibratedRed: 0.25, green: 0.25, blue: 0.30, alpha: 1),
        codeBackground: NSColor(calibratedWhite: 0.94, alpha: 1),
        codeForeground: NSColor(calibratedRed: 0.55, green: 0.30, blue: 0.10, alpha: 1),
        link: NSColor(calibratedRed: 0.05, green: 0.40, blue: 0.78, alpha: 1),
        math: NSColor(calibratedRed: 0.15, green: 0.55, blue: 0.25, alpha: 1),
        blockquote: NSColor(calibratedRed: 0.45, green: 0.45, blue: 0.52, alpha: 1),
        listMarker: NSColor(calibratedRed: 0.40, green: 0.30, blue: 0.65, alpha: 1)
    )

    private static var current: Style {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil ? darkStyle : lightStyle
    }

    private static let headingRegex = try! NSRegularExpression(pattern: "^(#{1,6})\\s+(.+)$", options: [.anchorsMatchLines])
    private static let strongRegex = try! NSRegularExpression(pattern: "(\\*\\*|__)(.+?)\\1")
    private static let emRegex = try! NSRegularExpression(pattern: "(?<!\\*)\\*([^*\\n]+)\\*(?!\\*)")
    private static let inlineCodeRegex = try! NSRegularExpression(pattern: "`[^`\\n]+`")
    private static let fencedCodeRegex = try! NSRegularExpression(pattern: "```[\\s\\S]*?```", options: [])
    private static let linkRegex = try! NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\(([^\\)]+)\\)")
    private static let mathInlineRegex = try! NSRegularExpression(pattern: "(?<!\\\\)\\$[^\\$\\n]+\\$")
    private static let mathBlockRegex = try! NSRegularExpression(pattern: "\\$\\$[\\s\\S]*?\\$\\$")
    private static let blockquoteRegex = try! NSRegularExpression(pattern: "^>\\s.*$", options: [.anchorsMatchLines])
    private static let listRegex = try! NSRegularExpression(pattern: "^\\s*([-*+]|\\d+\\.)\\s", options: [.anchorsMatchLines])

    @MainActor
    func applyHighlight(to storage: NSTextStorage?, source: String, baseAttributes: [NSAttributedString.Key: Any]) async {
        guard let storage = storage else { return }
        let nsSource = source as NSString
        let range = NSRange(location: 0, length: nsSource.length)
        let style = Self.current

        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: range)

        Self.headingRegex.enumerateMatches(in: source, options: [], range: range) { match, _, _ in
            guard let m = match else { return }
            storage.addAttribute(.foregroundColor, value: style.heading, range: m.range)
            if let headingFont = NSFont(descriptor: (baseAttributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 13)).fontDescriptor.withSymbolicTraits(.bold), size: 13) {
                storage.addAttribute(.font, value: headingFont, range: m.range)
            }
        }
        Self.fencedCodeRegex.enumerateMatches(in: source, options: [], range: range) { match, _, _ in
            guard let m = match else { return }
            storage.addAttribute(.foregroundColor, value: style.codeForeground, range: m.range)
            storage.addAttribute(.backgroundColor, value: style.codeBackground, range: m.range)
        }
        Self.inlineCodeRegex.enumerateMatches(in: source, options: [], range: range) { match, _, _ in
            guard let m = match else { return }
            storage.addAttribute(.foregroundColor, value: style.codeForeground, range: m.range)
            storage.addAttribute(.backgroundColor, value: style.codeBackground, range: m.range)
        }
        Self.strongRegex.enumerateMatches(in: source, options: [], range: range) { match, _, _ in
            guard let m = match else { return }
            storage.addAttribute(.foregroundColor, value: style.emphasis, range: m.range)
        }
        Self.emRegex.enumerateMatches(in: source, options: [], range: range) { match, _, _ in
            guard let m = match else { return }
            storage.addAttribute(.foregroundColor, value: style.emphasis, range: m.range)
        }
        Self.linkRegex.enumerateMatches(in: source, options: [], range: range) { match, _, _ in
            guard let m = match else { return }
            storage.addAttribute(.foregroundColor, value: style.link, range: m.range)
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: m.range)
        }
        Self.mathBlockRegex.enumerateMatches(in: source, options: [], range: range) { match, _, _ in
            guard let m = match else { return }
            storage.addAttribute(.foregroundColor, value: style.math, range: m.range)
        }
        Self.mathInlineRegex.enumerateMatches(in: source, options: [], range: range) { match, _, _ in
            guard let m = match else { return }
            storage.addAttribute(.foregroundColor, value: style.math, range: m.range)
        }
        Self.blockquoteRegex.enumerateMatches(in: source, options: [], range: range) { match, _, _ in
            guard let m = match else { return }
            storage.addAttribute(.foregroundColor, value: style.blockquote, range: m.range)
        }
        Self.listRegex.enumerateMatches(in: source, options: [], range: range) { match, _, _ in
            guard let m = match else { return }
            storage.addAttribute(.foregroundColor, value: style.listMarker, range: m.range)
        }
        storage.endEditing()
    }
}
