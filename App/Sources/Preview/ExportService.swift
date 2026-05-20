import Foundation
import WritCore
import WritParser
import WritRender

/// Disk-side wrapper around ``HTMLExporter`` — composes the bundled CSS and
/// writes the result atomically. The pure composition lives in WritRender so
/// it can be unit-tested without an AppKit harness.
@MainActor
enum ExportService {
    /// Persisted preference: include a TOC at the top of HTML and PDF
    /// exports. Default off.
    static let includeTOCDefaultsKey = "WritIncludeTOCInExport"
    static var includeTOC: Bool {
        get { UserDefaults.standard.bool(forKey: includeTOCDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: includeTOCDefaultsKey) }
    }

    /// Captures the live preview DOM (already-rendered math, Mermaid, etc.),
    /// wraps it with the bundled CSS, and writes the result to `url`. Falls
    /// back to the parser output if the preview can't be captured.
    static func exportHTML(preview: PreviewViewController, parsed: ParsedDocument?, source: String, theme: String, to url: URL) {
        // All three stylesheets the live preview relies on must be inlined so
        // the export renders identically without external assets:
        //   - theme.css   editor typography, table, blockquote, etc.
        //   - katex.css   math glyph fonts and spacing
        //   - github.css  highlight.js colour scheme for code blocks
        let css = bundledCSS() + "\n" + katexCSS() + "\n" + highlightCSS() + "\n" + tocCSS()
        let toc = includeTOC ? TOCBuilder.render(from: source) : ""
        preview.capturedContentHTML { captured in
            let html: String
            if let captured, !captured.isEmpty {
                html = HTMLExporter.render(body: captured, theme: theme, css: css, toc: toc)
            } else {
                html = HTMLExporter.render(parsed: parsed, theme: theme, css: css, toc: toc)
            }
            do {
                try Data(html.utf8).write(to: url, options: .atomic)
            } catch {
                print("Writ: HTML export failed: \(error)")
            }
        }
    }

    /// Minimal TOC stylesheet — bundled into exports so the nav block
    /// renders cleanly even without the live preview's theme.css.
    private static func tocCSS() -> String {
        """
        nav.writ-toc {
          margin: 0 0 2em;
          padding: 0.8em 1em;
          background: var(--writ-bg-alt, #f6f7f9);
          border: 1px solid var(--writ-border, #d6d8de);
          border-radius: 6px;
        }
        nav.writ-toc h2.writ-toc-title {
          margin: 0 0 0.5em;
          font-size: 1.05em;
          color: var(--writ-fg-muted, #525560);
        }
        nav.writ-toc ol {
          margin: 0;
          padding-left: 1.2em;
        }
        nav.writ-toc ol ol {
          padding-left: 1em;
        }
        nav.writ-toc a {
          color: var(--writ-link, #0a66c2);
          text-decoration: none;
        }
        nav.writ-toc a:hover { text-decoration: underline; }
        """
    }

    private static func bundledCSS() -> String {
        guard let cssURL = Bundle.main.url(forResource: "theme", withExtension: "css", subdirectory: "preview")
                ?? Bundle.main.url(forResource: "preview/theme", withExtension: "css") else {
            return ""
        }
        return (try? String(contentsOf: cssURL, encoding: .utf8)) ?? ""
    }

    /// KaTeX rendered HTML references KaTeX stylesheet classes — bundle it
    /// inline so exports look right without external assets.
    private static func katexCSS() -> String {
        guard let cssURL = Bundle.main.url(forResource: "katex.min", withExtension: "css", subdirectory: "preview/vendor/katex")
                ?? Bundle.main.url(forResource: "preview/vendor/katex/katex.min", withExtension: "css") else {
            return ""
        }
        return (try? String(contentsOf: cssURL, encoding: .utf8)) ?? ""
    }

    private static func highlightCSS() -> String {
        guard let cssURL = Bundle.main.url(forResource: "github.min", withExtension: "css", subdirectory: "preview/vendor/highlight")
                ?? Bundle.main.url(forResource: "preview/vendor/highlight/github.min", withExtension: "css") else {
            return ""
        }
        return (try? String(contentsOf: cssURL, encoding: .utf8)) ?? ""
    }
}
