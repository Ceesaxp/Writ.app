import Foundation

/// A position in the document as a 0-based logical line plus a 0-based
/// UTF-16 column offset within that line.
///
/// Columns are UTF-16 code-unit counts, not `Character` counts, because
/// `NSTextView` selection offsets are UTF-16 code units. Mixing the two
/// has already cost this editor a crash on the empty-document edge, so the
/// whole block-selection model speaks one unit and only one unit.
struct BlockPosition: Equatable, Comparable {
    var line: Int
    var column: Int

    /// Document reading order: earlier line first, then earlier column.
    static func < (lhs: BlockPosition, rhs: BlockPosition) -> Bool {
        (lhs.line, lhs.column) < (rhs.line, rhs.column)
    }
}

/// UTF-16 line-start table for a document string.
///
/// Built once per block-selection gesture and then queried once per line,
/// so a lookup must never rescan the document: the table is a sorted array
/// of line-start offsets, `lineStart`/`lineLength` are O(1) and
/// `position(forUTF16Offset:)` is a binary search.
///
/// Lines are the `\n`-separated runs *keeping a trailing empty line*:
/// `"a\nb\n"` is three lines `["a", "b", ""]`, `"a\nb"` is two, and `""` is
/// one empty line. That is what the editor draws, and it matches
/// `DocumentSnapshot.countLines`. Only `\n` is a line break — the editor
/// normalises line endings on load, so `\r\n` never reaches this model.
struct LineIndex {
    /// The document the table was built from.
    ///
    /// Retained, not discarded: `String` is copy-on-write, so holding it
    /// costs a reference, and it lets the index answer questions about the
    /// *text* as well as the line offsets. It also makes the one real
    /// hazard — pairing an index with a different document than the ranges
    /// are applied to — unrepresentable rather than merely unlikely.
    let source: String

    /// UTF-16 offset of each line's first code unit. Always non-empty, so
    /// `lineCount >= 1` even for an empty document.
    private let lineStarts: [Int]

    /// Total UTF-16 length of the source, needed to size the last line.
    private let utf16Count: Int

    init(_ source: String) {
        var starts = [0]
        var offset = 0
        for unit in source.utf16 {
            offset += 1
            if unit == 0x0A { starts.append(offset) }
        }
        self.source = source
        self.lineStarts = starts
        self.utf16Count = offset
    }

    var lineCount: Int { lineStarts.count }

    /// UTF-16 offset of the line's first code unit. An out-of-range line
    /// clamps into `0..<lineCount` rather than trapping.
    func lineStart(_ line: Int) -> Int {
        lineStarts[clampedLine(line)]
    }

    /// UTF-16 length of the line *excluding* its trailing newline, so a
    /// fragment range built from it can never cover the line break.
    func lineLength(_ line: Int) -> Int {
        let line = clampedLine(line)
        if line == lineStarts.count - 1 {
            return utf16Count - lineStarts[line]
        }
        // The next line starts one unit past this line's newline.
        return lineStarts[line + 1] - lineStarts[line] - 1
    }

    /// Translate a UTF-16 offset into (line, column). Binary search, so the
    /// cost is O(log lines) and not a per-call scan of the document. An
    /// offset outside `0...utf16Count` clamps into it.
    func position(forUTF16Offset offset: Int) -> BlockPosition {
        let target = max(0, min(offset, utf16Count))
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= target { low = mid } else { high = mid - 1 }
        }
        return BlockPosition(line: low, column: target - lineStarts[low])
    }

    /// Translate a (line, column) back into a UTF-16 offset. The line
    /// clamps into `0..<lineCount` and the column into `0...lineLength`, so
    /// a column that overhangs a short line lands at that line's end rather
    /// than on its newline or in the next line.
    func utf16Offset(of position: BlockPosition) -> Int {
        let line = clampedLine(position.line)
        let column = max(0, min(position.column, lineLength(line)))
        return lineStarts[line] + column
    }

    private func clampedLine(_ line: Int) -> Int {
        max(0, min(line, lineStarts.count - 1))
    }
}

/// A single text replacement: the UTF-16 range to overwrite and what to
/// put there. A block operation is always a *list* of these, one per row.
struct BlockEdit: Equatable {
    let range: NSRange
    let replacement: String
}

