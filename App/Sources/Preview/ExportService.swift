import Foundation
import WritCore
import WritParser
import WritRender

/// Disk-side wrapper around ``HTMLExporter`` — composes the bundled CSS and
/// writes the result atomically. The pure composition lives in WritRender so
/// it can be unit-tested without an AppKit harness.
enum ExportService {
    static func exportHTML(parsed: ParsedDocument?, theme: String, to url: URL) {
        let html = HTMLExporter.render(parsed: parsed, theme: theme, css: bundledCSS())
        do {
            try Data(html.utf8).write(to: url, options: .atomic)
        } catch {
            print("Writ: HTML export failed: \(error)")
        }
    }

    private static func bundledCSS() -> String {
        guard let cssURL = Bundle.main.url(forResource: "theme", withExtension: "css", subdirectory: "preview")
                ?? Bundle.main.url(forResource: "preview/theme", withExtension: "css") else {
            return ""
        }
        return (try? String(contentsOf: cssURL, encoding: .utf8)) ?? ""
    }
}
