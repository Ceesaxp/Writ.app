import AppKit
import XCTest

/// `WritTextView`'s half of rectangular selection, driven through the real
/// view on a real TextKit 1 stack (`TextViewHarness`).
///
/// The block is created programmatically here: ⌥-drag tracking, key routing
/// and the self-drawn carets belong to a later change. What is under test is
/// the state the block lives in, the edits it performs, and the points at
/// which it must be dropped.
///
/// The copy/cut/paste tests use the real `NSPasteboard.general` — there is no
/// seam to inject one — so `setUp`/`tearDown` save and restore whatever the
/// developer had on their clipboard. Running the suite should not cost you the
/// thing you were about to paste.
final class WritTextViewBlockSelectionTests: XCTestCase {

    /// The clipboard's plain-text contents as they were before this test ran.
    /// Only `.string` is preserved — these tests only ever write that flavour,
    /// and a faithful save of every flavour on the pasteboard is not worth the
    /// machinery here.
    private var savedClipboard: String??

    override func setUp() {
        super.setUp()
        savedClipboard = .some(NSPasteboard.general.string(forType: .string))
    }

    override func tearDown() {
        if case .some(let previous) = savedClipboard {
            NSPasteboard.general.clearContents()
            if let previous {
                NSPasteboard.general.setString(previous, forType: .string)
            }
        }
        savedClipboard = nil
        super.tearDown()
    }

    /// A zero-width block: one column of carets at `column`, over `lines`.
    @MainActor
    private func carets(_ harness: TextViewHarness, column: Int, lines: ClosedRange<Int>) {
        harness.textView.beginBlockSelection(
            anchor: BlockPosition(line: lines.lowerBound, column: column),
            head: BlockPosition(line: lines.upperBound, column: column)
        )
    }

    /// A rectangle spanning `columns` over `lines`.
    @MainActor
    private func rectangle(
        _ harness: TextViewHarness, columns: Range<Int>, lines: ClosedRange<Int>
    ) {
        harness.textView.beginBlockSelection(
            anchor: BlockPosition(line: lines.lowerBound, column: columns.lowerBound),
            head: BlockPosition(line: lines.upperBound, column: columns.upperBound)
        )
    }

    @MainActor
    private func putOnPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Typing

