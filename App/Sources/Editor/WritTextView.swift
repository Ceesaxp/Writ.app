import Cocoa
import WritParser

/// NSTextView subclass that paints a full-width background behind
/// fenced code-block ranges, addressing the limitation that
/// `.backgroundColor` attributes only colour the glyph bounding rect.
///
/// The editor's syntax highlighter pushes the current set of code-block
/// UTF-16 ranges via `codeBlockRanges`. On every `drawBackground(in:)`
/// — which fires before glyph rendering — we walk those ranges, find each
/// one's vertical span using `NSLayoutManager.enumerateLineFragments`,
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
        let start = LatencyProbe.enabled ? CFAbsoluteTimeGetCurrent() : 0
        defer {
            if LatencyProbe.enabled {
                let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
                LatencyProbe.log.info("insertText \(ms, format: .fixed(precision: 2))ms")
            }
        }
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

        // Both the front-matter gate (#26) and the `math: false` gate
        // (#27) need to know about the document's front matter. Looking
        // it up via `FrontMatterExtractor` on every keystroke compounds
        // — combine into a single cached lookup that's reused for both
        // checks and refreshed only when the text storage actually
        // changes.
        if WritTextView.markdownOnlyAutoPairs.contains(pair.open) {
            let fm = cachedFrontMatterInfo()
            let selectionEnd = selection.location + selection.length
            if selection.location < fm.utf16Length && selectionEnd <= fm.utf16Length {
                super.insertText(string, replacementRange: replacementRange)
                return
            }
            if pair.open == "$" && fm.mathDisabled {
                super.insertText(string, replacementRange: replacementRange)
                return
            }
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
    /// Compact summary of the active document's front matter relevant
    /// to the auto-pair gates: where it ends (in UTF-16 code units, so
    /// it can be compared against `NSRange`) and whether `math: false`
    /// is set. Both `0` / `false` when no FM is present.
    private struct FrontMatterInfo {
        let utf16Length: Int
        let mathDisabled: Bool
        static let empty = FrontMatterInfo(utf16Length: 0, mathDisabled: false)
    }

    /// Cached `FrontMatterInfo` — recomputed lazily when the text
    /// storage changes (`textStorageDidEdit` clears the cache via
    /// notification). Stale across edits within a single runloop tick
    /// is fine because auto-pair runs on the input event itself and
    /// the cache invalidation happens immediately after the storage
    /// commits.
    private var cachedFrontMatter: FrontMatterInfo?
    private var fmObserverRegistered = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !fmObserverRegistered else { return }
        // Observe any storage's didProcessEditing — we filter on
        // `note.object === textStorage` inside the handler so we
        // ignore unrelated storages. Registering with `object: nil`
        // dodges the chicken-and-egg of needing the storage pointer
        // at observe-registration time.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textStorageDidEdit(_:)),
            name: NSTextStorage.didProcessEditingNotification,
            object: nil
        )
        fmObserverRegistered = true
    }

    deinit {
        if fmObserverRegistered {
            NotificationCenter.default.removeObserver(self, name: NSTextStorage.didProcessEditingNotification, object: nil)
        }
    }

    private func cachedFrontMatterInfo() -> FrontMatterInfo {
        if let cached = cachedFrontMatter { return cached }
        let source = self.string
        let info: FrontMatterInfo
        if let (fm, _) = FrontMatterExtractor.extract(source) {
            let prefix = source.prefix(fm.charCount)
            let utf16Length = (String(prefix) as NSString).length
            let mathDisabled = fm["math"]?.lowercased() == "false"
            info = FrontMatterInfo(utf16Length: utf16Length, mathDisabled: mathDisabled)
        } else {
            info = .empty
        }
        cachedFrontMatter = info
        return info
    }

    /// Invalidate the FM cache on any storage edit. Filters on
    /// `note.object === textStorage` because the observer was
    /// registered with `object: nil` (see `viewDidMoveToWindow`).
    @objc private func textStorageDidEdit(_ note: Notification) {
        guard (note.object as AnyObject?) === textStorage else { return }
        cachedFrontMatter = nil
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard !codeBlockRanges.isEmpty, let layoutManager = layoutManager else { return }

        codeBlockBackgroundColor.setFill()
        let textViewWidth = bounds.width
        let containerOrigin = textContainerOrigin

        for codeRange in codeBlockRanges {
            // UTF-16 character range → glyph range. Under TK1 the two
            // are essentially identical for plain text but the API
            // takes the round-trip explicitly.
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: codeRange,
                actualCharacterRange: nil
            )
            // Each line fragment inside the code block contributes one
            // horizontal stripe across the full editor width.
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, _, _, _, _ in
                let viewRect = NSRect(
                    x: 0,
                    y: lineRect.minY + containerOrigin.y,
                    width: textViewWidth,
                    height: lineRect.height
                )
                if viewRect.intersects(rect) {
                    viewRect.fill()
                }
            }
        }
    }
}
