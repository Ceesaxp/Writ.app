import Foundation
import WritParser

/// Pure HTML export composition. Lives in the render package so it can be
/// unit-tested without an AppKit harness; the app target wraps this with
/// disk I/O and Save panel plumbing.
public enum HTMLExporter {
    public static func render(parsed: ParsedDocument?, theme: String, css: String) -> String {
        let body = parsed?.html ?? "<!-- no rendered document available -->"
        return """
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
        \(body)
        </main>
        </body>
        </html>
        """
    }
}
