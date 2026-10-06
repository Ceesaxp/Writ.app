import XCTest

/// Pure-model cover for rectangular ("block" / "column") selection.
///
/// Every offset, column and length in this model is a UTF-16 code-unit
/// count, because that is what `NSTextView` selection ranges are. The
/// tests therefore deliberately include non-BMP and combining-mark
/// fixtures: a `Character`-counting implementation passes the ASCII
/// cases and then silently corrupts a document containing an emoji.
final class BlockSelectionTests: XCTestCase {

    // MARK: - LineIndex

    func testLineIndexCountsTrailingEmptyLine() {
        let index = LineIndex("a\nb\n")
        XCTAssertEqual(index.lineCount, 3, "a trailing newline opens a real, empty last line — that is what the editor shows")
        XCTAssertEqual(index.lineLength(2), 0, "the trailing empty line has zero length")
    }

    func testLineIndexHandlesEmptyDocument() {
        let index = LineIndex("")
        XCTAssertEqual(index.lineCount, 1, "an empty document is one empty line, not zero lines")
        XCTAssertEqual(index.lineStart(0), 0)
        XCTAssertEqual(index.lineLength(0), 0)
    }

    func testLineLengthExcludesNewline() {
        let index = LineIndex("alpha\nbb")
        XCTAssertEqual(index.lineLength(0), 5, "lineLength must stop before the newline so no fragment can cover a line break")
        XCTAssertEqual(index.lineLength(1), 2)
        XCTAssertEqual(index.lineStart(1), 6, "the second line starts one unit past the newline")
    }

    func testLineIndexCountsUTF16NotCharacters() {
        // "a\u{1F44D}b" is 3 Characters but 4 UTF-16 code units: the thumbs-up
        // sits outside the BMP and is stored as a surrogate pair.
        let emoji = LineIndex("a\u{1F44D}b\nx")
        XCTAssertEqual(emoji.lineLength(0), 4, "a non-BMP scalar is two UTF-16 code units, so this line is 4 units long")
        XCTAssertEqual(emoji.lineStart(1), 5, "the second line starts past the 4 units plus the newline")

        // "e\u{0301}x" is 2 Characters ("é" as e + combining acute, then x)
        // but 3 UTF-16 code units.
        let combining = LineIndex("e\u{0301}x\n\u{4E2D}\u{6587}")
        XCTAssertEqual(combining.lineLength(0), 3, "a combining mark is its own UTF-16 code unit even though it joins one Character")
        XCTAssertEqual(combining.lineLength(1), 2, "BMP CJK ideographs are one UTF-16 code unit each")
    }

    func testOffsetRoundTripsThroughPosition() {
        // Non-BMP content on the first line, so the round trip genuinely
        // exercises UTF-16 arithmetic rather than agreeing by accident.
        let source = "a\u{1F44D}b\nsecond\nthird"
        let index = LineIndex(source)
        for offset in 0...(source.utf16.count) {
            let position = index.position(forUTF16Offset: offset)
            XCTAssertEqual(
                index.utf16Offset(of: position), offset,
                "offset \(offset) should survive the trip through \(position)"
            )
        }
        XCTAssertEqual(index.position(forUTF16Offset: 4), BlockPosition(line: 0, column: 4), "offset 4 is the end of the 4-unit first line")
        XCTAssertEqual(index.position(forUTF16Offset: 5), BlockPosition(line: 1, column: 0), "the unit after the newline opens the second line")
    }

    func testOutOfRangeLineClampsInsteadOfCrashing() {
        let source = "a\nb\n"
        let index = LineIndex(source)
        let utf16Count = source.utf16.count

        XCTAssertEqual(index.lineStart(999), index.lineStart(index.lineCount - 1), "a line past the end clamps to the last line")
        XCTAssertEqual(index.lineLength(-1), index.lineLength(0), "a negative line clamps to the first line")
        XCTAssertEqual(index.lineLength(999), 0, "the clamped last line of a newline-terminated document is empty")
        XCTAssertEqual(
            index.utf16Offset(of: BlockPosition(line: 999, column: 999)), utf16Count,
            "both coordinates clamp, landing at the end of the document instead of trapping"
        )
        XCTAssertEqual(index.utf16Offset(of: BlockPosition(line: -3, column: -7)), 0, "negative coordinates clamp to the document start")
        XCTAssertEqual(index.utf16Offset(of: BlockPosition(line: 0, column: 99)), 1, "a column past the line's end clamps to the line's end, never onto the newline")
        XCTAssertEqual(index.position(forUTF16Offset: -5), BlockPosition(line: 0, column: 0))
        XCTAssertEqual(index.position(forUTF16Offset: 999), BlockPosition(line: 2, column: 0), "an offset past the end clamps to the document end")
    }

