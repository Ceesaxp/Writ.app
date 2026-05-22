import Cocoa
import WebKit
import os
import os.log
import WritCore
import WritRender

private let previewLog = Logger(subsystem: "org.ceesaxp.Writ", category: "preview")

/// Old-school C-API log handle. We use this from background-thread closures
/// (the PDF export heartbeat, for instance) because the newer Swift `Logger`
/// becomes MainActor-isolated by inference when captured in a closure that
/// originated on the main actor, which crashes under Swift 6 strict
/// concurrency when the timer fires off-main.
private let previewOsLog = OSLog(subsystem: "org.ceesaxp.Writ", category: "preview")

/// Hosts a persistent `WKWebView` for the preview lifetime of one document.
///
/// Loads the bundled shell `Resources/preview/index.html` exactly once.
/// Subsequent updates are applied by calling `Writ.update(payload)` via
/// `evaluateJavaScript` on the same WebKit document — `loadHTMLString` is
/// avoided per the MVP's performance constraints.
final class PreviewViewController: NSViewController {
    private(set) var webView: WKWebView!
    private(set) var isReady = false
    private var pendingPayload: PreviewBridgePayload?
    /// Latest payload we successfully sent into JS. Stashed so it can be
    /// replayed after a WKWebView reload (Cmd+R or right-click Reload),
    /// which clears the JS document.
    private var lastAppliedPayload: PreviewBridgePayload?
    private(set) var lastRenderedRevision: DocumentRevision = .zero

    private var navHelper: PreviewNavigationHelper!
    private var messageHelper: PreviewMessageHelper!

    var onReady: (() -> Void)?
    var onRendered: ((DocumentRevision) -> Void)?
    /// Called when the preview pane's top visible source line changes
    /// (preview → editor scroll sync). 1-indexed.
    var onPreviewScrolled: ((Int) -> Void)?

    private(set) var schemeHandler: WritDocSchemeHandler!

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        let messageHelper = PreviewMessageHelper()
        controller.add(messageHelper, name: "writ")
        self.messageHelper = messageHelper
        configuration.userContentController = controller

