import Testing
import Foundation
import WritCore
import WritParser
@testable import WritRender

@Suite("HTMLExporter")
struct ExporterTests {
    @Test("Render produces standalone HTML with the parsed body")
    func basicRender() throws {
        let parser = SwiftMarkdownParser()
        let snap = DocumentSnapshot(revision: .zero, source: "# Hi\n\nBody.")
        let parsed = try parser.parse(snap)
        let html = HTMLExporter.render(parsed: parsed, theme: "light", css: "h1 { color: red; }")
        #expect(html.contains("<!DOCTYPE html>"))
        #expect(html.contains("<style>"))
        #expect(html.contains("h1 { color: red; }"))
        #expect(html.contains("Hi"))
        #expect(html.contains("Body."))
        #expect(html.contains("writ-theme-light"))
        #expect(html.contains("writ-content"))
    }

    @Test("Render with nil parsed shows placeholder comment")
    func emptyRender() {
        let html = HTMLExporter.render(parsed: nil, theme: "auto", css: "")
        #expect(html.contains("no rendered document available"))
        #expect(html.contains("writ-theme-auto"))
    }

    @Test("Render preserves technical block placeholders")
    func technicalBlocks() throws {
        let parser = SwiftMarkdownParser()
        let snap = DocumentSnapshot(revision: .zero, source: "```mermaid\ngraph TD\nA-->B\n```")
        let parsed = try parser.parse(snap)
        let html = HTMLExporter.render(parsed: parsed, theme: "dark", css: "")
        #expect(html.contains("writ-mermaid"))
    }

    /// PDF and HTML exports both prepend an optional TOC block before
    /// the document body. Verify the toc argument actually lands
    /// inside `#writ-content` and ahead of the parsed HTML — that's
    /// what makes the nav block render at the top of the page in
    /// both browsers and the WKWebView print path.
    @Test("Render with toc prepends it inside the content main")
    func tocPrepended() throws {
        let parser = SwiftMarkdownParser()
        let snap = DocumentSnapshot(revision: .zero, source: "# Top\n\n## Below")
        let parsed = try parser.parse(snap)
        let toc = TOCBuilder.render(from: snap.source)
        let html = HTMLExporter.render(parsed: parsed, theme: "auto", css: "", toc: toc)

        // Both pieces present.
        #expect(html.contains("writ-toc"))
        #expect(html.contains("<h1"))

        // TOC must sit before the first body heading in the output.
        let tocRange = try #require(html.range(of: "writ-toc"))
        let firstHeadingRange = try #require(html.range(of: "<h1"))
        #expect(tocRange.lowerBound < firstHeadingRange.lowerBound,
                "TOC must be emitted ahead of the body")
    }

    /// End-to-end: every link in a TOC produced by TOCBuilder must
    /// resolve to a corresponding `id="..."` attribute in the
    /// rendered HTML. Catches the class of bug where slug rules
    /// drift between HTMLEmitter and TOCBuilder.
    @Test("Every TOC anchor matches an id in the rendered HTML")
    func tocAnchorsResolve() throws {
        let source = """
        # One

        ## Two — with punctuation!

        ### Three with UPPER case
        """
        let parser = SwiftMarkdownParser()
        let snap = DocumentSnapshot(revision: .zero, source: source)
        let parsed = try parser.parse(snap)
        let toc = TOCBuilder.render(from: source)
        let html = HTMLExporter.render(parsed: parsed, theme: "auto", css: "", toc: toc)

        // Extract every href in the TOC. Each must appear as an id in
        // the body HTML (without the leading `#`).
        let hrefPattern = try NSRegularExpression(pattern: "href=\"#([^\"]+)\"")
        let nsToc = toc as NSString
        let matches = hrefPattern.matches(in: toc, range: NSRange(location: 0, length: nsToc.length))
        #expect(matches.count >= 3, "expected at least one href per heading")

        for match in matches {
            let anchor = nsToc.substring(with: match.range(at: 1))
            #expect(html.contains("id=\"\(anchor)\""),
                    "TOC href #\(anchor) has no matching heading id in the rendered HTML")
        }
    }

    @Test("Render with empty toc string omits the nav block")
    func tocOptional() throws {
        let parser = SwiftMarkdownParser()
        let snap = DocumentSnapshot(revision: .zero, source: "# Just one")
        let parsed = try parser.parse(snap)
        let html = HTMLExporter.render(parsed: parsed, theme: "auto", css: "", toc: "")
        #expect(!html.contains("writ-toc"), "no TOC requested → no TOC in output")
        #expect(html.contains("Just one"), "body still renders")
    }
}