    // MARK: - fragmentRanges

    func testFragmentRangesSpanOneRangePerLine() {
        let index = LineIndex(Fixture.ragged)
        let selection = BlockSelection(
            anchor: BlockPosition(line: 0, column: 3),
            head: BlockPosition(line: 2, column: 8)
        )

        let ranges = selection.fragmentRanges(in: index)

        XCTAssertEqual(ranges.count, 3, "a three-line block yields exactly one range per line")
        XCTAssertEqual(ranges, [NSRange(location: 3, length: 5), NSRange(location: 12, length: 0), NSRange(location: 16, length: 5)])
        XCTAssertEqual(ranges.map(\.location), ranges.map(\.location).sorted(), "fragments come back ascending by line")
    }

    func testFragmentRangeClampsToShortLine() {
        let index = LineIndex(Fixture.ragged)
        let selection = BlockSelection(
            anchor: BlockPosition(line: 0, column: 3),
            head: BlockPosition(line: 2, column: 8)
        )

        let shortRow = selection.fragmentRanges(in: index)[1]

        XCTAssertEqual(shortRow.length, 0, "a line too short to reach the block's left edge contributes nothing")
        XCTAssertEqual(
            shortRow.location, index.lineStart(1) + index.lineLength(1),
            "the empty fragment sits at the short line's end — the model clamps, it never pads with spaces"
        )
    }

    func testZeroWidthBlockYieldsEmptyRangesOnEveryLine() {
        let index = LineIndex(Fixture.ragged)
        let selection = BlockSelection(
            anchor: BlockPosition(line: 0, column: 0),
            head: BlockPosition(line: 2, column: 0)
        )

        let ranges = selection.fragmentRanges(in: index)

        XCTAssertTrue(selection.isZeroWidth, "equal anchor and head columns is a zero-width block, the primary list-prefix case")
        XCTAssertEqual(ranges, [NSRange(location: 0, length: 0), NSRange(location: 10, length: 0), NSRange(location: 13, length: 0)])
    }

    func testFragmentRangesNeverIncludeNewline() {
        let source = Fixture.ragged
        let index = LineIndex(source)
        // Deliberately overhang every line to the right.
        let selection = BlockSelection(
            anchor: BlockPosition(line: 0, column: 0),
            head: BlockPosition(line: 3, column: 99)
        )

        for range in selection.fragmentRanges(in: index) {
            let text = (source as NSString).substring(with: range)
            XCTAssertFalse(text.contains("\n"), "fragment \(range) covered a line break: \(text.debugDescription)")
        }
    }

    func testFragmentRangesNormaliseReversedDrag() {
        let index = LineIndex(Fixture.ragged)
        let forward = BlockSelection(
            anchor: BlockPosition(line: 0, column: 3),
            head: BlockPosition(line: 2, column: 8)
        )
        let draggedUpAndLeft = BlockSelection(
            anchor: BlockPosition(line: 2, column: 8),
            head: BlockPosition(line: 0, column: 3)
        )

        XCTAssertEqual(
            draggedUpAndLeft.fragmentRanges(in: index), forward.fragmentRanges(in: index),
            "a block is defined by its corners, so dragging up-and-left selects the same rectangle"
        )
        XCTAssertEqual(draggedUpAndLeft.lineRange, 0...2)
        XCTAssertEqual(draggedUpAndLeft.columnRange, 3..<8)
    }

    // MARK: - Grapheme snapping