    @MainActor
    func testTypingIntoAZeroWidthBlockPrefixesEveryRow() {
        let harness = TextViewHarness("alpha\nbeta\ngamma")
        harness.assertTextKit1()
        carets(harness, column: 0, lines: 0...2)

        harness.textView.insertText("- ", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(
            harness.escaped, "- alpha⏎- beta⏎- gamma",
            "a zero-width block is N carets: typing must insert at every one of them"
        )
    }

    @MainActor
    func testOneUndoRestoresTheWholeDocumentAfterABlockEdit() {
        let harness = TextViewHarness("alpha\nbeta\ngamma")
        carets(harness, column: 0, lines: 0...2)
        harness.textView.insertText("- ", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(harness.escaped, "- alpha⏎- beta⏎- gamma")

        harness.textView.breakUndoCoalescing()
        XCTAssertEqual(harness.textView.undoManager?.canUndo, true, "the fan-out must be undoable")
        harness.textView.undoManager?.undo()

        XCTAssertEqual(
            harness.escaped, "alpha⏎beta⏎gamma",
            "the whole fan-out is one undo group, so a single Cmd-Z restores the document"
        )
        XCTAssertEqual(
            harness.textView.undoManager?.canUndo, false,
            "three rows must not cost three undo groups"
        )
    }

    @MainActor
    func testTypingReplacesEveryRowsFragmentInANonEmptyBlock() {
        let harness = TextViewHarness("aXXb\ncXXd\neXXf")
        rectangle(harness, columns: 1..<3, lines: 0...2)

        harness.textView.insertText("-", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(harness.escaped, "a-b⏎c-d⏎e-f", "every row's fragment is replaced, not just the first")
    }

    @MainActor
    func testTypingIntoABlockThatOverhangsAShortRowAppendsAtThatRowsEnd() {
        let harness = TextViewHarness("alpha\nbb\ngamma")
        rectangle(harness, columns: 3..<5, lines: 0...2)

        harness.textView.insertText("Z", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(
            harness.escaped, "alpZ⏎bbZ⏎gamZ",
            "clamp, do not pad: the short row gets the text at its own end, with no invented spaces"
        )
    }

    @MainActor
    func testTypingLeavesAZeroWidthBlockPastWhatWasTyped() {
        let harness = TextViewHarness("alpha\nbeta\ngamma")
        carets(harness, column: 0, lines: 0...2)

        harness.textView.insertText("- ", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(
            harness.textView.blockSelection,
            BlockSelection(
                anchor: BlockPosition(line: 0, column: 2), head: BlockPosition(line: 2, column: 2)
            ),
            "a rectangle must stay a rectangle, carets past the two units just typed"
        )
    }

    @MainActor
    func testTypingAnAutoPairCharacterIntoABlockInsertsItLiterally() {
        let harness = TextViewHarness("ab\ncd")
        carets(harness, column: 0, lines: 0...1)

        harness.textView.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(
            harness.escaped, "(ab⏎(cd",
            "the block branch runs before auto-pair: pairing one row and fanning out the rest would be neither behaviour"
        )
    }

    @MainActor
    func testAutoPairStillWrapsASelectionWithNoBlockActive() {
        let harness = TextViewHarness("alpha")
        harness.textView.setSelectedRange(NSRange(location: 0, length: 5))

        harness.textView.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(harness.escaped, "(alpha)", "auto-pair wrapping must be untouched when no block is live")
        XCTAssertEqual(
            harness.textView.selectedRange(), NSRange(location: 1, length: 5),
            "and the wrapped text stays selected"
        )
    }

    // MARK: - Copy, cut, paste

    @MainActor
    func testBlockCopyJoinsRowsWithNewlines() {
        let harness = TextViewHarness("alpha\nbb\ngamma")
        rectangle(harness, columns: 3..<5, lines: 0...2)
        putOnPasteboard("stale")

        harness.textView.copy(nil)

        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string), "ha\n\nma",
            "the short row contributes an empty line — AppKit's own copy drops it and loses the rectangle's shape"
        )
        XCTAssertNotNil(harness.textView.blockSelection, "copying must not drop the block")
    }

    @MainActor
    func testBlockCutRemovesEveryRowAndCopies() {
        let harness = TextViewHarness("aXXb\ncXXd\neXXf")
        rectangle(harness, columns: 1..<3, lines: 0...2)

        harness.textView.cut(nil)

        XCTAssertEqual(harness.escaped, "ab⏎cd⏎ef", "cut removes every row's fragment")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "XX\nXX\nXX")
        XCTAssertEqual(
            harness.textView.blockSelection,
            BlockSelection(
                anchor: BlockPosition(line: 0, column: 1), head: BlockPosition(line: 2, column: 1)
            ),
            "the carets collapse to the rectangle's left edge"
        )
    }

    @MainActor
    func testCutOnAnOverhangingBlockRegistersNoEmptyUndoGroup() {
        // Columns 5..<8 reach past the end of every row, so every fragment
        // clamps to zero length. Routing Cut through `replacementEdits(with:
        // "")` would hand `shouldChangeText` three replace-nothing-with-nothing
        // edits and leave the user a Cmd-Z to press for no visible reason.
        let harness = TextViewHarness("ab\ncd")
        harness.textView.undoManager?.removeAllActions()
        rectangle(harness, columns: 5..<8, lines: 0...1)

        harness.textView.cut(nil)
        harness.textView.breakUndoCoalescing()

        XCTAssertEqual(harness.escaped, "ab⏎cd", "there was nothing inside the rectangle to cut")
        XCTAssertEqual(harness.textView.undoManager?.canUndo, false, "and so nothing to undo")
    }

    @MainActor
    func testCutOnAZeroWidthBlockDoesNothing() {
        // A reading of the spec, pinned so it is not silently "fixed": a column
        // of carets has no selection to cut, and stock Cut on an empty
        // selection is a no-op. Routing it into the delete path — which the
        // packet's "copy then backspaceEdits" says literally — would make Cmd-X
        // eat a grapheme per row, which is Backspace's job.
        let harness = TextViewHarness("abc\ndef")
        putOnPasteboard("sentinel")
        carets(harness, column: 2, lines: 0...1)

        harness.textView.cut(nil)

        XCTAssertEqual(harness.escaped, "abc⏎def", "there is no selection to cut")
        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string), "sentinel",
            "and nothing to put on the pasteboard either"
        )
        XCTAssertNotNil(harness.textView.blockSelection, "the block survives a gesture that did nothing")
    }

