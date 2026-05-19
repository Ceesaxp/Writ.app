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
}
