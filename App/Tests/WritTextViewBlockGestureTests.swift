import AppKit
import XCTest

/// The *input* half of rectangular selection: hit-testing a point to a
/// `BlockPosition`, and the `doCommand(by:)` key routing that starts, grows
/// and drops a block (docs/05-BLOCK-SELECTION.md §2).
///
/// **The keyboard is driven through `doCommand(by:)` only.** Neither
/// `mouseDown(with:)` nor `interpretKeyEvents(_:)` is safe here:
/// `NSTextView.mouseDown` runs its own modal event-tracking loop waiting for a
/// mouse-up that never arrives in a test process, and posting a synthetic
/// mouse-up through `NSApp.postEvent(_:atStart:)` first does not rescue it —
/// measured, it still hangs until the harness is killed.
/// `interpretKeyEvents` routes through the input context and hung the same
/// way. `doCommand(by:)` is a plain synchronous method call and is exactly the
/// seam the key bindings arrive at, so nothing is being faked by calling it
/// directly.
final class WritTextViewBlockGestureTests: XCTestCase {

    /// The fixture every measured hit-testing fact below was taken on.
    /// Line 0 is chars 0–4 with its `\n` at 5, line 1 is chars 6–7 with its
    /// `\n` at 8, line 2 is chars 9–13, and the document is 14 UTF-16 units.
    private static let fixture = "alpha\nbb\ngamma"

    /// A point in **view** coordinates at the vertical middle of `line`, at
    /// `x`. `characterIndexForInsertion(at:)` takes view coordinates and
    /// applies `textContainerOrigin` itself, so the container origin is added
    /// here to go the other way. It is `(0, 0)` in the harness — the addition
    /// is for the reader, and for a harness that one day insets its container.
    @MainActor
    private func point(_ harness: TextViewHarness, x: CGFloat, line: Int) -> NSPoint {
        let lineStart = LineIndex(harness.textView.string).lineStart(line)
        let glyph = harness.layoutManager.glyphIndexForCharacter(at: lineStart)
        let fragment = harness.layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let origin = harness.textView.textContainerOrigin
        return NSPoint(x: x + origin.x, y: fragment.midY + origin.y)
    }

    // MARK: - Hit-testing

    @MainActor
    func testHitTestingFarPastEndOfLineClampsToThatLine() {
        let harness = TextViewHarness(Self.fixture)
        harness.assertTextKit1()

        let far = point(harness, x: 5000, line: 1)

        XCTAssertEqual(
            harness.textView.blockPosition(for: far),
            BlockPosition(line: 1, column: 2),
            """
            a point past end-of-line must clamp to that line's own end (offset 8). \
            Line 2 column 0 would mean the hit test used the layout manager's \
            fraction-rounded index, which bleeds onto the next line (§4)
            """
        )
    }

    @MainActor
    func testHitTestingAboveTheDocumentYieldsTheFirstPosition() {
        let harness = TextViewHarness(Self.fixture)

        let above = NSPoint(x: 3, y: -50)

        XCTAssertEqual(
            harness.textView.blockPosition(for: above),
            BlockPosition(line: 0, column: 0),
            "a point above the document is the document's start"
        )
    }

    @MainActor
    func testHitTestingBelowTheDocumentYieldsTheLastPosition() {
        let harness = TextViewHarness(Self.fixture)

        let below = NSPoint(x: 3, y: 10_000)

        XCTAssertEqual(
            harness.textView.blockPosition(for: below),
            BlockPosition(line: 2, column: 5),
            "a point below the document is the document's end — offset 14, the last line's end"
        )
    }

    @MainActor
    func testHitTestingResolvesAnInteriorPointToItsLineAndColumn() {
        let harness = TextViewHarness(Self.fixture)
        // Past the middle of the glyph at offset 2, so the insertion point
        // rounds forward to 3 without the test betting on how AppKit breaks
        // an exact half-way tie.
        let glyph = harness.layoutManager.boundingRect(
            forGlyphRange: NSRange(location: 2, length: 1), in: harness.textContainer
        )
        let origin = harness.textView.textContainerOrigin
        let inside = NSPoint(
            x: glyph.minX + glyph.width * 0.6 + origin.x,
            y: glyph.midY + origin.y
        )

        XCTAssertEqual(
            harness.textView.blockPosition(for: inside),
            BlockPosition(line: 0, column: 3),
            "an interior point resolves to the insertion point nearest it"
        )
    }

