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
/// Supported in M0:
/// - block `$$...$$` (may span multiple lines)
/// - inline `$...$` on a single line, no whitespace immediately inside
///
/// Deferred:
/// - inline `` $`...`$ `` (M2)
/// - GitHub's "no digit immediately after closing $" rule (M2 — current
///   implementation is intentionally conservative)
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
                    let afterOpen = source.index(after: afterFirst)
                    if let closing = findBlockClose(in: source, from: afterOpen) {
                        let mathSource = String(source[afterOpen..<closing.start])
                        let id = "MATH_\(counter)"
                        counter += 1
                        let block = TechnicalBlock(id: id, kind: .math, source: mathSource)
                        blocks.append(Extracted(block: block, isBlock: true))
                        out.append("\n<div data-writ-block=\"\(id)\" class=\"writ-math-block\"></div>\n")
                        idx = closing.end
                        continue
                    }
                } else if let closing = findInlineClose(in: source, from: afterFirst) {
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

    private static func findBlockClose(
        in source: String,
        from start: String.Index
    ) -> (start: String.Index, end: String.Index)? {
        var i = start
        let end = source.endIndex
        while i < end {
            if source[i] == "\\" {
                let next = source.index(after: i)
                if next < end {
                    i = source.index(after: next)
                    continue
                }
            }
            if source[i] == "$" {
                let next = source.index(after: i)
                if next < end, source[next] == "$" {
                    return (i, source.index(after: next))
                }
            }
            i = source.index(after: i)
        }
        return nil
    }

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
