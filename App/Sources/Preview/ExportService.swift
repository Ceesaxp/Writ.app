import Foundation
import WritCore
import WritParser
import WritRender

/// Generates HTML export bundles from a `ParsedDocument`.
///
/// MVP scope: emit a single self-contained HTML file that references the
/// bundled preview shell's CSS inlined into the export. Math/Mermaid
/// rendering is left as a follow-up — M2 will render them server-side or
/// capture from the live preview.
enum ExportService {
    static func exportHTML(parsed: ParsedDocument?, theme: String, to url: URL) {
        guard let parsed else {
            try? Data("<!-- no rendered document available -->".utf8).write(to: url)
            return
        }
        let css = bundledCSS()
        let html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Writ Export</title>
        <style>\n\(css)\n</style>
        </head>
        <body class="writ-export writ-theme-\(theme)">
        <main id="writ-content">
        \(parsed.html)
        </main>
        </body>
        </html>
        """
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
