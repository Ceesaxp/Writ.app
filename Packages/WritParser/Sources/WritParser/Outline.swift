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
        let document = Document(parsing: source)
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
}