/// A rectangular ("block" / "column") selection: the drag or extend origin
/// and the live caret corner.
///
/// The two corners are stored as given, not normalised, so the caret can
/// keep moving in either direction while the anchor stays put. Everything
/// derived — `lineRange`, `columnRange`, the fragments — is normalised, so
/// a block dragged up-and-left covers the same rectangle as the equivalent
/// forward drag.
struct BlockSelection: Equatable {
    var anchor: BlockPosition
    var head: BlockPosition

    /// The lines the block touches, ascending and inclusive.
    var lineRange: ClosedRange<Int> {
        min(anchor.line, head.line)...max(anchor.line, head.line)
    }

    /// The UTF-16 columns the block covers, half-open. Empty — `n..<n` —
    /// when the block is zero-width.
    var columnRange: Range<Int> {
        min(anchor.column, head.column)..<max(anchor.column, head.column)
    }

    /// A zero-width block is a column of carets, one per line, and is a
    /// first-class case rather than a degenerate one: parking a zero-width
    /// block at column 0 across twenty lines and typing `- ` is the whole
    /// point of the feature.
    var isZeroWidth: Bool { anchor.column == head.column }

    /// One range per line in `lineRange`, **ascending by line**.
    ///
    /// A fragment never includes a newline character: it is bounded by the
    /// line's own length, which `LineIndex` reports without the line break.
    /// Two cases give a zero-length range — a zero-width block, and a line
    /// too short to reach the block's left edge. Short lines **clamp, they
    /// do not pad**: the fragment collapses to the line's end instead of
    /// the model inventing spaces, so typing into a rectangle that overhangs
    /// a short line appends at that line's end. Padding would mean editing
    /// text the user never selected.
    ///
    /// Both the line range and the columns clamp into the document, so a
    /// selection that outlived the text it was made in degrades to a sane
    /// rectangle at the document's end instead of trapping.
    ///
    /// A non-empty fragment is finally widened to whole composed character
    /// sequences — see `snappedToGraphemes(_:in:)` for why outward, and why
    /// the zero-length case is left alone.
    func fragmentRanges(in index: LineIndex) -> [NSRange] {
        let lines = clampedLines(in: index)
        let columns = columnRange
        let text = index.source as NSString
        return lines.map { line in
            let lineStart = index.lineStart(line)
            let lineLength = index.lineLength(line)
            let left = max(0, min(columns.lowerBound, lineLength))
            let right = max(left, min(columns.upperBound, lineLength))
            let range = NSRange(location: lineStart + left, length: right - left)
            return BlockSelection.snappedToGraphemes(range, in: text)
        }
    }

    /// Widen a fragment to whole composed character sequences.
    ///
    /// One column number is applied to every row, so an edge that is a clean
    /// boundary on one line can land inside a surrogate pair or a combining
    /// sequence on the next — and keyboard column extension (column ± 1)
    /// reaches that case directly. The resulting range goes straight to
    /// `NSTextStorage.replaceCharacters`, which would then write a lone
    /// surrogate into the document and onto the pasteboard. Mouse
    /// hit-testing never produces such a column, which is why the view
    /// layer cannot be relied on to notice: the rule belongs here, where it
    /// is pure Foundation and testable without a layout manager.
    ///
    /// **Outward, never inward.** An edge inside a grapheme takes the whole
    /// grapheme rather than dropping it — the same adjustment `NSTextView`
    /// makes to its own selections, so the model agrees with the view
    /// instead of fighting it. The widening cannot escape the line: `\n` is
    /// its own grapheme, so a fragment bounded by `lineLength` stays bounded
    /// by it.
    ///
    /// **Zero length is exempt.** A zero-width block is N carets, and
    /// `rangeOfComposedCharacterSequences` inflates *any* empty range to the
    /// grapheme containing it — which would turn "insert at a caret" into
    /// "replace a character", and at a line's end would swallow the
    /// newline. A caret mid-grapheme is merely odd to look at; it corrupts
    /// nothing.
    private static func snappedToGraphemes(_ range: NSRange, in text: NSString) -> NSRange {
        guard range.length > 0 else { return range }
        return text.rangeOfComposedCharacterSequences(for: range)
    }

