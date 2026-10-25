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

    /// Writ documents are plain Markdown — attributed content has no
    /// meaning here. Left to its rich-text default, NSTextView imports
    /// pasted RTF/HTML paragraph styles (browser lists arrive with
    /// hanging-indent head indents, tab stops, and their own line
    /// heights) which the syntax highlighter deliberately never
    /// touches, so they'd persist as phantom indents and per-paragraph
    /// line-height drift.
    ///
    /// A live block takes the paste instead and distributes the clipboard
    /// across its rows — see `pasteIntoBlock(_:block:index:)`.
    override func paste(_ sender: Any?) {
        guard let block = blockSelection, let index = blockLineIndex else {
            pasteAsPlainText(sender)
            return
        }
        guard let clipboard = NSPasteboard.general.string(forType: .string) else {
            // Nothing a rectangle can distribute — an image, say. Collapse to
            // a caret and let the ordinary plain-text path have it.
            dropBlockSelection()
            pasteAsPlainText(sender)
            return
        }
        pasteIntoBlock(clipboard, block: block, index: index)
    }

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
        // A live block claims the keystroke before auto-pair sees it: typing
        // into a rectangle replaces every row's fragment, and pairing the
        // first row's insert while fanning out the rest would be neither.
        if blockSelection != nil {
            // Any newline would insert N line breaks and dissolve the very
            // rows the rectangle is defined over, so it drops to a single
            // caret and then inserts normally (docs/06-BLOCK-SELECTION.md §2).
            // Tested over `Character.isNewline` rather than `"\n"` so a
            // `\r\n` or U+2028 arriving from an input method drops too.
            if typed.contains(where: \.isNewline) {
                dropBlockSelection()
                super.insertText(string, replacementRange: replacementRange)
            } else {
                insertIntoBlock(typed)
            }
            return
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

    /// Invalidate the FM cache on any storage edit, and drop any block
    /// selection whose coordinates the edit just invalidated. Filters on
    /// `note.object === textStorage` because the observer was
    /// registered with `object: nil` (see `viewDidMoveToWindow`).
    @objc private func textStorageDidEdit(_ note: Notification) {
        guard let storage = note.object as? NSTextStorage, storage === textStorage else { return }
        cachedFrontMatter = nil
        dropBlockSelectionIfInvalidated(by: storage)
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

    // MARK: - Block (rectangular) selection: state

    /// The live rectangular selection, or nil for an ordinary caret or range.
    ///
    /// Writ owns this rather than expressing it as `selectedRanges`, because
    /// AppKit cannot hold the shape: measured on this stack,
    /// `[{0,2}, {8,0}, {9,2}]` comes back as `[{0,2}, {9,2}]` and
    /// `[{0,0}, {6,0}, {9,0}]` as `[{0,0}]`. The empty fragments a rectangle
    /// produces — a short row it overhangs, or every row of a zero-width
    /// block — are exactly the ones AppKit discards
    /// (docs/06-BLOCK-SELECTION.md §4). `selectedRanges` is therefore a
    /// rendering channel only; see `refreshBlockSelectionDisplay()`.
    private(set) var blockSelection: BlockSelection?

    /// Line table for the document the block was made in, built once when the
    /// block starts and reused for every edit until it drops.
    ///
    /// Building a `LineIndex` is an O(document) scan. The gesture layer asks
    /// for a fragment set on every `mouseDragged` sample, and this editor
    /// targets 1000+ line documents, so a per-operation rebuild would put a
    /// full-document scan inside a mouse-tracking loop. Cached alongside the
    /// block, rebuilt only after a block edit changed the text, and discarded
    /// with the block so a stale table can never be paired with a document it
    /// does not describe.
    private var blockLineIndex: LineIndex?

    /// True while `applyBlockEdits` is mutating the storage.
    ///
    /// It exempts the view's own edit from **both** choke points, because a
    /// block edit trips both: the storage notification directly, and the
    /// selection override because AppKit re-sets the selection around the
    /// edited range. Deleting either use loses the rectangle the moment the
    /// first edit returns — six tests each way.
    private var isApplyingBlockEdit = false

    /// True while `refreshBlockSelectionDisplay` is assigning `selectedRanges`.
    /// Without it the selection choke point would drop the block it is in the
    /// middle of rendering — and since starting a block renders it, a block
    /// would never survive being made at all (25 tests).
    private var isRefreshingBlockDisplay = false

    // MARK: - Block selection: the gesture layer's API

    /// Start a rectangular selection between two corners. The corners are
    /// stored unnormalised, so the head can keep moving in either direction.
    func beginBlockSelection(anchor: BlockPosition, head: BlockPosition) {
        blockSelection = BlockSelection(anchor: anchor, head: head)
        blockLineIndex = LineIndex(string)
        refreshBlockSelectionDisplay()
    }

    /// Move the live corner, keeping the anchor. No-op when no block is live:
    /// starting one is `beginBlockSelection`'s job, which also needs the line
    /// table built.
    func updateBlockSelection(head: BlockPosition) {
        guard var block = blockSelection else { return }
        block.head = head
        blockSelection = block
        refreshBlockSelectionDisplay()
    }

    /// Drop the block and collapse to a single caret at the head corner —
    /// Esc, Return, and anything else that ends the rectangle deliberately.
    ///
    /// The state is cleared *before* the caret is set, so the
    /// `setSelectedRange` choke point sees no block and the drop cannot
    /// recurse through the selection it is itself installing.
    func dropBlockSelection() {
        guard let block = blockSelection, let index = blockLineIndex else { return }
        let caret = WritTextView.caretOffset(of: block.head, in: index)
        discardBlockSelection()
        setSelectedRange(NSRange(location: caret, length: 0))
    }

    /// Render the block through `selectedRanges`.
    ///
    /// AppKit preserves multiple *non-empty* ranges verbatim, sorts them, and
    /// highlights them for free — worth having, so the non-empty fragments go
    /// straight in. It cannot hold more than one *empty* range, so a
    /// zero-width block (every fragment zero-length) gets a single caret at
    /// the head instead and the gesture layer draws the other rows itself
    /// (§4). A mixed set would have its empty members silently dropped, which
    /// is why only the non-empty fragments are offered.
    func refreshBlockSelectionDisplay() {
        guard let block = blockSelection, let index = blockLineIndex else { return }
        // AppKit invalidates the selection it was handed and nothing else, and
        // the zero-length rows are exactly what it was *not* handed — so the
        // carets `draw(_:)` paints for them would keep the positions they had
        // before the rectangle moved. Asking for the repaint belongs here
        // because every change to the block comes through this method.
        needsDisplay = true
        let nonEmpty = block.fragmentRanges(in: index).filter { $0.length > 0 }
        isRefreshingBlockDisplay = true
        defer { isRefreshingBlockDisplay = false }
        if nonEmpty.isEmpty {
            setSelectedRange(
                NSRange(location: WritTextView.caretOffset(of: block.head, in: index), length: 0),
                affinity: .downstream,
                stillSelecting: false
            )
        } else {
            setSelectedRanges(
                nonEmpty.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false
            )
        }
    }

    // MARK: - Block selection: the carets AppKit will not draw

    /// Width of a block caret. One point, matching the ordinary insertion
    /// point so the drawn rows and the real one read as the same thing.
    private static let blockCaretWidth: CGFloat = 1

    /// Paint a caret on every zero-length row of the block.
    ///
    /// `super` draws the text and highlights the fragments that reached
    /// `selectedRanges` — which is all the *non-empty* ones and no more. A
    /// zero-width block arrives there as one caret at the head corner, and a
    /// ragged block has its short rows silently discarded (§4). Those are the
    /// rows drawn here.
    ///
    /// **Every** zero-length row, including the one AppKit is already showing
    /// a caret on: drawing all N identically is the point. Skipping the one
    /// AppKit has would leave a single row blinking against N-1 solid ones,
    /// which reads as a rendering fault rather than as one rectangle. These
    /// carets do not blink and there is no timer to make them — a repaint
    /// timer on a text view that already redraws on every keystroke is a cost
    /// for a cosmetic gain (§7).
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let block = blockSelection, let index = blockLineIndex else { return }
        let rows = block.fragmentRanges(in: index).filter { $0.length == 0 }
        guard !rows.isEmpty else { return }

        insertionPointColor.setFill()
        for row in rows {
            guard let caret = blockCaretRect(atUTF16Offset: row.location),
                  caret.intersects(dirtyRect) else { continue }
            caret.fill()
        }
    }

    /// The rect a caret at a UTF-16 `offset` occupies, in **view**
    /// coordinates, or nil when the offset has no geometry to stand on.
    ///
    /// Not private and not inlined into `draw(_:)`: a drawing override cannot
    /// be asserted on in the hostless test bundle, and the three branches
    /// below are the whole of what could be wrong here. Measured on the
    /// harness (TK1, 13pt monospace) rather than assumed:
    ///
    /// - **Inside the text.** `location(forGlyphAt:)` already includes the
    ///   container's 5pt `lineFragmentPadding` — glyph 0 of `"alpha…"` reports
    ///   `x == 5.0` — so x is the fragment's `minX` plus the glyph's own x and
    ///   **nothing else**. Adding the padding here as well would push every
    ///   caret 5pt to the right of the text it belongs to. The newline ending
    ///   a line has a glyph of its own (glyph 5: `x == 45.18`, fragment
    ///   `(0, 0, 600, 16)`), which is what puts an end-of-line caret on *its*
    ///   line instead of at column 0 of the next.
    /// - **The last position of a document that ends in a newline, and the
    ///   empty document.** Neither has a glyph to ask about — `""` reports
    ///   `numberOfGlyphs == 0` — and both live in the extra line fragment.
    ///   **The container is the test for one, never the rect**: `"ab\n"` gives
    ///   a non-nil `extraLineFragmentTextContainer` and
    ///   `extraLineFragmentRect == (0, 16, 600, 16)`, while
    ///   `"alpha\nbb\ngamma"` has a nil container and a *degenerate*
    ///   `(0, 34, 0, 0)` rect — believe that rect and the caret is drawn
    ///   zero-height, 2pt below the document. The extra fragment has no glyph
    ///   to take an x from, so the padding is the one place it is added by
    ///   hand (measured 5.0, where AppKit puts its own caret on a blank line).
    /// - **The last position of a document that does not end in a newline.**
    ///   No glyph of its own and no extra fragment, but the glyph immediately
    ///   before it is on the right line, so the caret goes at that glyph's
    ///   trailing edge (measured `45.18` — the end of `"gamma"`). Not a corner
    ///   case worth skipping: a zero-width block parked at the end of the last
    ///   line, and a ragged block overhanging it, both put a row here, and
    ///   without this branch that row is the one with no caret. The glyph
    ///   cannot be a newline — a document ending in one has a non-nil extra
    ///   container and left through the branch above — so its bounding rect
    ///   cannot be the next-line-spanning one a newline glyph reports
    ///   (measured for `"ab\n"`: `(0, 0, 595, 32)`).
    ///
    /// `textContainerOrigin` is applied rather than assumed away. It is
    /// `(0, 0)` in the harness, but the production view lives in a scroll view
    /// and is free to inset its container.
    func blockCaretRect(atUTF16Offset offset: Int) -> NSRect? {
        guard let layoutManager = layoutManager,
              let container = textContainer,
              let storage = textStorage else { return nil }
        guard offset >= 0, offset <= storage.length else { return nil }

        let fragment: NSRect
        let x: CGFloat
        if offset < storage.length {
            let glyph = layoutManager.glyphIndexForCharacter(at: offset)
            fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            x = fragment.minX + layoutManager.location(forGlyphAt: glyph).x
        } else if layoutManager.extraLineFragmentTextContainer != nil {
            fragment = layoutManager.extraLineFragmentRect
            x = fragment.minX + container.lineFragmentPadding
        } else if layoutManager.numberOfGlyphs > 0 {
            let last = layoutManager.numberOfGlyphs - 1
            fragment = layoutManager.lineFragmentRect(forGlyphAt: last, effectiveRange: nil)
            x = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: last, length: 1), in: container
            ).maxX
        } else {
            return nil
        }

        let origin = textContainerOrigin
        return NSRect(
            x: x + origin.x,
            y: fragment.minY + origin.y,
            width: WritTextView.blockCaretWidth,
            height: fragment.height
        )
    }

    // MARK: - Block selection: hit-testing

    /// The rectangle corner a point in **view** coordinates lands on.
    ///
    /// `characterIndexForInsertion(at:)` is the accessor, and the choice is
    /// load-bearing rather than a matter of taste. It takes view coordinates
    /// and applies `textContainerOrigin` itself, so there is no conversion to
    /// get wrong, and — the part that matters — it **clamps a point past
    /// end-of-line to that line's own end**.
    ///
    /// The lower-level
    /// `characterIndex(for:in:fractionOfDistanceBetweenInsertionPoints:)` does
    /// not. Measured on this stack with `"alpha\nbb\ngamma"` and a point at
    /// x = 5000 on **line 0**: it answers `idx = 5, fraction = 1.0`, so the
    /// conventional `fraction >= 0.5 ? idx + 1 : idx` rounding gives **6** —
    /// line 1, column 0 — where `characterIndexForInsertion` gives **5**, the
    /// end of line 0 where the user pointed. A drag to the right of a line
    /// would silently take the rectangle onto the line below (§4). Below the
    /// last line `characterIndexForInsertion` also returns the document's
    /// trailing position (measured: `14`) rather than refusing the point.
    ///
    /// So this is not a convenience wrapper that could be "optimised" to the
    /// layout manager: the two calls disagree by one line.
    ///
    /// A live block's `LineIndex` is reused when there is one. Building one is
    /// an O(document) scan and the mouse path asks for a position on every
    /// `mouseDragged` sample, which is the whole reason the table is cached
    /// alongside the block in the first place.
    func blockPosition(for pointInView: NSPoint) -> BlockPosition {
        let index = blockLineIndex ?? LineIndex(string)
        return index.position(forUTF16Offset: characterIndexForInsertion(at: pointInView))
    }

    // MARK: - Block selection: ⌥-drag

    /// ⌥-drag draws a rectangle; every other click stays AppKit's.
    ///
    /// **An ordinary click deliberately does not drop the block here.**
    /// `super.mouseDown` sets the selection for the click, and that arrives at
    /// the `setSelectedRange(s)` choke point, which drops it (§5). A second
    /// drop on this path would be a second place for the rule to live, and the
    /// choke point is the one that has to be right — ⌘F, the Insert menu and
    /// every programmatic selection reach it and nothing else.
    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.option) else {
            super.mouseDown(with: event)
            return
        }
        trackBlockSelection(from: event)
    }

    /// Run a ⌥-drag through to its mouse-up.
    ///
    /// A hand-rolled `nextEvent(matching:)` loop, and not the
    /// `NSGestureRecognizer` that is the modern default for a click or a pan:
    /// a pan recognizer does not claim the gesture until it has seen enough
    /// movement to tell a drag from a click, and the rectangle has to exist
    /// from the first sample so the carets appear where the mouse went down.
    /// There is also no view-level API to replace it with — `NSTextView` has
    /// no rectangular selection of its own, and macOS 27's
    /// `NSTextSelectionManager` is past this app's macOS 14 deployment target.
    ///
    /// `NSApplication` is asked for the events rather than the window, because
    /// periodic events belong to no window and `NSWindow.nextEvent(matching:)`
    /// is not the place to find out whether that matters.
    private func trackBlockSelection(from event: NSEvent) {
        // `super.mouseDown` is what normally focuses a text view on a click,
        // and this path never calls it — so a ⌥-drag into an unfocused editor
        // would otherwise build a rectangle nothing can be typed into. Taken
        // *before* the block starts: becoming first responder sets the
        // selection, which reaches the choke point and would drop it.
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }

        let start = blockPosition(for: convert(event.locationInWindow, from: nil))
        beginBlockSelection(anchor: start, head: start)

        // Periodic events are matched alongside the drags so that a drag held
        // still past the view's edge keeps scrolling. `autoscroll(with:)`
        // advances the document once per call, so a loop fed only by mouse
        // samples stops the moment the mouse does — "drag to the bottom edge
        // and hold" would scroll one step and stall.
        NSEvent.startPeriodicEvents(afterDelay: 0.1, withPeriod: 0.05)
        defer { NSEvent.stopPeriodicEvents() }

        var lastDrag = event
        while let next = NSApplication.shared.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp, .periodic],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ), next.type != .leftMouseUp {
            // A periodic event carries no usable location, so the last drag's
            // is reused: it is still where the mouse is being held.
            if next.type == .leftMouseDragged { lastDrag = next }
            // Scroll first, then read the position. The window point has not
            // moved but the text under it has, and the head is meant to follow
            // the line that just scrolled into view.
            autoscroll(with: lastDrag)
            let head = blockPosition(for: convert(lastDrag.locationInWindow, from: nil))
            if head != blockSelection?.head { updateBlockSelection(head: head) }
        }

        // A ⌥-click with no drag leaves a rectangle with no extent in either
        // dimension: nothing highlighted, one caret drawn, and every following
        // keystroke routed through the block paths for a reason the user
        // cannot see. Collapse it to the plain caret they clicked for.
        if let block = blockSelection, block.anchor == block.head {
            dropBlockSelection()
        }
    }

    // MARK: - Block selection: key routing

    /// `insertText:`, as a plain selector.
    ///
    /// `#selector(NSText.insertText(_:))` would name the same method but the
    /// single-argument form is deprecated, and referring to it costs a
    /// deprecation warning for no gain — `doCommand(by:)` is handed a
    /// `Selector`, never the method. The double parentheses tell Swift the
    /// string literal is deliberate rather than a `#selector` someone forgot.
    /// `NSSelectorFromString` rather than `#selector(insertText(_:))`: the
    /// single-argument `insertText:` is deprecated, so `#selector` on it warns,
    /// and `Selector(("insertText:"))` warns the other way round ("use
    /// '#selector' instead"). This spelling is the documented way to name a
    /// selector that has no non-deprecated Swift declaration to point at.
    private static let insertTextCommand = NSSelectorFromString("insertText:")

    /// Every key binding that touches the block, routed in one place (§2).
    ///
    /// **One override, not five.** The point of a single `switch` is its
    /// `default:` case: anything not named below **drops the block** before
    /// `super` sees it. The block holds line/column coordinates, so a command
    /// that moves the selection or rewrites the text without the view knowing
    /// leaves `blockSelection` and `selectedRanges` describing different
    /// things — and the next block edit is then applied at offsets taken from
    /// the wrong document (§5). Five separate method overrides would each
    /// handle their own selector and silently let every other one through.
    /// Dropping is the safe side of that bet: the cost is a rectangle the user
    /// has to redraw, against an edit written into the wrong place.
    ///
    /// **The fall-through list is not redundant with `default:` — inverting it
    /// breaks tested behaviour.** `insertTab:`, `deleteBackward:`,
    /// `deleteForward:`, `insertText:` and `insertNewline:` must reach `super`
    /// with the block *still live*, because `insertText(_:replacementRange:)`,
    /// `deleteBackward(_:)` and `deleteForward(_:)` above already implement
    /// §2's rules for them: Tab fans out across the rows, the deletes take one
    /// grapheme per row without crossing a line boundary, and a newline drops
    /// the block itself before inserting exactly one. Dropping here first
    /// would indent one row instead of all of them and turn a block backspace
    /// into an ordinary one — `WritTextViewBlockSelectionTests` pins both.
    ///
    /// `⌥⇧←/→` is the hybrid case: `moveWordLeft/RightAndModifySelection:` is
    /// stock word-extend, a binding worth keeping, so it is only claimed while
    /// a block is live and otherwise falls through to `super`.
    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(NSResponder.moveParagraphBackwardAndModifySelection(_:)):
            extendBlock(byLines: -1)
        case #selector(NSResponder.moveParagraphForwardAndModifySelection(_:)):
            extendBlock(byLines: 1)
        case #selector(NSResponder.moveWordLeftAndModifySelection(_:)):
            if !extendBlock(byColumns: -1) { super.doCommand(by: selector) }
        case #selector(NSResponder.moveWordRightAndModifySelection(_:)):
            if !extendBlock(byColumns: 1) { super.doCommand(by: selector) }
        case #selector(NSResponder.cancelOperation(_:)):
            if blockSelection == nil {
                super.doCommand(by: selector)
            } else {
                dropBlockSelection()
            }
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertTab(_:)),
             #selector(NSResponder.deleteBackward(_:)),
             #selector(NSResponder.deleteForward(_:)),
             WritTextView.insertTextCommand:
            super.doCommand(by: selector)
        default:
            dropBlockSelection()
            super.doCommand(by: selector)
        }
    }

    /// ⌥⇧↑/↓: start a block when none is live, then move the head `lines`
    /// rows. The head's line clamps into the document — growing past the first
    /// or last line stops there rather than wrapping round or running off the
    /// line table.
    ///
    /// The column is carried over untouched, so a rectangle keeps its width as
    /// it grows and a column of carets stays zero-width.
    private func extendBlock(byLines lines: Int) {
        if blockSelection == nil { beginBlockSelectionFromSelection() }
        guard let block = blockSelection, let index = blockLineIndex else { return }
        let line = max(0, min(block.head.line + lines, index.lineCount - 1))
        updateBlockSelection(head: BlockPosition(line: line, column: block.head.column))
    }

    /// ⌥⇧←/→ **while a block is live**: move the head `columns` columns.
    /// Returns false when there is no block, which is the caller's signal to
    /// leave the keystroke to AppKit's word-extend.
    ///
    /// Column 0 is the floor. There is deliberately no ceiling: a column past
    /// a short row's end is the overhang case the model is built for — every
    /// row's fragment clamps to its own line and typing appends at the short
    /// row's end rather than padding with spaces (§3).
    private func extendBlock(byColumns columns: Int) -> Bool {
        guard let block = blockSelection else { return false }
        updateBlockSelection(
            head: BlockPosition(
                line: block.head.line, column: max(0, block.head.column + columns)
            )
        )
        return true
    }

    /// Turn the current selection into a block: the anchor corner at its
    /// start, the head corner at its end.
    ///
    /// A caret gives a zero-width block, which is the common case —
    /// ⌥⇧↓ from a caret and typing is the feature's motivating gesture. A
    /// single-line selection gives the block its column span, so selecting
    /// `|` on one line and pulling the rectangle down turns into a column of
    /// pipes. A selection spanning several lines contributes both its rows and
    /// its columns, which is the same rule read without a special case.
    private func beginBlockSelectionFromSelection() {
        let index = LineIndex(string)
        let selection = selectedRange()
        beginBlockSelection(
            anchor: index.position(forUTF16Offset: selection.location),
            head: index.position(forUTF16Offset: NSMaxRange(selection))
        )
    }

    // MARK: - Block selection: the two choke points

    /// Selection changed. A plain click, ⌘F, the Insert menu's helpers and any
    /// other programmatic selection all arrive here, and none of them agree
    /// with the rectangle — so the default is to drop it and the only
    /// exemptions are the view's own two (`ownsThisSelectionChange`).
    override func setSelectedRanges(
        _ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool
    ) {
        if !ownsThisSelectionChange { discardBlockSelection() }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
    }

    /// The single-range form is overridden as well as the multi-range one
    /// rather than trusting it to funnel through it: `NSTextView` documents
    /// `setSelectedRanges(_:affinity:stillSelecting:)` as the primitive, but a
    /// block left live against a selection it does not match is a wrong-place
    /// edit, which is too expensive to stake on that.
    override func setSelectedRange(
        _ charRange: NSRange, affinity: NSSelectionAffinity, stillSelecting: Bool
    ) {
        if !ownsThisSelectionChange { discardBlockSelection() }
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelecting)
    }

    /// The two selection changes the block makes itself, directly or not.
    ///
    /// Rendering is the obvious one. The second is measured rather than
    /// assumed, and is not in §5's list: `replaceCharacters` inside
    /// `applyBlockEdits` makes AppKit adjust the selection around the edited
    /// range, and that arrives here like any other selection change. Without
    /// this second exemption no block survives its own edit — six of the tests
    /// in `WritTextViewBlockSelectionTests` fail, each on the block being nil
    /// the moment the edit returns.
    private var ownsThisSelectionChange: Bool {
        isRefreshingBlockDisplay || isApplyingBlockEdit
    }

    /// Text changed. Undo, Find & Replace, `setSource` and the syntax
    /// highlighter all reach the view this way; a block holding line/column
    /// coordinates into the *previous* text would write its next edit into the
    /// wrong place, so anything the view did not do itself drops it.
    ///
    /// Only `.editedCharacters` can invalidate a coordinate. The attribute-only
    /// pass is not a hypothetical: `EditorViewController.scheduleHighlight()`
    /// re-styles the document on an 80 ms debounce, so without this filter
    /// every block edit would be followed a moment later by the highlighter
    /// silently dropping the rectangle the user is still working in. Measured
    /// on this stack: `editedMask` inside the notification is `2`
    /// (`.editedCharacters`) for a character edit and `1`
    /// (`.editedAttributes`) for an attribute edit.
    private func dropBlockSelectionIfInvalidated(by storage: NSTextStorage) {
        guard storage.editedMask.contains(.editedCharacters) else { return }
        guard !isApplyingBlockEdit else { return }
        discardBlockSelection()
    }

    /// Forget the block without touching the selection — for the choke points,
    /// where whatever caused the drop is already setting the selection (or
    /// changing the text) and a second selection change would fight it.
    private func discardBlockSelection() {
        // The drawn carets are not in `selectedRanges`, so nothing else will
        // dirty the rows they are on: without this they stay on screen after
        // the rectangle they belonged to is gone. Guarded on there having been
        // a block, since the choke points call this on every selection change.
        if blockSelection != nil { needsDisplay = true }
        blockSelection = nil
        blockLineIndex = nil
    }

    // MARK: - Block selection: applying edits

    /// Apply one block operation as a single undoable change. Returns false
    /// when there was nothing to do.
    ///
    /// An empty list changes nothing and registers no undo group: the delete
    /// paths legitimately return `[]` (every caret at column 0, say), and a
    /// batch of nothing would still leave the user a ⌘Z to press for no
    /// visible reason.
    ///
    /// `shouldChangeText(inRanges:replacementStrings:)` documents its ranges as
    /// sorted ascending, while the model returns them **descending** so that
    /// each replacement only moves text after itself and the edits that have
    /// not run yet keep valid locations. Both are honoured: a sorted copy asks
    /// permission, the originals do the work.
    ///
    /// One `shouldChangeText`/`didChangeText` pair around one `beginEditing`/
    /// `endEditing` pair is what makes the whole fan-out a single undo group,
    /// so one ⌘Z restores the document (§4).
    @discardableResult
    private func applyBlockEdits(_ edits: [BlockEdit]) -> Bool {
        guard !edits.isEmpty, let storage = textStorage else { return false }
        let ascending = edits.sorted { $0.range.location < $1.range.location }
        guard shouldChangeText(
            inRanges: ascending.map { NSValue(range: $0.range) },
            replacementStrings: ascending.map(\.replacement)
        ) else { return false }

        isApplyingBlockEdit = true
        defer { isApplyingBlockEdit = false }
        storage.beginEditing()
        for edit in edits {
            // A plain `String` replacement inherits the attributes of the text
            // it lands in, which is what keeps each row's own paragraph style
            // — and so its line height — intact. Imposing `typingAttributes`
            // on every row instead has cost this editor line-height drift once
            // already.
            storage.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        storage.endEditing()
        didChangeText()
        return true
    }

    /// Replace the block with a zero-width one at `column` over the same rows,
    /// and rebuild the line table from the edited text.
    ///
    /// Keeping a rectangle a rectangle is what lets the user type, backspace
    /// and type again without re-dragging. The anchor and head keep their own
    /// rows so the direction of a later ⌥⇧ extension is preserved; only the
    /// columns collapse. The old line table's offsets are stale the moment the
    /// edits land, so it is rebuilt rather than adjusted.
    ///
    /// The rows are read off the **live** block, not off a pre-edit copy. The
    /// block is supposed to have survived its own edit — that is what
    /// `isApplyingBlockEdit` is for — and restoring it from a snapshot here
    /// would paper over the choke point having dropped it, leaving the flag
    /// looking redundant. Reading the live state means deleting the flag makes
    /// the block vanish after every edit, which the tests catch.
    private func reshapeBlock(toColumn column: Int) {
        guard let block = blockSelection else { return }
        blockLineIndex = LineIndex(string)
        blockSelection = BlockSelection(
            anchor: BlockPosition(line: block.anchor.line, column: column),
            head: BlockPosition(line: block.head.line, column: column)
        )
        refreshBlockSelectionDisplay()
    }

    /// UTF-16 offset of a caret at `position`, snapped off any grapheme
    /// interior. Asks the model for a one-row zero-width block's fragment
    /// rather than re-deriving the snap: `fragmentRanges` already clamps the
    /// column into the row and pulls a caret back to its grapheme's start, and
    /// two implementations of that rule would be one too many.
    private static func caretOffset(of position: BlockPosition, in index: LineIndex) -> Int {
        BlockSelection(anchor: position, head: position)
            .fragmentRanges(in: index).first?.location
            ?? index.utf16Offset(of: position)
    }

    // MARK: - Block selection: the operations

    private func insertIntoBlock(_ typed: String) {
        guard let block = blockSelection, let index = blockLineIndex else { return }
        // Read everything off the block *before* applying: AppKit adjusts the
        // selection during the storage edit, which runs through the choke
        // point above and clears `blockSelection`. Every operation below takes
        // the same precaution.
        let left = block.columnRange.lowerBound
        guard applyBlockEdits(block.replacementEdits(with: typed, in: index)) else { return }
        reshapeBlock(toColumn: left + typed.utf16.count)
    }

    override func deleteBackward(_ sender: Any?) {
        guard let block = blockSelection, let index = blockLineIndex else {
            super.deleteBackward(sender)
            return
        }
        let left = block.columnRange.lowerBound
        // A non-empty block simply loses its fragments, so every caret ends at
        // the left edge. A zero-width one loses one grapheme per row, so the
        // carets move left by the width of the grapheme — measured on the head
        // row, which is exact for ASCII and drifts a unit or two where rows
        // mix UTF-16 widths (§7).
        let column = block.isZeroWidth
            ? max(0, left - WritTextView.headBackspaceWidth(block, in: index))
            : left
        // No fall-through to `super` when the model returns no edits. Stock
        // backspace at column 0 joins the line above, which would dissolve the
        // rows the rectangle is defined over (§3).
        if applyBlockEdits(block.backspaceEdits(in: index)) {
            reshapeBlock(toColumn: column)
        }
    }

    override func deleteForward(_ sender: Any?) {
        guard let block = blockSelection, let index = blockLineIndex else {
            super.deleteForward(sender)
            return
        }
        let left = block.columnRange.lowerBound
        // Forward delete takes the grapheme to the right of each caret, so the
        // carets do not move. As with backspace, no edits means nothing
        // happens: stock forward delete at end-of-line eats the newline.
        if applyBlockEdits(block.forwardDeleteEdits(in: index)) {
            reshapeBlock(toColumn: left)
        }
    }

    /// UTF-16 length of the grapheme a backspace would take from the head row,
    /// or 0 when that row is at column 0. Asks the model for the one-row
    /// block's own backspace edit, so the grapheme rule lives in exactly one
    /// place.
    private static func headBackspaceWidth(_ block: BlockSelection, in index: LineIndex) -> Int {
        BlockSelection(anchor: block.head, head: block.head)
            .backspaceEdits(in: index).first?.range.length ?? 0
    }

    /// Copy the rectangle, newline-joined, from the model rather than from
    /// AppKit. AppKit's own copy is already `\n`-joined but it joins the
    /// ranges it kept — and it dropped the empty ones, so a block overhanging
    /// a short row comes back with that row missing and the rectangle's shape
    /// lost (§4).
    override func copy(_ sender: Any?) {
        guard let block = blockSelection, let index = blockLineIndex else {
            super.copy(sender)
            return
        }
        writeToPasteboard(block.copyString(in: index))
    }

    override func cut(_ sender: Any?) {
        guard let block = blockSelection, let index = blockLineIndex else {
            super.cut(sender)
            return
        }
        // A column of carets has nothing to cut, and stock Cut on an empty
        // selection is a no-op. Routing it into the delete path would make ⌘X
        // eat a grapheme per row, which is ⌫'s job.
        guard !block.isZeroWidth else { return }
        let left = block.columnRange.lowerBound
        writeToPasteboard(block.copyString(in: index))
        // Deliberately `backspaceEdits`, not `replacementEdits(with: "")`:
        // only the delete paths drop the rows that have nothing to delete, and
        // a block overhanging *every* row clamps to a zero-length fragment on
        // each. Through `replacementEdits` that would be a batch of pure
        // no-ops — an empty undo group for the user to press ⌘Z through.
        if applyBlockEdits(block.backspaceEdits(in: index)) {
            reshapeBlock(toColumn: left)
        }
    }

    private func pasteIntoBlock(_ clipboard: String, block: BlockSelection, index: LineIndex) {
        let left = block.columnRange.lowerBound
        let edits = block.pasteEdits(clipboard: clipboard, in: index)
        guard applyBlockEdits(edits), let lastApplied = edits.last else { return }
        if let line = WritTextView.soleClipboardLine(clipboard) {
            // One clipboard line went onto every row, so the rows still share
            // a column and the rectangle survives.
            reshapeBlock(toColumn: left + line.utf16.count)
            return
        }
        // A positional paste (one clipboard line per row) or the verbatim
        // fallback leaves the rows at different columns, so there is no
        // rectangle to keep. One caret at the end of the edit applied last —
        // the lowest-located one, since the model orders them descending, so
        // every edit that moved text did so above it and its own end offset is
        // still valid.
        discardBlockSelection()
        setSelectedRange(
            NSRange(
                location: lastApplied.range.location + lastApplied.replacement.utf16.count,
                length: 0
            )
        )
    }

    /// The clipboard's only line, or nil when it holds more than one. Splits
    /// the way `BlockSelection.pasteEdits` does — discard at most one trailing
    /// newline, then look for another — over unicode scalars, because `\r\n` is
    /// a single `Character` and counting it as a line break here would
    /// disagree with `LineIndex`, which counts only `\n`.
    private static func soleClipboardLine(_ clipboard: String) -> String? {
        var scalars = Array(clipboard.unicodeScalars)
        if scalars.last == "\n" { scalars.removeLast() }
        guard !scalars.contains("\n") else { return nil }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Dead-key and input-method composition marks only the *first* of several
    /// ranges, so a rectangle cannot survive it: it drops and then composes
    /// normally at one caret (§2).
    override func setMarkedText(
        _ string: Any, selectedRange: NSRange, replacementRange: NSRange
    ) {
        dropBlockSelection()
        super.setMarkedText(
            string, selectedRange: selectedRange, replacementRange: replacementRange
        )
    }

    private func writeToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
