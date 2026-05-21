import Foundation
import WritParser

/// Pure HTML export composition. Lives in the render package so it can be
/// unit-tested without an AppKit harness; the app target wraps this with
/// disk I/O and Save panel plumbing.
public enum HTMLExporter {
    public static func render(parsed: ParsedDocument?, theme: String, css: String, toc: String = "") -> String {
        let body = parsed?.html ?? "<!-- no rendered document available -->"
        // Use front-matter `title` if present so the exported file's
        // browser tab / OS preview shows the document name rather
        // than the generic "Writ Export" placeholder.
        let title = parsed?.frontMatter?["title"] ?? "Writ Export"
        return render(body: body, theme: theme, css: css, toc: toc, title: title)
    }

    public static func render(body: String, theme: String, css: String, toc: String = "", title: String = "Writ Export") -> String {
        let escapedTitle = escapeHTML(title)
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(escapedTitle)</title>
        <style>\n\(css)\n</style>
        </head>
        <body class="writ-export writ-theme-\(theme)">
        <main id="writ-content">
        \(toc)
        \(body)
        </main>
        </body>
        </html>
        """
    }

    private static func escapeHTML(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out.append("&amp;")
            case "<": out.append("&lt;")
            case ">": out.append("&gt;")
            case "\"": out.append("&quot;")
            case "'": out.append("&#39;")
            default: out.append(ch)
            }
        }
        return out
    }
}