    @MainActor
    func testPastingASingleLineRepeatsItAcrossEveryRow() {
        let harness = TextViewHarness("a b\nc d\ne f")
        putOnPasteboard("|")
        carets(harness, column: 1, lines: 0...2)

        harness.textView.paste(nil)

        XCTAssertEqual(
            harness.escaped, "a| b⏎c| d⏎e| f",
            "one clipboard line goes onto every row — the table-pipe case"
        )
        XCTAssertEqual(
            harness.textView.blockSelection,
            BlockSelection(
                anchor: BlockPosition(line: 0, column: 2), head: BlockPosition(line: 2, column: 2)
            ),
            "the rows still share a column, so the rectangle survives past the pasted unit"
        )
    }

    @MainActor
    func testPastingSeveralLinesDropsTheBlock() {
        let harness = TextViewHarness("a b\nc d\ne f")
        putOnPasteboard("1\n2\n3")
        carets(harness, column: 1, lines: 0...2)

        harness.textView.paste(nil)

        XCTAssertEqual(harness.escaped, "a1 b⏎c2 d⏎e3 f", "a positional paste gives row i clipboard line i")
        XCTAssertNil(
            harness.textView.blockSelection,
            "the rows no longer share a column, so there is no rectangle left to keep"
        )
        XCTAssertEqual(
            harness.textView.selectedRange(), NSRange(location: 2, length: 0),
            "one caret at the end of the edit applied last — the lowest-located one"
        )
    }

    @MainActor
    func testPastingWithNothingATextRectangleCanTakeDropsTheBlock() {
        let harness = TextViewHarness("a b\nc d")
        NSPasteboard.general.clearContents()
        carets(harness, column: 1, lines: 0...1)

        harness.textView.paste(nil)

        XCTAssertEqual(harness.escaped, "a b⏎c d", "an image clipboard has nothing to distribute across rows")
        XCTAssertNil(harness.textView.blockSelection, "so the block collapses and the ordinary paste path has it")
    }

    // MARK: - Deleting

    @MainActor
    func testBackspaceDeletesOneGraphemePerRow() {
        let harness = TextViewHarness("abc\ndef\nghi")
        carets(harness, column: 2, lines: 0...2)

        harness.textView.deleteBackward(nil)

        XCTAssertEqual(harness.escaped, "ac⏎df⏎gi", "every caret takes the grapheme to its left")
        XCTAssertEqual(
            harness.textView.blockSelection,
            BlockSelection(
                anchor: BlockPosition(line: 0, column: 1), head: BlockPosition(line: 2, column: 1)
            ),
            "the carets move left by the width of what they deleted"
        )
    }

    @MainActor
    func testBackspaceTakesAWholeEmojiPerRow() {
        // Each row holds a non-BMP scalar: a UTF-16-unit-at-a-time backspace
        // would leave a lone surrogate behind.
        let harness = TextViewHarness("a\u{1F44D}\nb\u{1F44D}")
        carets(harness, column: 3, lines: 0...1)

        harness.textView.deleteBackward(nil)

        XCTAssertEqual(harness.escaped, "a⏎b", "backspace takes the whole composed character, not one code unit")
    }

    @MainActor
    func testDeleteForwardDeletesOneGraphemePerRow() {
        let harness = TextViewHarness("abc\ndef\nghi")
        carets(harness, column: 1, lines: 0...2)

        harness.textView.deleteForward(nil)

        XCTAssertEqual(harness.escaped, "ac⏎df⏎gi", "every caret takes the grapheme to its right")
        XCTAssertEqual(
            harness.textView.blockSelection,
            BlockSelection(
                anchor: BlockPosition(line: 0, column: 1), head: BlockPosition(line: 2, column: 1)
            ),
            "a forward delete does not move the carets"
        )
    }

    @MainActor
    func testBackspaceAtColumnZeroChangesNothingAndRegistersNoUndoGroup() {
        let harness = TextViewHarness("abc\ndef")
        harness.textView.undoManager?.removeAllActions()
        carets(harness, column: 0, lines: 0...1)

        harness.textView.deleteBackward(nil)
        // Pending typing is coalesced into an open group; break it so `canUndo`
        // reports what the user would actually be able to press.
        harness.textView.breakUndoCoalescing()

        XCTAssertEqual(
            harness.escaped, "abc⏎def",
            "a caret at column 0 contributes no backspace — joining lines would dissolve the rectangle's rows"
        )
        XCTAssertEqual(
            harness.textView.undoManager?.canUndo, false,
            "a gesture that affected no row must not leave an empty undo group behind"
        )
        XCTAssertNotNil(harness.textView.blockSelection, "and the block survives a gesture that did nothing")
    }