    // MARK: - Key routing: the selectors under test

    /// `~$\UF701` in `StandardKeyBinding.dict` — ⌥⇧↓.
    private static let optionShiftDown = #selector(NSResponder.moveParagraphForwardAndModifySelection(_:))
    /// `~$\UF700` — ⌥⇧↑.
    private static let optionShiftUp = #selector(NSResponder.moveParagraphBackwardAndModifySelection(_:))
    /// `~$\UF702` — ⌥⇧←, which is stock word-extend when no block is live.
    private static let optionShiftLeft = #selector(NSResponder.moveWordLeftAndModifySelection(_:))
    /// `~$\UF703` — ⌥⇧→.
    private static let optionShiftRight = #selector(NSResponder.moveWordRightAndModifySelection(_:))

    /// A zero-width block: one column of carets at `column`, over `lines`.
    @MainActor
    private func carets(_ harness: TextViewHarness, column: Int, lines: ClosedRange<Int>) {
        harness.textView.beginBlockSelection(
            anchor: BlockPosition(line: lines.lowerBound, column: column),
            head: BlockPosition(line: lines.upperBound, column: column)
        )
    }

    // MARK: - Key routing: starting and growing a block

    @MainActor
    func testOptionShiftDownStartsABlockFromTheCaret() {
        let harness = TextViewHarness(Self.fixture)
        harness.textView.setSelectedRange(NSRange(location: 2, length: 0))

        harness.textView.doCommand(by: Self.optionShiftDown)

        XCTAssertEqual(
            harness.textView.blockSelection,
            BlockSelection(
                anchor: BlockPosition(line: 0, column: 2), head: BlockPosition(line: 1, column: 2)
            ),
            "⌥⇧↓ with no block live anchors one at the caret and puts the head one line down"
        )
    }

    @MainActor
    func testOptionShiftDownGrowsAnExistingBlock() {
        let harness = TextViewHarness(Self.fixture)
        harness.textView.setSelectedRange(NSRange(location: 2, length: 0))

        harness.textView.doCommand(by: Self.optionShiftDown)
        harness.textView.doCommand(by: Self.optionShiftDown)

        XCTAssertEqual(
            harness.textView.blockSelection?.head, BlockPosition(line: 2, column: 2),
            "the second ⌥⇧↓ grows the block instead of restarting it"
        )
        XCTAssertEqual(
            harness.textView.blockSelection?.anchor, BlockPosition(line: 0, column: 2),
            "and the anchor stays where the gesture started"
        )
    }

    @MainActor
    func testOptionShiftUpGrowsTheBlockUpward() {
        let harness = TextViewHarness(Self.fixture)
        // Caret on line 2, column 1.
        harness.textView.setSelectedRange(NSRange(location: 10, length: 0))

        harness.textView.doCommand(by: Self.optionShiftUp)
        harness.textView.doCommand(by: Self.optionShiftUp)

        XCTAssertEqual(
            harness.textView.blockSelection?.head, BlockPosition(line: 0, column: 1),
            "⌥⇧↑ walks the head up, two lines for two presses"
        )
        XCTAssertEqual(harness.textView.blockSelection?.lineRange, 0...2)
    }

    @MainActor
    func testOptionShiftArrowsStartABlockFromAnExistingSelection() {
        let harness = TextViewHarness(Self.fixture)
        // "lph" — a single-line selection, columns 1..<4 of line 0.
        harness.textView.setSelectedRange(NSRange(location: 1, length: 3))

        harness.textView.doCommand(by: Self.optionShiftDown)

        let block = harness.textView.blockSelection
        XCTAssertEqual(
            block?.anchor, BlockPosition(line: 0, column: 1),
            "the selection's start becomes the anchor corner"
        )
        XCTAssertEqual(
            block?.head, BlockPosition(line: 1, column: 4),
            "its end becomes the head corner, which then moves one line down"
        )
        XCTAssertEqual(
            block?.columnRange, 1..<4,
            "so a single-line selection turns into the rectangle's column span"
        )
    }

