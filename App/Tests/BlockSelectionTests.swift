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

    /// Corruption has to be asserted on the scalar view or on the exact
    /// expected value; the obvious-looking guards do not work.
    ///
    /// This test used to carry four checks, three of which could not fail,
    /// and they are recorded here so nobody adds them back. Measured:
    ///
    ///  - `contains("\u{FFFD}")` answers **false** on a string that
    ///    demonstrably holds U+FFFD. That overload is `range(of:)`, whose
    ///    search follows Foundation's own reckoning of the original UTF-16
    ///    rather than the repaired scalar view. `firstIndex(of:)` and
    ///    `unicodeScalars.contains { $0.value == 0xFFFD }` both answer true.
    ///    The same defect applies to `contains("\n")` — see
    ///    `testNonEmptyFragmentNeverSwallowsTheNewline`.
    ///  - a lone-surrogate scan over `unicodeScalars` can **never** fire:
    ///    `Unicode.Scalar` cannot hold a surrogate, so Swift has already
    ///    repaired any to U+FFFD by the time the scan runs.
    ///  - a `Data(utf8)` → `String(decoding:as:)` round trip passes on an
    ///    already-repaired string, so it re-encodes cleanly either way.
    ///
    /// What is left bites: the fragment ranges, the copied string, and the
    /// edited document, each as an exact value, plus the scalar-value
    /// U+FFFD scan. Each was confirmed red by reverting the non-empty snap
    /// to the identity.
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
        XCTAssertFalse(
            copied.unicodeScalars.contains { $0.value == 0xFFFD },
            "a split pair surfaces as a replacement character once bridged back to String: " + copied.debugDescription
        )

        // The same rectangle applied to the document, not just read off it:
        // a right edge left between the surrogates would delete one half of
        // the pair and strand the other in the text.
        let deleted = apply(selection.replacementEdits(with: "", in: index), to: source)

        XCTAssertEqual(deleted, "b\nzw", "deleting the rectangle removes the whole emoji and leaves the rest of each row")
        XCTAssertFalse(
            deleted.unicodeScalars.contains { $0.value == 0xFFFD },
            "deleting half a surrogate pair strands the other half: " + deleted.debugDescription
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
        // non-BMP and the combining case. Note what this fixture does NOT
        // reach: its combining mark sits after `q`, mid-line, and Foundation
        // joins a newline only to marks that *follow* it. So no left edge
        // here can widen backwards over a newline — this suite was green at
        // 50 tests with exactly that bug present. That case belongs to
        // `testNonEmptyFragmentNeverSwallowsTheNewline`, whose fixture opens
        // a line with the mark.
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
                // `.utf16.contains(0x0A)`, not `contains("\n")`: the String
                // overload of `contains` resolves to Foundation's range(of:)
                // and answers false on "\n\u{0301}", whose first Character
                // *is* a newline.
                XCTAssertFalse(
                    text.substring(with: range).utf16.contains(0x0A),
                    "columns \(left)..<\(right) row \(line): \(range) covered a line break"
                )
            }
        }
    }

    /// The non-empty twin of `testZeroWidthCaretSnapDoesNotLeaveItsOwnLine`.
    ///
    /// `testSnappingNeverCrossesTheLineBreak` does not reach this case: its
    /// fixture's second and third lines open with ordinary characters, and a
    /// combining mark at the *end* of a line is harmless — Foundation joins a
    /// `\n` to the marks that **follow** it, not the ones before it. So the
    /// fixture here has to open a line with a mark.
    func testNonEmptyFragmentNeverSwallowsTheNewline() {
        // Line 1 is "\u{0301}y", and measured:
        // ("x\n\u{0301}y\nzz" as NSString).rangeOfComposedCharacterSequences(
        // for: {2, 1}) answers {1, 2} — a range that starts on line 0's
        // newline. So a non-empty fragment at column 0 of line 1 widens
        // backwards out of its own row unless the snap clamps it.
        let source = "x\n\u{0301}y\nzz"
        let index = LineIndex(source)
        let selection = BlockSelection(
            anchor: BlockPosition(line: 0, column: 0),
            head: BlockPosition(line: 2, column: 1)
        )

        let ranges = selection.fragmentRanges(in: index)

        XCTAssertEqual(
            ranges, [NSRange(location: 0, length: 1), NSRange(location: 2, length: 1), NSRange(location: 5, length: 1)],
            "row 1's fragment clamps to its own line start instead of widening over the previous line's newline"
        )

        // The hazard is any left edge that lands *inside* the sequence
        // Foundation reports for the newline, not only column 0: on
        // "ab\n\u{0301}\u{0302}y" the fragment {4, 1} — column 1 of line 1 —
        // widens to {2, 3} and also starts on the newline.
        for source in [source, "ab\n\u{0301}\u{0302}y"] {
            let index = LineIndex(source)
            let text = source as NSString
            for (left, right) in [(0, 1), (0, 2), (0, 3), (1, 2), (1, 3), (2, 3), (0, 99), (1, 99)] {
                let selection = BlockSelection(
                    anchor: BlockPosition(line: 0, column: left),
                    head: BlockPosition(line: index.lineCount - 1, column: right)
                )

                for (line, range) in zip(0..., selection.fragmentRanges(in: index)) {
                    let start = index.lineStart(line)
                    let end = start + index.lineLength(line)
                    let where_ = "\(source.debugDescription) columns \(left)..<\(right) row \(line): \(range)"

                    XCTAssertGreaterThanOrEqual(range.location, start, "\(where_) widened back into the previous line")
                    XCTAssertLessThanOrEqual(range.location + range.length, end, "\(where_) widened past its line's last unit")
                    // Scanned over UTF-16 rather than written
                    // `contains("\n")`, which has no teeth on exactly the
                    // strings this test produces. Measured: the unfixed
                    // fragment {1, 2} here substrings to "\n\u{0301}", whose
                    // *first Character is* "\n" — and yet `contains("\n")`
                    // (the StringProtocol overload, i.e. `range(of:)`)
                    // answers false, because Foundation's search follows
                    // NSString's reckoning, in which that newline is part of
                    // a composed character sequence. `contains("\n" as
                    // Character)` and `firstIndex(of:)` both answer true.
                    XCTAssertFalse(
                        text.substring(with: range).utf16.contains(0x0A),
                        "\(where_) covered a line break"
                    )
                }
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

    func testZeroWidthCaretSnapsToGraphemeStartAndStaysZeroWidth() {
        // Column 2 is the middle of the thumbs-up on line 0 and an ordinary
        // boundary on line 1.
        //
        // This test was testZeroWidthBlockStaysZeroWidthInsideAGrapheme and
        // asserted the carets came back at {2, 0} and {7, 0} — that the
        // mid-pair caret did not move at all. Half of that was right and
        // half was wrong. The *length* must stay 0, or N carets become N
        // overwrites. But leaving the *location* between the two surrogates
        // means typing there splits the pair, which
        // testTypingIntoACaretInsideAGraphemeDoesNotCorruptTheDocument
        // demonstrates on the document. So row 0's caret snaps 2 -> 1.
        let source = "a\u{1F44D}b\nxyzw"
        let index = LineIndex(source)
        let selection = BlockSelection(
            anchor: BlockPosition(line: 0, column: 2),
            head: BlockPosition(line: 1, column: 2)
        )

        let ranges = selection.fragmentRanges(in: index)

        XCTAssertTrue(selection.isZeroWidth)
        XCTAssertEqual(
            ranges, [NSRange(location: 1, length: 0), NSRange(location: 7, length: 0)],
            "the mid-pair caret snaps back to the emoji's leading boundary; the row that was already on a boundary does not move"
        )
        XCTAssertTrue(
            ranges.allSatisfy { $0.length == 0 },
            "every row of a zero-width block stays an insertion point — the snap moves carets, it never widens them"
        )
    }

    func testZeroWidthCaretSnapsOutOfCombiningSequence() {
        // Line 0 is "éx" as e + combining acute + x, so column 1 sits
        // between the base character and its mark.
        let source = "e\u{0301}x\nabc"
        let index = LineIndex(source)
        let selection = BlockSelection(
            anchor: BlockPosition(line: 0, column: 1),
            head: BlockPosition(line: 1, column: 1)
        )

        XCTAssertEqual(
            selection.fragmentRanges(in: index),
            [NSRange(location: 0, length: 0), NSRange(location: 5, length: 0)],
            "a caret between a base character and its combining mark snaps back to the base"
        )
    }

    func testZeroWidthCaretSnapDoesNotLeaveItsOwnLine() {
        // Pathological but reachable: line 1 opens with two combining marks,
        // and Foundation joins a newline to the marks that follow it —
        // rangeOfComposedCharacterSequence(at: 3) here is {1, 3}, which
        // starts on line 0's newline. The snap is bounded by the row's own
        // line start precisely so one row cannot step out of the rectangle.
        let source = "x\n\u{0301}\u{0302}y\nzz"
        let index = LineIndex(source)
        let selection = BlockSelection(
            anchor: BlockPosition(line: 0, column: 1),
            head: BlockPosition(line: 2, column: 1)
        )

        let ranges = selection.fragmentRanges(in: index)

        XCTAssertEqual(
            ranges, [NSRange(location: 1, length: 0), NSRange(location: 2, length: 0), NSRange(location: 7, length: 0)],
            "row 1's caret clamps to its own line start instead of snapping onto the previous line's newline"
        )
        for (line, range) in zip(0..., ranges) {
            XCTAssertGreaterThanOrEqual(range.location, index.lineStart(line), "row \(line): \(range) snapped out of its line")
            XCTAssertLessThanOrEqual(
                range.location, index.lineStart(line) + index.lineLength(line),
                "row \(line): \(range) snapped past its line's last unit"
            )
        }
    }

    func testZeroWidthCaretOnBoundaryDoesNotMove() {
        let plain = LineIndex("one\ntwo\nthree")
        let plainCarets = BlockSelection(
            anchor: BlockPosition(line: 0, column: 2),
            head: BlockPosition(line: 2, column: 2)
        )
        XCTAssertEqual(
            plainCarets.fragmentRanges(in: plain),
            [NSRange(location: 2, length: 0), NSRange(location: 6, length: 0), NSRange(location: 10, length: 0)],
            "nothing in plain text sits inside a grapheme, so no caret may move"
        )

        // Column 1 is the thumbs-up's *leading* boundary on line 0 and an
        // ordinary one on line 1: already the answer the snap would give.
        let emoji = LineIndex("a\u{1F44D}b\nxyzw")
        let onLeadingBoundary = BlockSelection(
            anchor: BlockPosition(line: 0, column: 1),
            head: BlockPosition(line: 1, column: 1)
        )
        XCTAssertEqual(
            onLeadingBoundary.fragmentRanges(in: emoji),
            [NSRange(location: 1, length: 0), NSRange(location: 6, length: 0)],
            "a caret already at a grapheme start stays exactly where it is"
        )

        // Column 3 is the trailing boundary of the same emoji — the start of
        // the next grapheme, so it must not be dragged back over the emoji.
        let afterTheEmoji = BlockSelection(
            anchor: BlockPosition(line: 0, column: 3),
            head: BlockPosition(line: 1, column: 3)
        )
        XCTAssertEqual(
            afterTheEmoji.fragmentRanges(in: emoji)[0], NSRange(location: 3, length: 0),
            "a caret just past a multi-unit grapheme is on the next grapheme's start, not inside the previous one"
        )
    }

    func testZeroWidthCaretAtEndOfLineDoesNotMove() {
        // Line 0 ends in a surrogate pair, so a caret at its end has a
        // multi-unit grapheme behind it; line 1 ends at the end of the
        // document, which is the offset rangeOfComposedCharacterSequence(at:)
        // treats as out of range.
        let source = "ab\u{1F44D}\nzz"
        let index = LineIndex(source)
        let selection = BlockSelection(
            anchor: BlockPosition(line: 0, column: 99),
            head: BlockPosition(line: 1, column: 99)
        )

        let ranges = selection.fragmentRanges(in: index)

        XCTAssertEqual(
            ranges, [NSRange(location: 4, length: 0), NSRange(location: 7, length: 0)],
            "an end-of-line caret is already on a boundary and must not be pulled back into the emoji, "
                + "and the end-of-document caret must survive the guard rather than trapping"
        )
    }

    func testCaretSnapIsIdempotent() {
        // Checked through the public path, not the raw NSString call: where
        // the snap clamps to a line start, re-asking Foundation would still
        // answer with the previous line's offset, and only the model's own
        // bound makes the operation stable.
        for source in ["a\u{1F44D}b\nxyzw", "e\u{0301}x\nabc", "x\n\u{0301}\u{0302}y\nzz", "plain\ntext"] {
            let index = LineIndex(source)
            for column in 0...6 {
                let block = BlockSelection(
                    anchor: BlockPosition(line: 0, column: column),
                    head: BlockPosition(line: index.lineCount - 1, column: column)
                )

                for (line, caret) in zip(0..., block.fragmentRanges(in: index)) {
                    let snappedColumn = caret.location - index.lineStart(line)
                    let resnapped = BlockSelection(
                        anchor: BlockPosition(line: line, column: snappedColumn),
                        head: BlockPosition(line: line, column: snappedColumn)
                    )
                    XCTAssertEqual(
                        resnapped.fragmentRanges(in: index), [caret],
                        "\(source.debugDescription) column \(column) row \(line): snapping \(caret) a second time moved it"
                    )
                }
            }
        }
    }

    /// The bug the leading-boundary snap exists for.
    ///
    /// Caret at column 2 of `xyzw`, then ⌥⇧↑ into `a👍b`: one rectangle,
    /// column 2 on both rows, and on row 0 column 2 falls *between* the two
    /// UTF-16 units of the thumbs-up. Inserting there writes the typed text
    /// between a high and a low surrogate and leaves two lone surrogates in
    /// the document.
    ///
    /// The corruption has to be detected through `unicodeScalars`. Measured:
    /// a `String` that came from an `NSMutableString` holding lone surrogates
    /// shows `U+FFFD` in its scalar view and compares equal to the literal
    /// with those scalars, yet `contains("\u{FFFD}")` on it answers **false**
    /// — most likely because that overload is Foundation's `range(of:)`,
    /// searching the original UTF-16 where no `U+FFFD` exists. The mechanism
    /// is inferred; the behaviour is measured, as is `firstIndex(of:)`
    /// answering **true** on the same string. The UTF-8 round trip is
    /// weaker still: the scalar view is already repaired, so it re-encodes
    /// cleanly either way. Both are asserted below because they are cheap,
    /// but the scalar scan and the exact document are the assertions with
    /// teeth.
    func testTypingIntoACaretInsideAGraphemeDoesNotCorruptTheDocument() {
        let source = "a\u{1F44D}b\nxyzw"
        let index = LineIndex(source)
        let selection = BlockSelection(
            anchor: BlockPosition(line: 0, column: 2),
            head: BlockPosition(line: 1, column: 2)
        )

        let typed = apply(selection.replacementEdits(with: "-", in: index), to: source)

        XCTAssertFalse(
            typed.unicodeScalars.contains { $0.value == 0xFFFD },
            "typing into a caret inside the surrogate pair split it, leaving replacement characters: "
                + typed.debugDescription
        )
        XCTAssertFalse(typed.contains("\u{FFFD}"), "no replacement character may survive in the document")
        XCTAssertEqual(
            String(decoding: Data(typed.utf8), as: UTF8.self), typed,
            "the edited document must round-trip through UTF-8 losslessly"
        )
        XCTAssertEqual(
            typed, "a-\u{1F44D}b\nxy-zw",
            "row 0's caret snaps back to the emoji's leading boundary, so the text lands before the whole emoji"
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

    // MARK: - backspaceEdits / forwardDeleteEdits

    func testBackspaceOnZeroWidthBlockDeletesOneGraphemePerRow() {
        let source = "one\ntwo\nthree"
        let index = LineIndex(source)
        let selection = BlockSelection(
            anchor: BlockPosition(line: 0, column: 1),
            head: BlockPosition(line: 2, column: 1)
        )

        let edits = selection.backspaceEdits(in: index)

        XCTAssertEqual(edits.count, 3, "three carets, three deletions")
        XCTAssertEqual(edits.map(\.range), [NSRange(location: 8, length: 1), NSRange(location: 4, length: 1), NSRange(location: 0, length: 1)])
        XCTAssertEqual(Set(edits.map(\.replacement)), [""], "a deletion replaces with nothing")
        XCTAssertEqual(apply(edits, to: source), "ne\nwo\nhree", "each row loses the one character to the left of its caret")
    }

    func testForwardDeleteOnZeroWidthBlockDeletesOneGraphemePerRow() {
        // Row 0's caret sits on the thumbs-up's leading boundary, so the
        // grapheme to its right is two UTF-16 units wide.
        let source = "a\u{1F44D}b\nxyzw"
        let index = LineIndex(source)
        let selection = BlockSelection(
            anchor: BlockPosition(line: 0, column: 1),
            head: BlockPosition(line: 1, column: 1)
        )

        let edits = selection.forwardDeleteEdits(in: index)

        XCTAssertEqual(
            edits.map(\.range), [NSRange(location: 6, length: 1), NSRange(location: 1, length: 2)],
            "each row deletes the whole grapheme to the right of its caret, which is two units wide on row 0"
        )
        let deleted = apply(edits, to: source)
        XCTAssertEqual(deleted, "ab\nxzw")
        XCTAssertFalse(
            deleted.unicodeScalars.contains { $0.value == 0xFFFD },
            "deleting half a surrogate pair would leave a replacement character: " + deleted.debugDescription
        )
    }

    func testBackspaceOnNonEmptyBlockDeletesTheSelection() {
        // The ordinary case: every row has text inside the block, so no row
        // is a no-op and the delete paths are exactly "delete the selection".
        let source = "one\ntwo\nthree"
        let index = LineIndex(source)
        let selection = BlockSelection(
            anchor: BlockPosition(line: 0, column: 1),
            head: BlockPosition(line: 2, column: 3)
        )

        let deleteTheSelection = selection.replacementEdits(with: "", in: index)

        XCTAssertTrue(
            deleteTheSelection.allSatisfy { $0.range.length > 0 },
            "the fixture's point is that every row genuinely has something to delete — otherwise the equality below is vacuous"
        )
        XCTAssertEqual(
            selection.backspaceEdits(in: index), deleteTheSelection,
            "with a rectangle selected, Backspace deletes the rectangle — the direction of the key is irrelevant"
        )
        XCTAssertEqual(
            selection.forwardDeleteEdits(in: index), deleteTheSelection,
            "and so does Forward Delete, identically"
        )
        XCTAssertEqual(apply(selection.backspaceEdits(in: index), to: source), "o\nt\ntee")

        // The limit of that equality, and the subtle part of the file: a row
        // whose fragment clamped to nothing is dropped from the delete paths
        // and kept by `replacementEdits`. `Fixture.ragged`'s `bb` row is
        // shorter than the block's left edge, so the two diverge by one edit.
        let ragged = LineIndex(Fixture.ragged)
        let overhangsTheShortRow = BlockSelection(
            anchor: BlockPosition(line: 0, column: 3),
            head: BlockPosition(line: 2, column: 8)
        )

        XCTAssertEqual(
            overhangsTheShortRow.replacementEdits(with: "", in: ragged).count, 3,
            "replacementEdits keeps one edit per row, including the row whose fragment clamped to zero length"
        )
        XCTAssertEqual(
            overhangsTheShortRow.backspaceEdits(in: ragged).map(\.range),
            [NSRange(location: 16, length: 5), NSRange(location: 3, length: 5)],
            "the short `bb` row contributes no edit at all, so Backspace is *not* identical to replacementEdits here"
        )
        XCTAssertEqual(
            overhangsTheShortRow.forwardDeleteEdits(in: ragged),
            overhangsTheShortRow.backspaceEdits(in: ragged),
            "both delete paths filter the same way"
        )
    }

    func testDeletingABlockThatOverhangsEveryRowReturnsNoEdits() {
        // Columns 5..<8 against two 2-unit lines. The block is three columns
        // wide, so this is the *non-empty* delete path — but every row is
        // shorter than the block's left edge, so every fragment clamps to a
        // zero-length range at its row's end. Two edits replacing nothing
        // with nothing is precisely the empty undo group the no-op rule
        // exists to prevent: the user presses ⌘Z and nothing visible happens.
        let source = "ab\ncd"
        let index = LineIndex(source)
        let selection = BlockSelection(
            anchor: BlockPosition(line: 0, column: 5),
            head: BlockPosition(line: 1, column: 8)
        )

        XCTAssertFalse(selection.isZeroWidth, "a three-column block takes the non-empty branch, not the caret branch")
        XCTAssertEqual(
            selection.fragmentRanges(in: index),
            [NSRange(location: 2, length: 0), NSRange(location: 5, length: 0)],
            "clamp-don't-pad leaves every row with a zero-length fragment at its end"
        )

        XCTAssertEqual(selection.backspaceEdits(in: index), [], "no row has anything to delete, so the whole gesture is empty")
        XCTAssertEqual(selection.forwardDeleteEdits(in: index), [], "and Forward Delete answers identically")

        // The asymmetry, asserted rather than only commented: only the
        // *combination* of a zero-length range and an empty replacement is a
        // no-op, so `replacementEdits` keeps both rows either way — a
        // zero-length range with a non-empty replacement is the zero-width
        // insert, which is the whole feature.
        XCTAssertEqual(
            selection.replacementEdits(with: "", in: index).count, 2,
            "replacementEdits is deliberately unfiltered: dropping a row there would lose an edit the caller needs"
        )
        XCTAssertEqual(
            apply(selection.replacementEdits(with: "!", in: index), to: source), "ab!\ncd!",
            "typing into the same overhanging block still appends to every row"
        )
    }

    func testBackspaceDeletesWholeGraphemeNotOneCodeUnit() {
        // Row 0 is "a👍" and the caret sits at its end, so the character to
        // the left is two UTF-16 units. Deleting one unit would leave a lone
        // surrogate in the document.
        let source = "a\u{1F44D}\nxyz"
        let index = LineIndex(source)
        let selection = BlockSelection(
            anchor: BlockPosition(line: 0, column: 3),
            head: BlockPosition(line: 1, column: 3)
        )

        let edits = selection.backspaceEdits(in: index)

        XCTAssertEqual(
            edits.map(\.range), [NSRange(location: 6, length: 1), NSRange(location: 1, length: 2)],
            "the emoji row deletes two units — the whole grapheme — and the ASCII row deletes one"
        )
        let deleted = apply(edits, to: source)
        XCTAssertEqual(deleted, "a\nxy")
        XCTAssertFalse(
            deleted.unicodeScalars.contains { $0.value == 0xFFFD },
            "deleting a single code unit would strand a surrogate: " + deleted.debugDescription
        )
    }

    func testBackspaceAtColumnZeroSkipsTheRow() {
        // The middle line is empty, so the block's column 1 clamps to column
        // 0 on it: a caret with nothing to its left on its own line.
        let source = "ab\n\ncd"
        let index = LineIndex(source)
        let selection = BlockSelection(
            anchor: BlockPosition(line: 0, column: 1),
            head: BlockPosition(line: 2, column: 1)
        )

        let edits = selection.backspaceEdits(in: index)

        XCTAssertEqual(
            edits.map(\.range), [NSRange(location: 4, length: 1), NSRange(location: 0, length: 1)],
            "the empty row is simply absent from the result — two rows contribute, not three"
        )
        XCTAssertFalse(
            edits.contains { $0.range.location == index.lineStart(1) },
            "no edit may be placed on the skipped row"
        )
        XCTAssertEqual(
            apply(edits, to: source), "b\n\nd",
            "both newlines survive: the row at column 0 is skipped, not joined to the line above it"
        )
    }

    func testBackspaceWithEveryCaretAtColumnZeroReturnsNoEdits() {
        let source = "one\ntwo\nthree"
        let index = LineIndex(source)
        let selection = BlockSelection(
            anchor: BlockPosition(line: 0, column: 0),
            head: BlockPosition(line: 2, column: 0)
        )

        XCTAssertEqual(
            selection.backspaceEdits(in: index), [],
            "no row has anything to its left, so the whole gesture is empty — N no-op edits would register an empty undo group"
        )
        XCTAssertEqual(
            selection.replacementEdits(with: "", in: index).count, 3,
            "the contrast with replacementEdits is deliberate: there every row receives the replacement, so none is dropped"
        )
    }

    func testForwardDeleteAtEndOfLineSkipsTheRow() {
        // Column 3 is the end of "abc" and the middle of "defgh".
        let source = "abc\ndefgh"
        let index = LineIndex(source)
        let selection = BlockSelection(
            anchor: BlockPosition(line: 0, column: 3),
            head: BlockPosition(line: 1, column: 3)
        )

        let edits = selection.forwardDeleteEdits(in: index)

        XCTAssertEqual(edits.map(\.range), [NSRange(location: 7, length: 1)], "only the row with a character to its right contributes")
        XCTAssertFalse(
            edits.contains { $0.range.location <= 3 && 3 < $0.range.location + $0.range.length },
            "offset 3 is the newline; deleting it would pull the next line up and dissolve the block's rows"
        )
        let deleted = apply(edits, to: source)
        XCTAssertEqual(deleted, "abc\ndefh")
        XCTAssertEqual(LineIndex(deleted).lineCount, 2, "the document still has two lines — the newline was not eaten")
    }

    func testDeleteEditsAreSortedDescendingByLocation() {
        let source = "alpha\nbravo\ncharlie\ndelta"
        let index = LineIndex(source)
        let selection = BlockSelection(
            anchor: BlockPosition(line: 0, column: 2),
            head: BlockPosition(line: 3, column: 2)
        )

        let backspace = selection.backspaceEdits(in: index)
        let forwardDelete = selection.forwardDeleteEdits(in: index)

        XCTAssertEqual(
            backspace.map(\.range.location), [21, 13, 7, 1],
            "bottom-up, so applying them in order leaves the not-yet-applied offsets valid"
        )
        XCTAssertEqual(forwardDelete.map(\.range.location), [22, 14, 8, 2])
        for edits in [backspace, forwardDelete] {
            XCTAssertEqual(
                edits.map(\.range.location), edits.map(\.range.location).sorted(by: >),
                "every delete path owes the same descending-order contract as replacementEdits"
            )
        }
        XCTAssertEqual(apply(backspace, to: source), "apha\nbavo\ncarlie\ndlta")
        XCTAssertEqual(apply(forwardDelete, to: source), "alha\nbrvo\nchrlie\ndeta")
    }

    func testDeleteEditsNeverCrossALineBoundary() {
        // The first fixture is the pathological one: line 1 opens with two
        // combining marks that Foundation reports as one sequence with the
        // *previous* line's newline, so an unbounded grapheme walk would
        // delete across the break.
        let sources = ["x\n\u{0301}\u{0302}y\nzz", "a\u{1F44D}b\nxyzw", "ab\n\ncd", "one\ntwo\nthree"]
        for source in sources {
            let index = LineIndex(source)
            let text = source as NSString
            for column in 0...5 {
                let selection = BlockSelection(
                    anchor: BlockPosition(line: 0, column: column),
                    head: BlockPosition(line: index.lineCount - 1, column: column)
                )

                for edits in [selection.backspaceEdits(in: index), selection.forwardDeleteEdits(in: index)] {
                    for edit in edits {
                        let line = index.position(forUTF16Offset: edit.range.location).line
                        let lineStart = index.lineStart(line)
                        let lineEnd = lineStart + index.lineLength(line)
                        let where_ = "\(source.debugDescription) column \(column) row \(line): \(edit.range)"

                        XCTAssertGreaterThanOrEqual(edit.range.location, lineStart, "\(where_) starts before its own line")
                        XCTAssertLessThanOrEqual(edit.range.location + edit.range.length, lineEnd, "\(where_) ends past its own line")
                        XCTAssertGreaterThan(edit.range.length, 0, "\(where_) is a no-op and should have been left out")
                        XCTAssertFalse(text.substring(with: edit.range).contains("\n"), "\(where_) covers a line break")
                    }
                }
            }
        }
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