        // Register the writ-doc:// scheme so document-relative <img src>
        // attributes can be resolved without widening the WebView's
        // file:// sandbox grant.
        let handler = WritDocSchemeHandler()
        configuration.setURLSchemeHandler(handler, forURLScheme: WritDocSchemeHandler.scheme)
        self.schemeHandler = handler

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 600), configuration: configuration)
        let navHelper = PreviewNavigationHelper()
        webView.navigationDelegate = navHelper
        self.navHelper = navHelper

        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        webView.autoresizingMask = [.width, .height]

        messageHelper.owner = self
        navHelper.owner = self

        self.webView = webView
        self.view = webView
    }

    private var hasIssuedLoad = false
    /// Document directory used to resolve `writ-doc://` URLs to local files.
    /// Updated by `DocumentWindowController` when the document gains a URL.
    var documentDirectory: URL? {
        didSet { schemeHandler?.baseDirectory = documentDirectory }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        previewLog.notice("viewWillAppear, hasIssuedLoad=\(self.hasIssuedLoad)")
        if !hasIssuedLoad {
            hasIssuedLoad = true
            loadShell()
        }
    }

    deinit {
        // WKWebView config is main-actor isolated; cleanup hops to main.
        if let webView {
            Task { @MainActor in
                webView.configuration.userContentController.removeScriptMessageHandler(forName: "writ")
            }
        }
    }

    private func loadShell() {
        guard let indexURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "preview")
                ?? Bundle.main.url(forResource: "preview/index", withExtension: "html") else {
            previewLog.error("failed to find preview shell in bundle")
            return
        }
        let accessURL = Bundle.main.resourceURL ?? indexURL.deletingLastPathComponent()
        previewLog.notice("loadShell index=\(indexURL.path, privacy: .public) access=\(accessURL.path, privacy: .public)")
        webView.loadFileURL(indexURL, allowingReadAccessTo: accessURL)
    }

    func didFinishNavigationCallback() {
        previewLog.notice("webView didFinish navigation, isReady=\(self.isReady)")
        // After a reload (Cmd+R, right-click → Reload, etc.) the JS document
        // is reset, so isReady flips back to false and any payload we sent
        // before is gone. Replay it once the shell is back.
        let probeWebView = webView
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, !self.isReady else { return }
            previewLog.notice("ready signal missing after 2s — probing")
            probeWebView?.evaluateJavaScript("window.Writ && window.Writ.markReady && window.Writ.markReady()", completionHandler: nil)
        }
    }

    /// Called by the navigation helper when a reload is detected. Reverts the
    /// ready flag so the next `ready` from the freshly-loaded JS triggers a
    /// replay of the last applied payload.
    func navigationWillReload() {
        isReady = false
        if let last = lastAppliedPayload {
            pendingPayload = last
        }
    }

    func didFailNavigationCallback(_ error: Error) {
        previewLog.error("navigation failed: \(error.localizedDescription, privacy: .public)")
    }

    /// Called by the navigation helper when WebKit's WebContent process
    /// dies (out of memory, crash, sandbox kill, etc.). The WebView is
    /// still alive but has no content. Issue a fresh load of the shell
    /// so the user gets the preview back without restarting the app.
    func webContentProcessDidTerminate() {
        isReady = false
        previewLog.notice("re-loading shell after WebContent crash")
        loadShell()
    }

    func didReceiveMessage(type: String, body: [String: Any]) {
        switch type {
        case "ready":
            previewLog.notice("JS ready, pendingPayload=\(self.pendingPayload != nil ? "yes" : "no")")
            isReady = true
            onReady?()
            if let pending = pendingPayload {
                pendingPayload = nil
                apply(pending)
            }
        case "rendered":
            if let r = body["revision"] as? UInt64 {
                previewLog.notice("JS rendered rev=\(r)")
                lastRenderedRevision = DocumentRevision(r)
                onRendered?(lastRenderedRevision)
            }
        case "console":
            let level = body["level"] as? String ?? "log"
            let message = body["message"] as? String ?? ""
            if level == "error" {
                previewLog.error("JS: \(message, privacy: .public)")
            } else {
                previewLog.notice("JS \(level, privacy: .public): \(message, privacy: .public)")
            }
        case "previewScrolled":
            if let line = body["line"] as? Int {
                onPreviewScrolled?(line)
            }
        default:
            break
        }
    }

    /// Push a render result to the preview. Safe to call before the shell is
    /// ready — the latest payload is replayed when JS reports ready.
    func apply(_ payload: PreviewBridgePayload) {
        if !isReady {
            previewLog.notice("apply: not ready yet, stashing pendingPayload rev=\(payload.revision)")
            pendingPayload = payload
            return
        }
        do {
            let json = try payload.encodedAsJSON()
            let js = "window.Writ && window.Writ.update(\(json))"
            lastAppliedPayload = payload
            previewLog.notice("apply: evaluating Writ.update rev=\(payload.revision) json=\(json.utf8.count)B")
            webView.evaluateJavaScript(js) { [weak self] _, error in
                if let error {
                    previewLog.error("Writ.update failed: \(error.localizedDescription, privacy: .public)")
                } else {
                    previewLog.notice("Writ.update evaluated OK rev=\(payload.revision)")
                }
                self?.lastRenderedRevision = DocumentRevision(payload.revision)
            }
        } catch {
            previewLog.error("failed to encode payload: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setMathRenderer(_ name: String) {
        let js = "window.Writ && window.Writ.setMathRenderer('\(name)')"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func scrollToRatio(_ ratio: Double) {
        guard isReady else { return }
        let clamped = max(0, min(1, ratio))
        let js = "window.Writ && window.Writ.scrollToRatio(\(clamped))"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Block-aware scroll sync: ask the preview to align the rendered block
    /// that maps to the editor's top visible source line. If the block can't
    /// be located (e.g. the line is inside a fenced block we don't surface),
    /// the JS side falls back to proportional scroll using `fallbackRatio`.
    func scrollToSourceLine(_ line: Int, fallbackRatio: Double) {
        guard isReady else { return }
        let clampedRatio = max(0, min(1, fallbackRatio))
        let js = "window.Writ && window.Writ.scrollToSourceLine(\(line), \(clampedRatio))"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Asks the preview JS to return the current `#writ-content` innerHTML.
    /// Used by the HTML export pipeline so rendered math/mermaid output is
    /// captured in the export rather than the unrendered placeholders.
    func capturedContentHTML(completion: @escaping (String?) -> Void) {
        guard isReady else { completion(nil); return }
        let js = "(function(){var el=document.getElementById('writ-content');return el?el.innerHTML:''})()"
        webView.evaluateJavaScript(js) { value, error in
            if let error {
                previewLog.error("capture failed: \(error.localizedDescription, privacy: .public)")
                completion(nil)
                return
            }
            completion(value as? String)
        }
    }

    // MARK: - PDF export

    /// Save the preview as a paginated PDF.
    ///
    /// `WKPDFConfiguration` always produces a single-page PDF the full height
    /// of the content, so for real pagination at US Letter we drive
    /// `WKWebView.printOperation(with:)` and tell `NSPrintInfo` to save to
    /// PDF.
    ///
    /// The print operation is dispatched async with a short settle delay so
    /// that:
    ///   1. The NSSavePanel sheet is fully dismissed before the runloop has
    ///      to service the WebContent IPC the print needs (calling
    ///      `op.run()` from inside the save panel's completion handler
    ///      deadlocks on documents with heavy async JS rendering such as
    ///      Mermaid diagrams).
    ///   2. Any in-flight Mermaid/KaTeX renders have a chance to settle so
    ///      they appear in the captured pages.
    ///
    /// Completion is reported through `onExportFinished` so the UI can clear
    /// any "Exporting…" indicator.
    var onExportFinished: ((URL, Bool) -> Void)?

    /// Optional TOC HTML to prepend to the exported document body.
    /// Used by `WritDocument.exportPDF` when the user enabled the
    /// "Include TOC" setting — the document supplies the rendered
    /// nav block, the controller weaves it into the export HTML.
    /// Nil means no TOC.
    var pendingExportTOC: String?

    /// Source text to pass through to `HTMLExporter` so the title
    /// is taken from front matter when available. Set by
    /// `WritDocument.exportPDF` just before calling this method.
    var pendingExportSource: String?

    /// Standalone HTML composer used by the PDF export path.
    /// Injected by `WritDocument.exportPDF` so the controller
    /// doesn't have to drag in the asset-resolution helpers that
    /// live next to the document.
    var pendingExportHTML: ((String) -> Void)? // legacy slot; unused

    func exportPDF(to url: URL, then: (() -> Void)? = nil) {
        // Wrap the export-finished handler so the optional `then`
        // closure fires before the original completion runs and
        // is restored after.
        let originalOnFinished = onExportFinished
        if let then {
            onExportFinished = { [weak self] finishedURL, ok in
                then()
                originalOnFinished?(finishedURL, ok)
                self?.onExportFinished = originalOnFinished
            }
        }
        exportPDFImpl(to: url)
    }

    /// Offscreen WebView spun up specifically for the current PDF
    /// export. Retained for the duration of the export so it
    /// survives the async didFinish + createPDF callbacks.
    private var pdfExportWebView: WKWebView?
    private var pdfExportNavDelegate: PDFExportNavHelper?

    private func exportPDFImpl(to url: URL) {
        let target = url
        let paper = ExportService.pdfPaperSize.pointSize
        previewLog.notice("[pdf] entry target=\(target.path, privacy: .public) paper=\(ExportService.pdfPaperSize.rawValue, privacy: .public) size=\(paper.width)x\(paper.height)")
        previewLog.notice("[pdf] live webView frame=\(String(describing: self.webView?.frame), privacy: .public)")

        // Step 1: capture the live preview's #writ-content innerHTML
        // (post-KaTeX, post-Mermaid, post-hljs). We'll feed this to
        // an offscreen WKWebView whose frame we control — eliminates
        // every "what if the visible WebView is sized 0" failure mode.
        capturedContentHTML { [weak self] captured in
            guard let self else { return }
            let bodyHTML = captured ?? ""
            previewLog.notice("[pdf] captured body \(bodyHTML.utf8.count) bytes")
            self.renderOffscreenPDF(bodyHTML: bodyHTML, paper: paper, to: target)
        }
    }

    private func renderOffscreenPDF(bodyHTML: String, paper: NSSize, to target: URL) {
        // Step 2: build the standalone HTML doc — same path the
        // HTML export uses. Includes theme + KaTeX + hljs CSS
        // inlined so the offscreen WebView can render without any
        // external resource fetch.
        let css = Self.bundledExportCSS()
        let toc = ExportService.includeTOC ? (pendingExportTOC ?? "") : ""
        let title = pendingExportTitle ?? "Writ Export"
        let html = HTMLExporter.render(
            body: bodyHTML,
            theme: "auto",
            css: css + Self.pdfPageCSS(paper: paper),
            toc: toc,
            title: title
        )
        previewLog.notice("[pdf] standalone HTML composed: \(html.utf8.count) bytes")

        // Step 3: spin up an offscreen WebView. Width = paper width;
        // height starts large so the WebView's auto-layout doesn't
        // truncate content before we measure. We'll resize to
        // scrollHeight after the document loads.
        let config = WKWebViewConfiguration()
        // Hand the offscreen WebView the same writ-doc:// handler so
        // relative-path images in the captured HTML still resolve.
        let scheme = WritDocSchemeHandler()
        scheme.baseDirectory = self.documentDirectory
        config.setURLSchemeHandler(scheme, forURLScheme: WritDocSchemeHandler.scheme)

        let initialFrame = CGRect(x: 0, y: 0, width: paper.width, height: 20_000)
        let offscreen = WKWebView(frame: initialFrame, configuration: config)
        offscreen.setValue(false, forKey: "drawsBackground") // KVO trick: avoid grey background bleed in PDF output

        let navDelegate = PDFExportNavHelper { [weak self] in
            self?.offscreenDidFinishLoad(paper: paper, to: target)
        }
        offscreen.navigationDelegate = navDelegate

        self.pdfExportWebView = offscreen
        self.pdfExportNavDelegate = navDelegate

        // baseURL points into the bundle so any unexpected relative
        // resource that did sneak into the captured HTML still has
        // a chance to load.
        let baseURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "preview")?
            .deletingLastPathComponent()
        previewLog.notice("[pdf] offscreen WebView ready; loading HTML")
        offscreen.loadHTMLString(html, baseURL: baseURL)
    }

    private func offscreenDidFinishLoad(paper: NSSize, to target: URL) {
        guard let offscreen = pdfExportWebView else { return }
        previewLog.notice("[pdf] offscreen didFinish; settling 350 ms before measure")
        // Brief settle so any post-load layout / web font swap finishes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            offscreen.evaluateJavaScript("Math.max(document.documentElement.scrollHeight, document.body.scrollHeight)") { value, error in
                if let error {
                    previewLog.error("[pdf] scrollHeight probe failed: \(error.localizedDescription, privacy: .public)")
                }
                let scrollHeight: CGFloat
                if let n = value as? CGFloat { scrollHeight = n }
                else if let n = value as? Double { scrollHeight = CGFloat(n) }
                else if let n = value as? Int { scrollHeight = CGFloat(n) }
                else { scrollHeight = paper.height }
                previewLog.notice("[pdf] offscreen scrollHeight=\(scrollHeight)")
                self?.resizeAndCreatePDF(offscreen: offscreen, paper: paper, contentHeight: scrollHeight, to: target)
            }
        }
    }

    private func resizeAndCreatePDF(offscreen: WKWebView, paper: NSSize, contentHeight: CGFloat, to target: URL) {
        // Step 4: resize the offscreen WebView so its bounds enclose
        // the entire content. createPDF with rect=nil then produces
        // a single-page PDF (page width = paper.width, page height =
        // content) — no clipping, no print system involvement.
        let finalHeight = max(contentHeight, paper.height)
        offscreen.frame = CGRect(x: 0, y: 0, width: paper.width, height: finalHeight)
        previewLog.notice("[pdf] offscreen resized to \(paper.width)x\(finalHeight); 100 ms relayout settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            let config = WKPDFConfiguration()
            config.rect = nil
            offscreen.createPDF(configuration: config) { result in
                self?.finishOffscreenPDF(result: result, to: target)
            }
        }
    }

    private func finishOffscreenPDF(result: Result<Data, Error>, to target: URL) {
        let ok: Bool
        switch result {
        case .success(let data):
            previewLog.notice("[pdf] createPDF success: \(data.count) bytes")
            do {
                try data.write(to: target, options: .atomic)
                ok = true
            } catch {
                previewLog.error("[pdf] write failed: \(error.localizedDescription, privacy: .public)")
                ok = false
            }
        case .failure(let err):
            previewLog.error("[pdf] createPDF failed: \(err.localizedDescription, privacy: .public)")
            ok = false
        }
        // Tear down the offscreen WebView. Capturing here is safe
        // — the createPDF callback is the last point that needed it.
        pdfExportWebView = nil
        pdfExportNavDelegate = nil
        onExportFinished?(target, ok)
    }

    /// Source for the document <title> in the export. Set by
    /// WritDocument.exportPDF from the parsed front matter when
    /// available.
    var pendingExportTitle: String?

    /// Bundled stylesheet stack used in HTML / PDF exports.
    /// Combined ahead of time so the offscreen WebView only has to
    /// parse one `<style>` block.
    private static func bundledExportCSS() -> String {
        func read(_ resource: String, subdir: String) -> String {
            guard let url = Bundle.main.url(forResource: resource, withExtension: "css", subdirectory: subdir)
                    ?? Bundle.main.url(forResource: "\(subdir)/\(resource)", withExtension: "css") else { return "" }
            return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        return read("theme", subdir: "preview")
            + "\n" + read("katex.min", subdir: "preview/vendor/katex")
            + "\n" + read("github.min", subdir: "preview/vendor/highlight")
    }

    /// Page-shape CSS that adapts the document to the chosen paper
    /// size. The body becomes the page-width column; padding adds
    /// margins; everything reads as a printable page in the PDF.
    private static func pdfPageCSS(paper: NSSize) -> String {
        // 36 pt = 0.5 in margins on every side.
        let margin: CGFloat = 36
        let contentWidth = paper.width - 2 * margin
        return """
        @page { size: \(paper.width)pt \(paper.height)pt; margin: \(margin)pt; }
        html, body { margin: 0; padding: 0; }
        body.writ-export {
          width: \(contentWidth)pt;
          padding: \(margin)pt;
          box-sizing: content-box;
          background: white;
          color: black;
        }
        body.writ-export #writ-content { max-width: none; }
        """
    }
}

/// Plain NSObject so the offscreen PDF WebView's navigationDelegate
/// can fire without the @MainActor PreviewViewController having to
/// conform to WKNavigationDelegate itself (avoids Swift 6 isolation
/// gymnastics).
final class PDFExportNavHelper: NSObject, WKNavigationDelegate {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        super.init()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        previewLog.error("[pdf] offscreen didFail: \(error.localizedDescription, privacy: .public)")
        onFinish() // fire anyway so the user sees a failure rather than a hang
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        previewLog.error("[pdf] offscreen didFailProvisional: \(error.localizedDescription, privacy: .public)")
        onFinish()
    }
}

/// Plain NSObject delegate target — avoids any Swift 6 isolation oddities with
/// the @MainActor view controller conforming to ObjC delegate protocols.
final class PreviewNavigationHelper: NSObject, WKNavigationDelegate {
    weak var owner: PreviewViewController?

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let action = navigationAction
        let url = action.request.url

        // Reload (Cmd+R / context menu Reload / programmatic reload): let it
        // proceed, but tell the owner so it can replay the latest payload
        // when the fresh JS announces ready.
        if action.navigationType == .reload {
            owner?.navigationWillReload()
            decisionHandler(.allow)
            return
        }

        // Initial shell load: always allow.
        guard let url else { decisionHandler(.allow); return }
        if action.navigationType == .other && url.isFileURL {
            decisionHandler(.allow)
            return
        }

        // Link clicks and any other non-file navigation: only hand off
        // schemes we know are safe. A markdown document is untrusted
        // content and can carry arbitrary `app-name://` URLs that would
        // otherwise launch third-party handlers without user consent.
        if action.navigationType == .linkActivated || !url.isFileURL {
            if Self.allowExternalNavigation(to: url, owner: owner) {
                NSWorkspace.shared.open(url)
            } else {
                previewLog.notice("blocking unexpected external scheme: \(url.scheme ?? "(none)", privacy: .public)")
            }
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    /// Whitelist of schemes the preview is allowed to hand off to the OS.
    /// `file:` is gated behind a confirmation alert because it can target
    /// any path the sandbox grants access to.
    private static func allowExternalNavigation(to url: URL, owner: PreviewViewController?) -> Bool {
        switch (url.scheme ?? "").lowercased() {
        case "http", "https", "mailto":
            return true
        case "file":
            return confirmFileNavigation(to: url, owner: owner)
        default:
            return false
        }
    }

    private static func confirmFileNavigation(to url: URL, owner: PreviewViewController?) -> Bool {
        _ = owner // reserved for future sheet-modal attachment
        let alert = NSAlert()
        alert.messageText = "Open “\(url.lastPathComponent)”?"
        alert.informativeText = "This document is asking to open a local file:\n\n\(url.path)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        // The navigation decision handler is synchronous, so we have to
        // use runModal rather than attaching as a sheet. WKNavigation
        // ignores the WebView while the alert is up — which is the
        // intended behaviour.
        return alert.runModal() == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        owner?.didFinishNavigationCallback()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        previewLog.error("navigation didFail: \(error.localizedDescription, privacy: .public)")
        owner?.didFailNavigationCallback(error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        previewLog.error("navigation didFailProvisional: \(error.localizedDescription, privacy: .public)")
        owner?.didFailNavigationCallback(error)
    }

    // Fires when WebKit's WebContent process terminates — the most common
    // cause of "WKWebView is alive but never loaded anything" since the
    // delegate methods above never fire if the process dies during the
    // initial load.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        previewLog.error("WebContent process terminated — preview will be unable to load anything")
        owner?.webContentProcessDidTerminate()
    }

}

/// NSObject target used by `NSPrintOperation.runModal(for:delegate:didRun:contextInfo:)`.
final class PreviewMessageHelper: NSObject, WKScriptMessageHandler {
    weak var owner: PreviewViewController?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "writ" else { return }
        let body = message.body as? [String: Any] ?? [:]
        let type = body["type"] as? String ?? "?"
        owner?.didReceiveMessage(type: type, body: body)
    }
}