    @MainActor
    func testGrowingPastTheLastLineClamps() {
        let harness = TextViewHarness(Self.fixture)
        harness.textView.setSelectedRange(NSRange(location: 0, length: 0))

        for _ in 0..<6 { harness.textView.doCommand(by: Self.optionShiftDown) }

        XCTAssertEqual(
            harness.textView.blockSelection?.head, BlockPosition(line: 2, column: 0),
            "growing past the last line clamps there — it does not wrap, overshoot or trap"
        )
    }

    @MainActor
    func testGrowingPastTheFirstLineClamps() {
        let harness = TextViewHarness(Self.fixture)
        // Caret on line 1.
        harness.textView.setSelectedRange(NSRange(location: 6, length: 0))

        for _ in 0..<6 { harness.textView.doCommand(by: Self.optionShiftUp) }

        XCTAssertEqual(
            harness.textView.blockSelection?.head, BlockPosition(line: 0, column: 0),
            "growing past the first line clamps there"
        )
        XCTAssertEqual(
            harness.textView.blockSelection?.anchor, BlockPosition(line: 1, column: 0),
            "and the anchor is untouched by the clamping"
        )
    }

    // MARK: - Key routing: the hybrid horizontal extend

    @MainActor
    func testHorizontalExtendIsIgnoredWhenNoBlockIsActive() {
        let harness = TextViewHarness("alpha beta")
        harness.textView.setSelectedRange(NSRange(location: 0, length: 0))

        harness.textView.doCommand(by: Self.optionShiftRight)

        XCTAssertNil(
            harness.textView.blockSelection,
            "⌥⇧→ must not invent a block: with none live it stays stock word-extend (§2)"
        )
        XCTAssertEqual(
            harness.textView.selectedRange(), NSRange(location: 0, length: 5),
            "and AppKit's own word-extend ran, selecting the first word"
        )
    }

    @MainActor
    func testHorizontalExtendWidensALiveBlock() {
        let harness = TextViewHarness(Self.fixture)
        harness.textView.setSelectedRange(NSRange(location: 0, length: 0))
        harness.textView.doCommand(by: Self.optionShiftDown)

        harness.textView.doCommand(by: Self.optionShiftRight)

        XCTAssertEqual(
            harness.textView.blockSelection?.head, BlockPosition(line: 1, column: 1),
            "with a block live, ⌥⇧→ moves the head one column instead of one word"
        )
        XCTAssertEqual(harness.textView.blockSelection?.columnRange, 0..<1)
        XCTAssertEqual(
            harness.textView.selectedRanges.map(\.rangeValue),
            [NSRange(location: 0, length: 1), NSRange(location: 6, length: 1)],
            "and the rendering followed, so the extend refreshed the display"
        )
    }

    @MainActor
    func testLeftExtendClampsAtColumnZero() {
        let harness = TextViewHarness(Self.fixture)
        harness.textView.setSelectedRange(NSRange(location: 0, length: 0))
        harness.textView.doCommand(by: Self.optionShiftDown)

        harness.textView.doCommand(by: Self.optionShiftLeft)
        harness.textView.doCommand(by: Self.optionShiftLeft)

        XCTAssertEqual(
            harness.textView.blockSelection?.head, BlockPosition(line: 1, column: 0),
            "a left-extend at column 0 stays at column 0 rather than going negative"
        )
        XCTAssertEqual(
            harness.textView.blockSelection?.isZeroWidth, true,
            "so the block is still the column of carets it was"
        )
    }

    // MARK: - Key routing: dropping, and the selectors that must not drop

