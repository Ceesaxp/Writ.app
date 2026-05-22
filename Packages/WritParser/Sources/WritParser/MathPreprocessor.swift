import Foundation
import WritCore

/// Extracts GitHub-compatible math regions from Markdown source before it is
/// handed to a CommonMark parser.
///
/// Math source is replaced in-place by an HTML placeholder element that cmark
/// will treat as inline or block HTML and pass through unchanged. The original
/// source travels alongside in ``MathPreprocessor.Result.blocks`` so the
/// preview can render it asynchronously.
///
/// Supported:
/// - block `$$...$$` — both opener and closer must be the only non-whitespace
///   content on their line (Pandoc / GitHub strict rule)
/// - inline `$...$` on a single line. GitHub-strict delimiter rules apply:
///     - opening `$` must be at start-of-source or preceded by a
///       non-alphanumeric character; must be followed by non-whitespace
///     - closing `$` must be preceded by non-whitespace; must be followed by
///       end-of-line or a non-alphanumeric character; and must not be followed
///       by a digit (kills `$5 and $10`-style currency false positives)
///
/// Per-document opt-out via front matter `math: false`. The caller is expected
/// to short-circuit before calling `extract` when that flag is set.
public enum MathPreprocessor {
    public struct Extracted: Sendable {
        public let block: TechnicalBlock
        public let isBlock: Bool
    }

    public static func extract(_ source: String) -> (preprocessed: String, blocks: [Extracted]) {
        var out = String()
        out.reserveCapacity(source.count)
        var blocks: [Extracted] = []
        var idx = source.startIndex
        let end = source.endIndex
        var counter = 0

        while idx < end {
            let ch = source[idx]
            if ch == "\\" {
                let next = source.index(after: idx)
                if next < end {
                    out.append(ch)
                    out.append(source[next])
                    idx = source.index(after: next)
                    continue
                }
            }
            if ch == "$" {
                let afterFirst = source.index(after: idx)
                if afterFirst < end, source[afterFirst] == "$" {
                    // `$$` — must be the only non-whitespace content on its
                    // line for both opener and closer.
                    if lineIsOnlyDelimiter(in: source, doubleStart: idx),
                       let closing = findBlockClose(in: source, from: nextLineStart(in: source, from: afterFirst)) {
                        let bodyStart = nextLineStart(in: source, from: afterFirst)
                        let mathSource = String(source[bodyStart..<closing.lineStart])
                        let id = "MATH_\(counter)"
                        counter += 1
                        let block = TechnicalBlock(id: id, kind: .math, source: mathSource)
                        blocks.append(Extracted(block: block, isBlock: true))
                        out.append("\n<div data-writ-block=\"\(id)\" class=\"writ-math-block\"></div>\n")
                        idx = closing.endOfLine
                        continue
                    }
                    // Not a valid block delimiter: emit both `$` as literals
                    // so the second one isn't reinterpreted as an inline
                    // opener (which would turn `$$x^2$$` into `$ <inline x^2> $`).
                    out.append("$$")
                    idx = source.index(after: afterFirst)
                    continue
                }
                // Single `$` — inline math candidate.
                if isValidInlineOpenContext(in: source, at: idx),
                   let closing = findInlineClose(in: source, from: afterFirst),
                   isValidInlineCloseContext(in: source, at: closing) {
                    let mathSource = String(source[afterFirst..<closing])
                    let id = "MATH_\(counter)"
                    counter += 1
                    let block = TechnicalBlock(id: id, kind: .mathInline, source: mathSource)
                    blocks.append(Extracted(block: block, isBlock: false))
                    out.append("<span data-writ-block=\"\(id)\" class=\"writ-math-inline\"></span>")
                    idx = source.index(after: closing)
                    continue
                }
            }
            out.append(ch)
            idx = source.index(after: idx)
        }
        return (out, blocks)
    }

