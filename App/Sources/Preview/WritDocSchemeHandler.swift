import Foundation
import WebKit
import UniformTypeIdentifiers
import os

private let schemeLog = Logger(subsystem: "org.ceesaxp.Writ", category: "scheme")

/// Resolves `writ-doc://<relative-path>` URLs from the preview's `<img>` and
/// other asset references against the currently-open document's directory.
///
/// Why this exists: a sandboxed WKWebView refuses to load `file://` URLs
/// that fall outside its `allowingReadAccessTo` scope, and widening that
/// scope to the document's directory failed when the document lived outside
/// the bundle tree (the OS rejected the load entirely — see crash analysis
/// in commit `c733434`).
///
/// By going through a custom URL scheme handler we sidestep WebKit's file
/// sandbox: we do the file read ourselves with whatever read access the
/// host app already has (NSDocument grants access to the document directory
/// for the lifetime of the document window) and stream the bytes back as
/// `Data:` to the WebView.
@MainActor
final class WritDocSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "writ-doc"

    /// Per-WebView base directory; set by PreviewViewController each time the
    /// document URL is known. `nil` means "no document, deny all requests".
    var baseDirectory: URL?

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let request = urlSchemeTask.request
        guard let url = request.url, url.scheme == Self.scheme else {
            schemeLog.error("rejecting request with wrong scheme: \(String(describing: request.url?.absoluteString), privacy: .public)")
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        guard let baseDirectory else {
            schemeLog.error("no base directory configured; denying \(url.path, privacy: .public)")
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        // JS uses the empty-host form `writ-doc:///relative/path.svg` so the
        // `url.path` component is the encoded relative path inside the
        // document directory. Decode percent-escapes and strip the leading
        // slash before resolving.
        let pathComponent = url.path.removingPercentEncoding ?? url.path
        let trimmed = pathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let candidate = baseDirectory.appendingPathComponent(trimmed).standardizedFileURL

        // Path-traversal guard: ensure the resolved path is still inside
        // baseDirectory after standardising the URL (eliminates `..` escapes).
        let baseStandard = baseDirectory.standardizedFileURL
        guard candidate.path.hasPrefix(baseStandard.path) else {
            schemeLog.error("rejecting traversal: \(candidate.path, privacy: .public) escapes \(baseStandard.path, privacy: .public)")
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }

        do {
            let data = try Data(contentsOf: candidate, options: .mappedIfSafe)
            let mime = mimeType(for: candidate)
            let response = URLResponse(
                url: url,
                mimeType: mime,
                expectedContentLength: data.count,
                textEncodingName: nil
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            schemeLog.error("read failed for \(candidate.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        // Reads are synchronous; nothing to cancel.
    }

    private func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType {
            return type
        }
        // Common fallbacks the preview cares about.
        switch url.pathExtension.lowercased() {
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }
}