    @MainActor
    func testEscapeDropsTheBlock() {
        let harness = TextViewHarness(Self.fixture)
        carets(harness, column: 2, lines: 0...1)

        harness.textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))

        XCTAssertNil(harness.textView.blockSelection, "Esc ends the rectangle (§2)")
        XCTAssertEqual(
            harness.textView.selectedRange(), NSRange(location: 8, length: 0),
            "collapsing to one caret at the head corner — line 1, column 2"
        )
    }

    @MainActor
    func testAnUnhandledCommandDropsTheBlock() {
        let harness = TextViewHarness(Self.fixture)
        carets(harness, column: 2, lines: 0...1)

        // A movement selector deliberately *not* in the routing table, so it
        // lands in `doCommand(by:)`'s default case.
        harness.textView.doCommand(by: #selector(NSResponder.moveDown(_:)))

        XCTAssertNil(
            harness.textView.blockSelection,
            """
            the default case drops the block: an unhandled command can otherwise \
            leave `blockSelection` and `selectedRanges` disagreeing, and the next \
            block edit would then be applied at the wrong offsets (§5)
            """
        )
    }

    @MainActor
    func testTabDoesNotDropTheBlockInDoCommand() {
        let harness = TextViewHarness("ab\ncd")
        carets(harness, column: 0, lines: 0...1)

        harness.textView.doCommand(by: #selector(NSResponder.insertTab(_:)))

        XCTAssertEqual(
            harness.escaped, "\tab⏎\tcd",
            "Tab must reach the existing insert path and fan out — dropping first would indent one row"
        )
        XCTAssertNotNil(harness.textView.blockSelection, "and the rectangle survives its own edit")
    }

    @MainActor
    func testDeleteBackwardDoesNotDropTheBlockInDoCommand() {
        let harness = TextViewHarness("abc\ndef")
        carets(harness, column: 1, lines: 0...1)

        harness.textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))

        XCTAssertEqual(
            harness.escaped, "bc⏎ef",
            "Backspace must reach the existing override, which takes one grapheme per row"
        )
        XCTAssertNotNil(harness.textView.blockSelection, "and the rectangle survives")
    }

    // MARK: - The motivating case, driven entirely from the keyboard

    @MainActor
    func testStartingABlockThenTypingPrefixesEveryRow() {
        let harness = TextViewHarness("alpha\nbeta\ngamma")
        harness.textView.setSelectedRange(NSRange(location: 0, length: 0))

        harness.textView.doCommand(by: Self.optionShiftDown)
        harness.textView.doCommand(by: Self.optionShiftDown)
        harness.textView.insertText("- ", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(
            harness.escaped, "- alpha⏎- beta⏎- gamma",
            "caret, ⌥⇧↓ twice, type — three rows prefixed is the job this feature exists for"
        )
    }

    // MARK: - Caret geometry for the rows AppKit will not draw

    /// The line fragment rect `line` starts in, read off the layout manager so
    /// the assertions below are about `blockCaretRect`'s arithmetic and not
    /// about the fixture font's metrics. **Which** fragment a caret lands in is
    /// the interesting part, so that is asserted exactly; the x coordinates are
    /// asserted relationally except where a measured constant *is* the rule
    /// under test (the 5pt padding).
    @MainActor
    private func lineFragment(_ harness: TextViewHarness, line: Int) -> NSRect {
        let start = LineIndex(harness.textView.string).lineStart(line)
        let glyph = harness.layoutManager.glyphIndexForCharacter(at: start)
        return harness.layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    }

    @MainActor
    func testCaretRectAtAnInteriorOffsetSitsAtItsLinesStart() throws {
        let harness = TextViewHarness(Self.fixture)
        harness.assertTextKit1()

        // Offset 6 — line 1, column 0.
        let caret = try XCTUnwrap(harness.textView.blockCaretRect(atUTF16Offset: 6))

        XCTAssertEqual(
            caret.minY, lineFragment(harness, line: 1).minY,
            "the caret takes its row from the line fragment the glyph is in"
        )
        XCTAssertEqual(caret.height, lineFragment(harness, line: 1).height)
        XCTAssertEqual(
            caret.width, 1, "one point wide, like the insertion point AppKit draws itself"
        )
        XCTAssertEqual(
            caret.minX, 5, accuracy: 0.001,
            """
            a line-start caret sits at the container's 5pt lineFragmentPadding and \
            no further: `location(forGlyphAt:)` already includes it, so 10 would \
            mean the padding was added a second time
            """
        )
    }

    @MainActor
    func testCaretRectAtEndOfLineStaysOnThatLine() throws {
        let harness = TextViewHarness(Self.fixture)

        // Offset 5 — the end of "alpha", where its newline begins.
        let caret = try XCTUnwrap(harness.textView.blockCaretRect(atUTF16Offset: 5))
        let oneLeft = try XCTUnwrap(harness.textView.blockCaretRect(atUTF16Offset: 4))

        XCTAssertEqual(
            caret.minY, lineFragment(harness, line: 0).minY,
            """
            an end-of-line caret belongs to line 0. Line 1's minY would mean the \
            newline's glyph was taken to start the line it ends (§4)
            """
        )
        XCTAssertGreaterThan(
            caret.minX, oneLeft.minX, "and it is one character further right than the caret before it"
        )
    }

    @MainActor
    func testCaretRectOnThePhantomLineAfterATrailingNewline() throws {
        let harness = TextViewHarness("ab\n")
        let extra = harness.layoutManager.extraLineFragmentRect
        XCTAssertNotNil(
            harness.layoutManager.extraLineFragmentTextContainer,
            "the fixture has to end in a newline for there to be a phantom row at all"
        )

        // Offset 3 is both the document's end and the phantom line's column 0.
        let caret = try XCTUnwrap(harness.textView.blockCaretRect(atUTF16Offset: 3))

        XCTAssertEqual(
            caret.minY, extra.minY, "the phantom row's caret comes from the extra line fragment"
        )
        XCTAssertEqual(caret.height, extra.height)
        XCTAssertGreaterThan(
            caret.minY, lineFragment(harness, line: 0).minY, "and it is below the real line, not on it"
        )
        XCTAssertEqual(
            caret.minX, 5, accuracy: 0.001,
            "at the padding — there is no glyph to take an x from, so it is added here"
        )
    }

    @MainActor
    func testCaretRectInAnEmptyDocument() throws {
        let harness = TextViewHarness("")
        XCTAssertEqual(
            harness.layoutManager.numberOfGlyphs, 0,
            "an empty document has no glyphs, so its caret can only come from the extra fragment"
        )

        let caret = try XCTUnwrap(
            harness.textView.blockCaretRect(atUTF16Offset: 0),
            """
            an empty document still has a caret position. nil here would leave the \
            single row of a block in a brand-new document with nothing drawn
            """
        )

        XCTAssertEqual(caret.minY, 0)
        XCTAssertEqual(caret.minX, 5, accuracy: 0.001)
        XCTAssertGreaterThan(
            caret.height, 0, "with a usable height, taken from the extra fragment"
        )
    }

    @MainActor
    func testCaretRectAtEndOfADocumentThatDoesNotEndInANewline() throws {
        let harness = TextViewHarness(Self.fixture)
        XCTAssertNil(
            harness.layoutManager.extraLineFragmentTextContainer,
            """
            a document not ending in a newline has no extra line fragment — which \
            is what makes this a third case and not the one above
            """
        )

        // Offset 14 — the end of "gamma", and so of the document.
        let caret = try XCTUnwrap(
            harness.textView.blockCaretRect(atUTF16Offset: 14),
            """
            the last position of the last line needs a caret: a zero-width block \
            parked there, or a ragged one overhanging it, puts a row here
            """
        )
        let oneLeft = try XCTUnwrap(harness.textView.blockCaretRect(atUTF16Offset: 13))

        XCTAssertEqual(
            caret.minY, lineFragment(harness, line: 2).minY,
            """
            on the last line — not 2pt below the document, where this stack's \
            degenerate extraLineFragmentRect of (0, 34, 0, 0) would put it
            """
        )
        XCTAssertEqual(caret.height, lineFragment(harness, line: 2).height)
        XCTAssertGreaterThan(caret.minX, oneLeft.minX, "one character right of the caret before it")
    }

    @MainActor
    func testCaretRectPastTheEndOfTheDocumentIsNil() {
        let harness = TextViewHarness(Self.fixture)

        XCTAssertNil(
            harness.textView.blockCaretRect(atUTF16Offset: 15),
            "an offset outside the document has no geometry, and a guess would be drawn somewhere"
        )
    }

    @MainActor
    func testAZeroWidthBlocksCaretsShareAColumnAndStepDownTheLines() throws {
        let harness = TextViewHarness(Self.fixture)
        carets(harness, column: 1, lines: 0...2)
        let block = try XCTUnwrap(harness.textView.blockSelection)

        let rects = try block.fragmentRanges(in: LineIndex(harness.textView.string)).map {
            try XCTUnwrap(
                harness.textView.blockCaretRect(atUTF16Offset: $0.location),
                "every row of a zero-width block needs a caret — that is all the user can see of it"
            )
        }

        XCTAssertEqual(rects.count, 3)
        XCTAssertEqual(
            Set(rects.map(\.minX)).count, 1, "all three carets line up in one column"
        )
        XCTAssertEqual(
            rects.map(\.minY), (0...2).map { lineFragment(harness, line: $0).minY },
            "one per line, in order, each on its own line fragment"
        )
    }
}