    func testFragmentRangeSnapsOutwardOverSurrogatePair() {
        // Line 0 is "a👍b": 4 UTF-16 units, the thumbs-up occupying 1...2.
        // Column 2 is therefore a valid boundary on line 1 and the middle of
        // a surrogate pair on line 0 — the hazard a rectangle creates.
        let source = "a\u{1F44D}b\nxyzw"
        let index = LineIndex(source)
        let selection = BlockSelection(
            anchor: BlockPosition(line: 0, column: 0),
            head: BlockPosition(line: 1, column: 2)
        )

        let ranges = selection.fragmentRanges(in: index)

        XCTAssertEqual(
            ranges, [NSRange(location: 0, length: 3), NSRange(location: 5, length: 2)],
            "the right edge landed between the surrogates, so the row widens to take the whole emoji"
        )

        let copied = selection.copyString(in: index)

        XCTAssertEqual(copied, "a\u{1F44D}\nxy", "the copied rectangle contains the whole emoji, not half of one")
        XCTAssertFalse(copied.contains("\u{FFFD}"), "a split pair would surface as a replacement character once bridged back to String")
        XCTAssertFalse(
            copied.unicodeScalars.contains { (0xD800...0xDFFF).contains($0.value) },
            "no lone surrogate may reach the pasteboard"
        )
        XCTAssertEqual(
            String(decoding: Data(copied.utf8), as: UTF8.self), copied,
            "the copied string round-trips through UTF-8 losslessly"
        )
    }

    func testFragmentRangeSnapsOutwardOverCombiningSequence() {
        // Line 0 is "éx" written as e + combining acute + x: units e(0),
        // U+0301(1), x(2). Columns 1 and 2 both sit inside the "é".
        let source = "e\u{0301}x\nabc"
        let index = LineIndex(source)

        let rightEdgeInsideTheSequence = BlockSelection(
            anchor: BlockPosition(line: 0, column: 0),
            head: BlockPosition(line: 1, column: 1)
        )
        XCTAssertEqual(
            rightEdgeInsideTheSequence.fragmentRanges(in: index),
            [NSRange(location: 0, length: 2), NSRange(location: 4, length: 1)],
            "a right edge between the e and its combining acute takes the whole é"
        )
        XCTAssertEqual(rightEdgeInsideTheSequence.copyString(in: index), "e\u{0301}\na")

        let leftEdgeInsideTheSequence = BlockSelection(
            anchor: BlockPosition(line: 0, column: 1),
            head: BlockPosition(line: 1, column: 3)
        )
        XCTAssertEqual(
            leftEdgeInsideTheSequence.fragmentRanges(in: index)[0],
            NSRange(location: 0, length: 3),
            "a left edge inside the sequence widens leftward too — outward, never inward"
        )
    }

    func testSnappingNeverCrossesTheLineBreak() {
        // Line 0 ends in a surrogate pair and line 1 ends in a combining
        // mark, so a right edge at end-of-line sits against a \n on both the
        // non-BMP and the combining case. Line 2 opens straight after a
        // combining mark, so a left edge at column 0 could only reach the
        // previous line by widening backwards over the newline.
        let source = "ab\u{1F44D}\nq\u{0301}\nzz"
        let index = LineIndex(source)
        let text = source as NSString

        for (left, right) in [(0, 1), (0, 2), (0, 4), (1, 4), (2, 3), (0, 99), (3, 99)] {
            let selection = BlockSelection(
                anchor: BlockPosition(line: 0, column: left),
                head: BlockPosition(line: 2, column: right)
            )
            let ranges = selection.fragmentRanges(in: index)

            for (line, range) in zip(0..., ranges) {
                let start = index.lineStart(line)
                let end = start + index.lineLength(line)
                XCTAssertGreaterThanOrEqual(range.location, start, "columns \(left)..<\(right) row \(line): \(range) widened back into the previous line")
                XCTAssertLessThanOrEqual(range.location + range.length, end, "columns \(left)..<\(right) row \(line): \(range) widened past the line's last unit")
                XCTAssertFalse(
                    text.substring(with: range).contains("\n"),
                    "columns \(left)..<\(right) row \(line): \(range) covered a line break"
                )
            }
        }
    }

    func testSnappingIsIdempotent() {
        let source = "a\u{1F44D}b\ne\u{0301}x\nplain"
        let index = LineIndex(source)
        let text = source as NSString

        for (left, right) in [(0, 2), (1, 2), (1, 3), (2, 4), (0, 99)] {
            let selection = BlockSelection(
                anchor: BlockPosition(line: 0, column: left),
                head: BlockPosition(line: 2, column: right)
            )

            for range in selection.fragmentRanges(in: index) {
                XCTAssertEqual(
                    text.rangeOfComposedCharacterSequences(for: range), range,
                    "columns \(left)..<\(right): \(range) is already whole, so snapping it again must change nothing"
                )
            }
        }
    }

