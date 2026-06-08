import Cocoa
import WritParser

/// NSTextView subclass that paints a full-width background behind
/// fenced code-block ranges, addressing the limitation that
/// `.backgroundColor` attributes only colour the glyph bounding rect.
///
/// The editor's syntax highlighter pushes the current set of code-block
/// UTF-16 ranges via `codeBlockRanges`. On every `drawBackground(in:)`
/// — which fires before glyph rendering — we walk those ranges, find each
/// one's vertical span using `NSTextLayoutManager.enumerateTextSegments`,
/// and fill across the textView's full width.
@MainActor
final class WritTextView: NSTextView {
    /// UTF-16 ranges of code blocks. Sets the source of truth for the
    /// background painting; assigning triggers a redraw.
    var codeBlockRanges: [NSRange] = [] {
        didSet { needsDisplay = true }
    }

    /// Background colour for code-block lines. Defaults to a subtle tint.
    var codeBlockBackgroundColor: NSColor = NSColor(calibratedWhite: 0.93, alpha: 1) {
        didSet { needsDisplay = true }
    }

    // TextKit 2's NSTextLayoutManager does not honour the legacy
    // `widthTracksTextView` flag the way TextKit 1 did — the text
    // container holds onto whatever width it was first sized with,
    // so lines wrap at that fixed width regardless of the actual
    // visible area. Bridge it manually by resizing the container
    // every time the text view's frame width changes.
    //
    // NOTE on padding: `NSTextContainer.size.width` is the layout width
    // INCLUDING the per-side `lineFragmentPadding`. The glyph layout
    // area inside is automatically reduced by the padding. So the
    // container width should equal the view width, not the view width
    // minus the padding.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let container = textContainer else { return }
        if container.size.width != newSize.width {
            container.size = NSSize(width: newSize.width, height: container.size.height)
            // TextKit 2's layout manager doesn't invalidate automatically
            // on container resize; force a re-layout so wrap takes effect.
            textLayoutManager?.invalidateLayout(for: textLayoutManager!.documentRange)
        }
    }

    /// Characters whose typing triggers auto-pair behavior — wrap any
    /// selected text with the pair, or insert open+close around the
    /// caret. Implemented here (in `insertText`) instead of in the
    /// `NSTextViewDelegate.textView(_:shouldChangeTextIn:)` callback to
    /// avoid nesting `shouldChangeText` calls inside the delegate's
    /// dispatch — that nesting corrupted NSTextView's undo bookkeeping
    /// so Cmd-Z couldn't replay wrap operations in reverse.
    private static let autoPairs: [(open: String, close: String)] = [
        ("(", ")"), ("[", "]"), ("{", "}"),
        ("\"", "\""), ("'", "'"),
        ("*", "*"), ("_", "_"), ("`", "`"), ("$", "$")
    ]

    /// Markdown-formatting characters whose auto-pair behavior should
    /// be suppressed inside a front-matter block. `*` and `_` carry
    /// meaning in YAML (anchors, aliases) and TOML values; `` ` ``
    /// and `$` are markdown-only constructs that just confuse front
    /// matter. Brackets and quotes stay paired — they're legitimate
    /// YAML/TOML syntax for arrays, inline objects, and quoted values.
    private static let markdownOnlyAutoPairs: Set<String> = ["*", "_", "`", "$"]

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let typed: String
        if let s = string as? String {
            typed = s
        } else if let s = string as? NSAttributedString {
            typed = s.string
        } else {
            typed = ""
        }
        // Only single-character inserts trigger auto-pair logic.
        guard typed.count == 1, let pair = WritTextView.autoPairs.first(where: { $0.open == typed }) else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        let selection = selectedRange()
        let docNS = self.string as NSString

        // Suppress markdown-only auto-pairs when the cursor sits inside
        // the front-matter block. `*foo*` etc. is not emphasis there.
        if WritTextView.markdownOnlyAutoPairs.contains(pair.open),
           selectionIsInFrontMatter(selection: selection) {
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        // Selection present: wrap it with the pair as a single edit
        // (one `super.insertText` call → one shouldChangeText cycle
        // → one undo group). The user's Cmd-Z then replays the wrap
        // in reverse.
        if selection.length > 0 {
            let selected = docNS.substring(with: selection)
            let combined = pair.open + selected + pair.close
            super.insertText(combined, replacementRange: selection)
            let inside = NSRange(
                location: selection.location + (pair.open as NSString).length,
                length: (selected as NSString).length
            )
            setSelectedRange(inside)
            return
        }

        // No selection: a couple of context-sensitive skips first,
        // then insert open+close with the caret parked between them.
        if selection.location < docNS.length {
            let next = docNS.substring(with: NSRange(location: selection.location, length: 1))
            if next == pair.close {
                // Already a closer next to the caret — don't auto-pair;
                // let the typed character drop in normally so the user
                // can build up "**" → "***" if they really want.
                super.insertText(string, replacementRange: replacementRange)
                return
            }
        }
        if pair.open == "'", selection.location > 0 {
            let prev = docNS.substring(with: NSRange(location: selection.location - 1, length: 1))
            if let scalar = prev.unicodeScalars.first, scalar.properties.isAlphabetic {
                // Inside a word — treat as an apostrophe (contraction),
                // not as a quote pair.
                super.insertText(string, replacementRange: replacementRange)
                return
            }
        }
        // `replacementRange.location` can be `NSNotFound` (== `Int.max`)
        // when the caller means "use the current selection" — arithmetic
        // on it overflows. The user's selection.location is the actual
        // insertion point.
        let combined = pair.open + pair.close
        super.insertText(combined, replacementRange: replacementRange)
        let between = NSRange(
            location: selection.location + (pair.open as NSString).length,
            length: 0
        )
        setSelectedRange(between)
    }

    /// True when the (collapsed or extended) selection sits entirely
    /// inside the YAML/TOML front-matter block at the top of the
    /// document. Uses `FrontMatterExtractor` so the editor and the
    /// renderer agree byte-for-byte on what counts as front matter.
    /// `FrontMatter.charCount` is in `Character` units; convert via
    /// the source's UTF-16 prefix to compare against `selectedRange()`
    /// which is in UTF-16 code units.
    private func selectionIsInFrontMatter(selection: NSRange) -> Bool {
        let source = self.string
        guard let (fm, _) = FrontMatterExtractor.extract(source) else { return false }
        let prefix = source.prefix(fm.charCount)
        let fmUTF16Length = (String(prefix) as NSString).length
        let selectionEnd = selection.location + selection.length
        return selection.location < fmUTF16Length && selectionEnd <= fmUTF16Length
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard !codeBlockRanges.isEmpty,
              let textLayoutManager = textLayoutManager else { return }

        codeBlockBackgroundColor.setFill()
        let textViewWidth = bounds.width
        let containerOrigin = textContainerOrigin

        for range in codeBlockRanges {
            // Resolve UTF-16 NSRange → NSTextRange in the layout manager.
            let docStart = textLayoutManager.documentRange.location
            guard let start = textLayoutManager.location(docStart, offsetBy: range.location),
                  let end = textLayoutManager.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end) else { continue }

            // Enumerate visual segments inside the range. Each segment
            // gives us a rect in text-container coordinates. We translate
            // to textView coordinates and stretch horizontally to the
            // full editor width.
            textLayoutManager.enumerateTextSegments(in: textRange, type: .standard, options: [.rangeNotRequired]) { _, segmentFrame, _, _ in
                let viewRect = NSRect(
                    x: 0,
                    y: segmentFrame.minY + containerOrigin.y,
                    width: textViewWidth,
                    height: segmentFrame.height
                )
                if viewRect.intersects(rect) {
                    viewRect.fill()
                }
                return true
            }
        }
    }
}