    /// True when the line containing `doubleStart` (which points at the
    /// first `$` of a `$$` pair) consists only of `$$` plus surrounding
    /// whitespace — i.e. matches `^\s*\$\$\s*$`.
    private static func lineIsOnlyDelimiter(in source: String, doubleStart: String.Index) -> Bool {
        // Anything before `doubleStart` on the same line must be whitespace.
        var i = doubleStart
        while i > source.startIndex {
            let prev = source.index(before: i)
            let c = source[prev]
            if c == "\n" { break }
            if !c.isWhitespace { return false }
            i = prev
        }
        // Anything after the closing `$` (at doubleStart+2) on the same
        // line must be whitespace until newline or end-of-source.
        let afterDouble = source.index(doubleStart, offsetBy: 2, limitedBy: source.endIndex) ?? source.endIndex
        var j = afterDouble
        while j < source.endIndex {
            let c = source[j]
            if c == "\n" { return true }
            if !c.isWhitespace { return false }
            j = source.index(after: j)
        }
        return true
    }

    /// Advances past the rest of the current line (consumes the `\n`
    /// if present); returns the index where the next line begins.
    private static func nextLineStart(in source: String, from start: String.Index) -> String.Index {
        var i = start
        let end = source.endIndex
        while i < end {
            if source[i] == "\n" { return source.index(after: i) }
            i = source.index(after: i)
        }
        return end
    }

    /// Finds a line whose content is exactly `$$` (possibly surrounded
    /// by whitespace). Returns the start of that line (where the math
    /// body ends) and the index just past the line's newline (where
    /// scanning resumes).
    private static func findBlockClose(
        in source: String,
        from start: String.Index
    ) -> (lineStart: String.Index, endOfLine: String.Index)? {
        var lineStart = start
        let end = source.endIndex
        while lineStart < end {
            var i = lineStart
            while i < end, source[i] != "\n" { i = source.index(after: i) }
            let lineEnd = i
            let line = source[lineStart..<lineEnd]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "$$" {
                let next = (lineEnd < end) ? source.index(after: lineEnd) : end
                return (lineStart, next)
            }
            if lineEnd >= end { return nil }
            lineStart = source.index(after: lineEnd)
        }
        return nil
    }

    /// Checks the character preceding the `$` opener. Must be at start
    /// of source or preceded by a non-alphanumeric character (the
    /// GitHub strict rule that kills `foo$bar$` patterns).
    private static func isValidInlineOpenContext(in source: String, at dollarIdx: String.Index) -> Bool {
        if dollarIdx == source.startIndex { return true }
        let prev = source.index(before: dollarIdx)
        let pc = source[prev]
        if pc.isLetter || pc.isNumber { return false }
        return true
    }

    /// Checks the character following the closing `$`. Must be at end
    /// of line, end of source, or a non-alphanumeric character. Also
    /// must NOT be a digit (kills `$5 and $10` false positives even
    /// when both delimiters technically pass the inner rules).
    private static func isValidInlineCloseContext(in source: String, at dollarIdx: String.Index) -> Bool {
        let next = source.index(after: dollarIdx)
        if next >= source.endIndex { return true }
        let nc = source[next]
        if nc == "\n" { return true }
        if nc.isNumber { return false }
        if nc.isLetter { return false }
        return true
    }

    /// Scans forward from the index just past the opening `$` looking
    /// for the matching closing `$`. Returns its index, or nil if the
    /// line ends without a valid closing delimiter.
    private static func findInlineClose(
        in source: String,
        from start: String.Index
    ) -> String.Index? {
        let end = source.endIndex
        guard start < end, !source[start].isWhitespace else { return nil }

        var i = start
        var hasNonSpace = false
        while i < end {
            let ch = source[i]
            if ch == "\n" { return nil }
            if ch == "\\" {
                let next = source.index(after: i)
                if next < end {
                    hasNonSpace = true
                    i = source.index(after: next)
                    continue
                }
            }
            if ch == "$" {
                let prev = source.index(before: i)
                if hasNonSpace, !source[prev].isWhitespace {
                    return i
                }
                return nil
            }
            if !ch.isWhitespace { hasNonSpace = true }
            i = source.index(after: i)
        }
        return nil
    }
}