    @MainActor
    func testForwardDeleteAtEndOfLineDoesNotEatTheNewline() {
        let harness = TextViewHarness("ab\ncd")
        carets(harness, column: 2, lines: 0...1)

        harness.textView.deleteForward(nil)

        XCTAssertEqual(
            harness.escaped, "ab⏎cd",
            "a caret at end-of-line contributes no forward delete, so the lines are not joined"
        )
    }

    // MARK: - The drop rules

    @MainActor
    func testReturnDropsTheBlockAndInsertsOneNewline() {
        let harness = TextViewHarness("abc\ndef")
        carets(harness, column: 1, lines: 0...1)

        harness.textView.insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(
            harness.escaped, "abc⏎d⏎ef",
            "Return inserts one newline at the head caret — fanning it out would dissolve the rectangle's rows"
        )
        XCTAssertEqual(
            harness.textView.string.filter { $0 == "\n" }.count, 2,
            "one newline was added, not one per row"
        )
        XCTAssertNil(harness.textView.blockSelection, "and the block is gone")
    }

    @MainActor
    func testTabIsABlockInsert() {
        let harness = TextViewHarness("ab\ncd")
        carets(harness, column: 0, lines: 0...1)

        harness.textView.insertTab(nil)

        XCTAssertEqual(harness.escaped, "\tab⏎\tcd", "Tab fans out like any other character — column indent is the point")
    }

    @MainActor
    func testExternalTextChangeDropsTheBlock() {
        let harness = TextViewHarness("abc\ndef")
        carets(harness, column: 1, lines: 0...1)

        harness.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "x")

