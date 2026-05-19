import Foundation
import WritCore
import WritParser
import WritRender

/// Disk-side wrapper around ``HTMLExporter`` — composes the bundled CSS and
/// writes the result atomically. The pure composition lives in WritRender so
/// it can be unit-tested without an AppKit harness.
@MainActor
enum ExportService {
    /// Captures the live preview DOM (already-rendered math, Mermaid, etc.),
    /// wraps it with the bundled CSS, and writes the result to `url`. Falls
    /// back to the parser output if the preview can't be captured.
    static func exportHTML(preview: PreviewViewController, parsed: ParsedDocument?, theme: String, to url: URL) {
        let css = bundledCSS() + "\n" + katexCSS()
        preview.capturedContentHTML { captured in
            let html: String
            if let captured, !captured.isEmpty {
                html = HTMLExporter.render(body: captured, theme: theme, css: css)
            } else {
                html = HTMLExporter.render(parsed: parsed, theme: theme, css: css)
            }
            do {
                try Data(html.utf8).write(to: url, options: .atomic)
            } catch {
                print("Writ: HTML export failed: \(error)")
            }
        }
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
}
