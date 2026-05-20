import Foundation
import Markdown

/// One heading in a document outline.
///
/// `OutlineExtractor` produces a flat list of these — the editor's
/// outline pane is responsible for building the visible nesting from the
/// `level` field if it wants to.
public struct OutlineHeading: Sendable, Hashable {
    /// 1…6 (matches HTML <h1>…<h6>).
    public let level: Int
    /// Plain-text rendering of the heading content, with markdown
    /// formatting stripped.
    public let title: String
    /// 1-indexed source line, suitable for handing to the editor's
    /// scrollToSourceLine.
    public let line: Int

    public init(level: Int, title: String, line: Int) {
        self.level = level
        self.title = title
        self.line = line
    }
}

/// Walks a document and collects every heading into a flat ordered list.
public enum OutlineExtractor {
    public static func extract(from source: String) -> [OutlineHeading] {
        // Mask math regions before parsing. CommonMark interprets a line
        // of `=` (or `-`) under a text line as a setext heading — and a
        // multi-line `$$...$$` block can easily contain such a line
        // (e.g. matrix equations). Masking with spaces preserves line
        // numbers so heading.line stays meaningful for scroll sync.
        let masked = maskMathRegions(in: source)
        let document = Document(parsing: masked)
        var headings: [OutlineHeading] = []
        for child in document.children {
            collect(child, into: &headings)
        }
        return headings
    }

    private static func collect(_ markup: any Markup, into headings: inout [OutlineHeading]) {
        if let heading = markup as? Heading {
            let title = heading.plainText
            let line = heading.range?.lowerBound.line ?? 0
            headings.append(OutlineHeading(level: heading.level, title: title, line: line))
        }
        // Headings are top-level in CommonMark; we don't recurse to keep
        // the list flat and predictable.
    }

    /// Replaces the *content* of every `$$...$$` and `$...$` region with
    /// spaces while preserving newlines, so CommonMark sees those lines
    /// as effectively empty. Line numbers in the masked output match the
    /// original source.
    private static func maskMathRegions(in source: String) -> String {
        var out = String()
        out.reserveCapacity(source.count)
        let chars = Array(source)
        let n = chars.count
        var i = 0
        while i < n {
            let ch = chars[i]
            if ch == "\\" && i + 1 < n {
                // Pass through any escaped char (e.g. `\$`) so it isn't
                // mistaken for a math delimiter.
                out.append(ch)
                out.append(chars[i + 1])
                i += 2
                continue
            }
            if ch == "$" {
                if i + 1 < n && chars[i + 1] == "$" {
                    if let closeStart = findBlockMathClose(in: chars, from: i + 2) {
                        // Mask `$$` + body + `$$`. Newlines inside stay
                        // newlines; everything else becomes a space.
                        for k in i..<(closeStart + 2) {
                            out.append(chars[k] == "\n" ? "\n" : " ")
                        }
                        i = closeStart + 2
                        continue
                    }
                } else if let closeIdx = findInlineMathClose(in: chars, from: i + 1) {
                    for k in i...closeIdx {
                        out.append(chars[k] == "\n" ? "\n" : " ")
                    }
                    i = closeIdx + 1
                    continue
                }
            }
            out.append(ch)
            i += 1
        }
        return out
    }

    private static func findBlockMathClose(in chars: [Character], from start: Int) -> Int? {
        var i = start
        let n = chars.count
        while i < n {
            if chars[i] == "\\" && i + 1 < n { i += 2; continue }
            if chars[i] == "$" && i + 1 < n && chars[i + 1] == "$" {
                return i
            }
            i += 1
        }
        return nil
    }

    private static func findInlineMathClose(in chars: [Character], from start: Int) -> Int? {
        let n = chars.count
        guard start < n, !chars[start].isWhitespace else { return nil }
        var i = start
        var sawNonSpace = false
        while i < n {
            let ch = chars[i]
            if ch == "\n" { return nil }
            if ch == "\\" && i + 1 < n {
                sawNonSpace = true
                i += 2
                continue
            }
            if ch == "$" {
                let prev = chars[i - 1]
                return (sawNonSpace && !prev.isWhitespace) ? i : nil
            }
            if !ch.isWhitespace { sawNonSpace = true }
            i += 1
        }
        return nil
    }
}