        XCTAssertNil(
            harness.textView.blockSelection,
            "a change the block did not make leaves it holding coordinates into the previous text"
        )
    }

    @MainActor
    func testAttributeOnlyEditDoesNotDropTheBlock() {
        // The syntax highlighter re-styles the document on an 80 ms debounce,
        // as a separate attribute-only editing pass. Dropping on it would mean
        // the rectangle disappeared a moment after every block edit.
        let harness = TextViewHarness("abc\ndef")
        carets(harness, column: 1, lines: 0...1)

        harness.textStorage.addAttribute(
            .foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: 3)
        )

        XCTAssertNotNil(
            harness.textView.blockSelection,
            "attributes cannot invalidate a line/column coordinate, so an attribute pass must not drop the block"
        )
    }

    @MainActor
    func testUndoDropsTheBlock() {
        let harness = TextViewHarness("abc\ndef")
        carets(harness, column: 0, lines: 0...1)
        harness.textView.insertText("-", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertNotNil(harness.textView.blockSelection)

        harness.textView.breakUndoCoalescing()
        harness.textView.undoManager?.undo()

        XCTAssertEqual(harness.escaped, "abc⏎def")
        XCTAssertNil(harness.textView.blockSelection, "undo rewrites the text under the block, so the block goes")
    }

    @MainActor
    func testExternalSelectionChangeDropsTheBlock() {
        let harness = TextViewHarness("abc\ndef")
        carets(harness, column: 1, lines: 0...1)

        harness.textView.setSelectedRange(NSRange(location: 2, length: 0))

        XCTAssertNil(harness.textView.blockSelection, "a click or any programmatic selection replaces the block")

        // The multi-range setter is the documented primitive, but the block is
        // dropped through both — pinned here so neither override can be removed
        // on the assumption that the other funnels.
        carets(harness, column: 1, lines: 0...1)
        harness.textView.selectedRanges = [NSValue(range: NSRange(location: 0, length: 3))]

        XCTAssertNil(harness.textView.blockSelection, "the multi-range setter drops it too")
    }

    @MainActor
    func testTheViewsOwnDisplayRefreshDoesNotDropTheBlock() {
        let harness = TextViewHarness("alpha\nbb\ngamma")
        rectangle(harness, columns: 3..<5, lines: 0...2)
        let before = harness.textView.blockSelection

        harness.textView.refreshBlockSelectionDisplay()

        XCTAssertEqual(
            harness.textView.blockSelection, before,
            "the rendering channel must not drop the block it is rendering"
        )
    }

    @MainActor
    func testMarkedTextDropsTheBlock() {
        let harness = TextViewHarness("abc\ndef")
        carets(harness, column: 1, lines: 0...1)

        harness.textView.setMarkedText(
            "\u{0301}", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        XCTAssertNil(
            harness.textView.blockSelection,
            "composition marks only the first of several ranges, so the block cannot survive it"
        )
        harness.textView.unmarkText()
    }

    @MainActor
    func testDropBlockSelectionCollapsesToACaretAtTheHead() {
        let harness = TextViewHarness("alpha\nbeta\ngamma")
        carets(harness, column: 2, lines: 0...2)

        harness.textView.dropBlockSelection()

        XCTAssertNil(harness.textView.blockSelection)
        XCTAssertEqual(
            harness.textView.selectedRange(), NSRange(location: 13, length: 0),
            "the caret lands at the head corner: line 2 (offset 11) column 2"
        )
    }

    // MARK: - Rendering through selectedRanges

    @MainActor
    func testNonEmptyFragmentsBecomeTheSelectedRanges() {
        let harness = TextViewHarness("alpha\nbb\ngamma")
        harness.assertTextKit1()

        rectangle(harness, columns: 3..<5, lines: 0...2)

        XCTAssertEqual(
            harness.textView.selectedRanges.map(\.rangeValue),
            [NSRange(location: 3, length: 2), NSRange(location: 12, length: 2)],
            "AppKit preserves and highlights multiple non-empty ranges, so they are handed to it verbatim — "
                + "the short middle row's zero-length fragment is left out because AppKit would discard it anyway"
        )
    }

    @MainActor
    func testUpdateBlockSelectionMovesTheHeadAndRerenders() {
        // What the ⌥-drag loop calls on every mouse sample.
        let harness = TextViewHarness("alpha\nbravo\ngamma")
        harness.textView.beginBlockSelection(
            anchor: BlockPosition(line: 0, column: 1), head: BlockPosition(line: 0, column: 3)
        )
        XCTAssertEqual(
            harness.textView.selectedRanges.map(\.rangeValue), [NSRange(location: 1, length: 2)]
        )

        harness.textView.updateBlockSelection(head: BlockPosition(line: 2, column: 3))

        XCTAssertEqual(
            harness.textView.blockSelection,
            BlockSelection(
                anchor: BlockPosition(line: 0, column: 1), head: BlockPosition(line: 2, column: 3)
            ),
            "the head moves and the anchor stays put"
        )
        XCTAssertEqual(
            harness.textView.selectedRanges.map(\.rangeValue),
            [
                NSRange(location: 1, length: 2),
                NSRange(location: 7, length: 2),
                NSRange(location: 13, length: 2)
            ],
            "and the grown rectangle is re-rendered, one range per row"
        )
    }

    @MainActor
    func testZeroWidthBlockLeavesASingleEmptySelectedRange() {
        let harness = TextViewHarness("abc\ndef\nghi")

        carets(harness, column: 1, lines: 0...2)

        XCTAssertEqual(
            harness.textView.selectedRanges.map(\.rangeValue),
            [NSRange(location: 9, length: 0)],
            "AppKit collapses multiple empty ranges to one, so a zero-width block shows a single caret at its head "
                + "and the gesture layer draws the other rows itself"
        )
    }

    @MainActor
    func testAppKitDiscardsTheEmptyMembersOfAMixedSelection() {
        // The measurement the design turns on: the block state cannot live in
        // `selectedRanges`, because the fragments a rectangle produces are
        // exactly the ones AppKit throws away.
        let harness = TextViewHarness("alpha\nbb\ngamma")
        harness.assertTextKit1()

        harness.textView.selectedRanges = [
            NSValue(range: NSRange(location: 3, length: 2)),
            NSValue(range: NSRange(location: 8, length: 0)),
            NSValue(range: NSRange(location: 12, length: 2))
        ]

        XCTAssertEqual(
            harness.textView.selectedRanges.map(\.rangeValue),
            [NSRange(location: 3, length: 2), NSRange(location: 12, length: 2)],
            "the zero-length middle range is silently dropped"
        )
    }
}
