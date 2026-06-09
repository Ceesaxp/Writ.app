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

    /// PDF paper size preference. PostScript points (1/72 inch).
    /// US Letter: 612×792 pt. A4: 595×842 pt. Default Letter so
    /// existing exports keep their dimensions.
    enum PDFPaperSize: String, CaseIterable, Sendable {
        case usLetter = "letter"
        case a4 = "a4"

        var displayName: String {
            switch self {
            case .usLetter: return "US Letter (8.5 × 11 in)"
            case .a4: return "A4 (210 × 297 mm)"
            }
        }

        var pointSize: NSSize {
            switch self {
            case .usLetter: return NSSize(width: 612, height: 792)
            case .a4:       return NSSize(width: 595, height: 842)
            }
        }
    }

    static let pdfPaperSizeDefaultsKey = "WritPDFPaperSize"
    static var pdfPaperSize: PDFPaperSize {
        get {
            let raw = UserDefaults.standard.string(forKey: pdfPaperSizeDefaultsKey) ?? PDFPaperSize.usLetter.rawValue
            return PDFPaperSize(rawValue: raw) ?? .usLetter
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: pdfPaperSizeDefaultsKey) }
    }

    /// PDF font scale (% of HTML base). Screen preview is sized for
    /// reading on a Mac; on paper that density reads loose, so the
    /// default trims it to 85%. Clamp to [60, 100]; 100 means "same as
    /// preview, skip the print stylesheet entirely".
    static let pdfFontScalePercentDefaultsKey = "WritPDFFontScalePercent"
    static let pdfFontScalePercentDefault = 85
    static var pdfFontScalePercent: Int {
        get {
            guard let stored = UserDefaults.standard.object(forKey: pdfFontScalePercentDefaultsKey) as? Int else {
                return pdfFontScalePercentDefault
            }
            return min(100, max(60, stored))
        }
        set {
            let clamped = min(100, max(60, newValue))
            UserDefaults.standard.set(clamped, forKey: pdfFontScalePercentDefaultsKey)
        }
    }

    /// Captures the live preview DOM (already-rendered math, Mermaid, etc.),
    /// wraps it with the bundled CSS, and writes the result to `url`. Falls
    /// back to the parser output if the preview can't be captured.
    static func exportHTML(preview: PreviewViewController, parsed: ParsedDocument?, source: String, theme: String, to url: URL) {
        // All the stylesheets the live preview relies on must be inlined so
        // the export renders identically without external assets:
        //   - theme.css         base structure (code blocks, alerts, etc.)
        //   - themes/<name>.css the active preview theme overlay
        //   - katex.css         math glyph fonts and spacing
        //   - github.css        highlight.js colour scheme for code blocks
        //   - custom CSS        the user's override (issue #6) if set
        let css = bundledCSS()
            + "\n" + activeThemeCSS()
            + "\n" + userCustomCSS()
            + "\n" + katexCSS()
            + "\n" + highlightCSS()
            + "\n" + tocCSS()
        let toc = includeTOC ? TOCBuilder.render(from: source) : ""
        let header = DocumentHeaderBuilder.render(frontMatter: parsed?.frontMatter)
        let title = parsed?.frontMatter?["title"] ?? "Writ Export"
        preview.capturedContentHTML { captured in
            let html: String
            if let captured, !captured.isEmpty {
                html = HTMLExporter.render(
                    body: captured,
                    theme: theme,
                    css: css,
                    toc: toc,
                    title: title,
                    docHeader: header?.html ?? "",
                    tags: header?.tags ?? []
                )
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

    /// CSS for the user's active preview theme overlay (`Resources/
    /// preview/themes/<name>.css`). Empty when the bundle lookup fails.
    private static func activeThemeCSS() -> String {
        let name = PreviewAppearance.theme.rawValue
        let subdir = "preview/themes"
        guard let url = Bundle.main.url(forResource: name, withExtension: "css", subdirectory: subdir)
                ?? Bundle.main.url(forResource: "\(subdir)/\(name)", withExtension: "css") else {
            return ""
        }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Contents of the user's custom CSS file (#6) if configured —
    /// empty otherwise.
    private static func userCustomCSS() -> String {
        guard let url = PreviewAppearance.customCSSURL else { return "" }
        // Custom CSS may live outside the app sandbox; use the
        // security-scoped resource bookmark we persisted.
        var accessed = false
        if url.startAccessingSecurityScopedResource() { accessed = true }
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
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