    /// The block's fragments joined with `\n` — what Cmd-C should put on
    /// the pasteboard. A row too short to reach the block contributes an
    /// empty string rather than being dropped, so the rectangle's shape
    /// survives the round trip through `pasteEdits`.
    func copyString(in index: LineIndex) -> String {
        let text = index.source as NSString
        return fragmentRanges(in: index)
            .map { text.substring(with: $0) }
            .joined(separator: "\n")
    }

    /// Edits that replace every fragment with `replacement` — typing into a
    /// block, or deleting it with `replacement: ""`.
    ///
    /// **The caller applies the edits in the order returned.** They are
    /// sorted descending by `range.location` so that each replacement only
    /// ever moves text *after* itself, leaving the locations of the edits
    /// that have not run yet still valid. Applying them in any other order
    /// requires the caller to re-derive offsets after every step.
    ///
    /// A zero-width block yields one zero-length edit per row rather than
    /// an empty list: the one-edit-per-row shape is what the caller needs
    /// to place N carets afterwards, and with `replacement: ""` the edits
    /// are simply a no-op on the text.
    func replacementEdits(with replacement: String, in index: LineIndex) -> [BlockEdit] {
        fragmentRanges(in: index)
            .reversed()
            .map { BlockEdit(range: $0, replacement: replacement) }
    }

    /// Edits for pasting `clipboard` into the block, descending by
    /// `range.location` on the same contract as `replacementEdits`.
    ///
    /// The clipboard is split on `\n` with exactly one trailing newline
    /// discarded, so `"x\ny\n"` and `"x\ny"` are both two lines and `""`
    /// is one empty line. With M clipboard lines and N block rows:
    ///
    ///  - **M == 1** — that one line goes onto every row. This is how a
    ///    column of table pipes or list markers gets pasted.
    ///  - **M == N** — positional: row *i* takes clipboard line *i*.
    ///  - **otherwise** — this is not a block paste at all, so rather than
    ///    guess, fall back to a single edit replacing the whole contiguous
    ///    span from the block's top-left to its bottom-right offset with
    ///    the clipboard **verbatim**, trailing newline included. Lossless
    ///    and predictable beats silently dropping or repeating lines.
    func pasteEdits(clipboard: String, in index: LineIndex) -> [BlockEdit] {
        let fragments = fragmentRanges(in: index)
        guard !fragments.isEmpty else { return [] }
        let lines = BlockSelection.clipboardLines(clipboard)

        if lines.count == 1 {
            return replacementEdits(with: lines[0], in: index)
        }
        if lines.count == fragments.count {
            return zip(fragments, lines)
                .reversed()
                .map { BlockEdit(range: $0.0, replacement: $0.1) }
        }
        return [BlockEdit(range: BlockSelection.span(of: fragments), replacement: clipboard)]
    }

    /// Split a clipboard string into rows, discarding at most one trailing
    /// newline. Done over unicode scalars rather than `Character`s: `\n` is
    /// never part of a surrogate pair, but `\r\n` is a single `Character`,
    /// and treating it as a line break here would disagree with
    /// `LineIndex`, which counts only `\n`.
    private static func clipboardLines(_ clipboard: String) -> [String] {
        var scalars = Array(clipboard.unicodeScalars)
        if scalars.last == "\n" { scalars.removeLast() }
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in scalars {
            if scalar == "\n" {
                lines.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        lines.append(String(current))
        return lines
    }

    /// The contiguous span from the block's top-left offset to its
    /// bottom-right one. Taken as min-location to max-end over the
    /// fragments so a ragged right edge can't invert the range.
    private static func span(of fragments: [NSRange]) -> NSRange {
        let lower = fragments.map(\.location).min() ?? 0
        let upper = fragments.map { $0.location + $0.length }.max() ?? lower
        return NSRange(location: lower, length: upper - lower)
    }

    /// `lineRange` with each endpoint clamped into the document's lines.
    /// Clamping the endpoints rather than intersecting the range keeps a
    /// wholly out-of-range block alive as a block on the last line, which
    /// is the same choice `LineIndex.utf16Offset(of:)` makes.
    private func clampedLines(in index: LineIndex) -> ClosedRange<Int> {
        let last = index.lineCount - 1
        let lower = max(0, min(lineRange.lowerBound, last))
        let upper = max(0, min(lineRange.upperBound, last))
        return min(lower, upper)...max(lower, upper)
    }
}