    func testZeroWidthBlockStaysZeroWidthInsideAGrapheme() {
        // Column 2 is the middle of the thumbs-up on line 0 and an ordinary
        // boundary on line 1. Widening the carets would turn typing into
        // overwriting on one row and not the other.
        let source = "a\u{1F44D}b\nxyzw"
        let index = LineIndex(source)
        let selection = BlockSelection(
            anchor: BlockPosition(line: 0, column: 2),
            head: BlockPosition(line: 1, column: 2)
        )

        let ranges = selection.fragmentRanges(in: index)

        XCTAssertTrue(selection.isZeroWidth)
        XCTAssertEqual(
            ranges, [NSRange(location: 2, length: 0), NSRange(location: 7, length: 0)],
            "a caret inside a grapheme stays a caret — snapping it would make N carets into N overwrites"
        )
        XCTAssertTrue(
            ranges.allSatisfy { $0.length == 0 },
            "every row of a zero-width block is an insertion point, including the one mid-pair"
        )
    }

    // MARK: - copyString

    func testCopyStringJoinsFragmentsWithNewlines() {
        let source = "one two\nthree four\nfive six"
        let index = LineIndex(source)
        let selection = BlockSelection(
            anchor: BlockPosition(line: 0, column: 0),
            head: BlockPosition(line: 2, column: 4)
        )

        XCTAssertEqual(
            selection.copyString(in: index), "one \nthre\nfive",
            "Cmd-C on a block puts the rectangle on the pasteboard, one row per line"
        )
    }

    func testCopyStringEmitsEmptyLineForShortRow() {
        let source = Fixture.ragged
        let index = LineIndex(source)
        let selection = BlockSelection(
            anchor: BlockPosition(line: 0, column: 3),
            head: BlockPosition(line: 2, column: 8)
        )

        let copied = selection.copyString(in: index)

        XCTAssertEqual(copied, "ha on\n\nma th", "the short row contributes an empty string, not a dropped row")
        XCTAssertEqual(copied.filter { $0 == "\n" }.count, 2, "three rows keep two newlines so the rectangle's shape survives a round trip")
    }

    // MARK: - replacementEdits

    func testReplacementEditsAreSortedDescendingByLocation() {
        let index = LineIndex(Fixture.ragged)
        let selection = BlockSelection(
            anchor: BlockPosition(line: 0, column: 3),
            head: BlockPosition(line: 2, column: 8)
        )

        let edits = selection.replacementEdits(with: "X", in: index)

        XCTAssertEqual(edits.count, 3)
        XCTAssertEqual(
            edits.map(\.range.location), [16, 12, 3],
            "edits come back bottom-up so applying them in order leaves the not-yet-applied offsets valid"
        )
        XCTAssertEqual(Set(edits.map(\.replacement)), ["X"])
    }

    func testApplyingDescendingEditsProducesExpectedDocument() {
        let source = "one\ntwo\nthree"
        let index = LineIndex(source)

        let listPrefix = BlockSelection(
            anchor: BlockPosition(line: 0, column: 0),
            head: BlockPosition(line: 2, column: 0)
        )
        XCTAssertEqual(
            apply(listPrefix.replacementEdits(with: "- ", in: index), to: source),
            "- one\n- two\n- three",
            "a zero-width column at 0 plus `- ` is the make-these-lines-a-list case"
        )

        let twoWide = BlockSelection(
            anchor: BlockPosition(line: 0, column: 1),
            head: BlockPosition(line: 2, column: 3)
        )
        XCTAssertEqual(
            apply(twoWide.replacementEdits(with: "XX", in: index), to: source),
            "oXX\ntXX\ntXXee",
            "a two-column-wide block is overwritten row by row, leaving the rest of each line alone"
        )

        XCTAssertEqual(
            apply(twoWide.replacementEdits(with: "", in: index), to: source),
            "o\nt\ntee",
            "deleting a block removes the rectangle and nothing else"
        )
    }

    func testDeletingZeroWidthBlockIsANoOp() {
        let source = Fixture.ragged
        let index = LineIndex(source)
        let selection = BlockSelection(
            anchor: BlockPosition(line: 0, column: 4),
            head: BlockPosition(line: 3, column: 4)
        )

        let edits = selection.replacementEdits(with: "", in: index)

        XCTAssertTrue(edits.allSatisfy { $0.range.length == 0 }, "a zero-width block has nothing to remove on any row")
        XCTAssertEqual(apply(edits, to: source), source, "deleting a zero-width block must leave the document untouched")
    }

    // MARK: - pasteEdits

    func testSingleClipboardLineRepeatsAcrossEveryRow() {
        let source = "one\ntwo\nthree"
        let index = LineIndex(source)
        let selection = BlockSelection(
            anchor: BlockPosition(line: 0, column: 0),
            head: BlockPosition(line: 2, column: 0)
        )

        let edits = selection.pasteEdits(clipboard: "| ", in: index)

        XCTAssertEqual(edits.count, 3, "one clipboard line goes onto every row — the table-pipe case")
        XCTAssertEqual(apply(edits, to: source), "| one\n| two\n| three")
    }

    func testMatchingLineCountsPastePositionally() {
        let source = "one\ntwo\nthree"
        let index = LineIndex(source)
        let selection = BlockSelection(
            anchor: BlockPosition(line: 0, column: 0),
            head: BlockPosition(line: 2, column: 0)
        )

        let edits = selection.pasteEdits(clipboard: "1. \n2. \n3. ", in: index)

        XCTAssertEqual(edits.count, 3)
        XCTAssertEqual(
            edits.map(\.range.location), [8, 4, 0],
            "the positional path owes the same descending-order contract — the applied document alone would not catch a mis-zipped order here"
        )
        XCTAssertEqual(
            apply(edits, to: source), "1. one\n2. two\n3. three",
            "as many clipboard lines as block rows pastes row for row, top to bottom"
        )
    }

    func testMismatchedLineCountsFallBackToContiguousReplacement() {
        let source = "one\ntwo\nthree"
        let index = LineIndex(source)
        let selection = BlockSelection(
            anchor: BlockPosition(line: 0, column: 1),
            head: BlockPosition(line: 2, column: 2)
        )

        let edits = selection.pasteEdits(clipboard: "A\nB", in: index)

        XCTAssertEqual(
            edits, [BlockEdit(range: NSRange(location: 1, length: 9), replacement: "A\nB")],
            "two clipboard lines into a three-row block is not a block paste: replace the whole span verbatim "
                + "rather than silently dropping or duplicating a line"
        )
        XCTAssertEqual(apply(edits, to: source), "oA\nBree")
    }

    func testClipboardTrailingNewlineIsDiscardedOnce() {
        let source = "one\ntwo\nthree"
        let index = LineIndex(source)
        let selection = BlockSelection(
            anchor: BlockPosition(line: 0, column: 0),
            head: BlockPosition(line: 2, column: 0)
        )

        XCTAssertEqual(
            apply(selection.pasteEdits(clipboard: "| \n", in: index), to: source), "| one\n| two\n| three",
            "a copy that ended with a newline is still one line, so it repeats across the rows"
        )
        XCTAssertEqual(
            apply(selection.pasteEdits(clipboard: "1. \n2. \n3. \n", in: index), to: source), "1. one\n2. two\n3. three",
            "exactly one trailing newline is discarded, so this is three lines and pastes positionally"
        )

        // Only one newline is discarded: a second one is a real empty line,
        // which makes this a two-line clipboard and therefore a mismatch.
        let twoLines = selection.pasteEdits(clipboard: "| \n\n", in: index)
        XCTAssertEqual(twoLines.count, 1, "`| \\n\\n` is two lines against three rows, so it falls back to a contiguous replacement")
        XCTAssertEqual(twoLines[0].replacement, "| \n\n", "the fallback pastes the clipboard verbatim, trailing newline included")
    }

    // MARK: - Fixtures and helpers

    private enum Fixture {
        /// Line lengths 9, 2, 16, 0 — line starts 0, 10, 13, 30. The short
        /// `bb` row is what makes the clamp-don't-pad rule observable.
        static let ragged = "alpha one\nbb\ngamma three long\n"
    }

    /// Apply edits **in the order given** — which is the descending-order
    /// contract under test. Applying them in any other order would shift
    /// the offsets of the edits that have not run yet.
    private func apply(_ edits: [BlockEdit], to source: String) -> String {
        let document = NSMutableString(string: source)
        for edit in edits {
            document.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return document as String
    }
}
