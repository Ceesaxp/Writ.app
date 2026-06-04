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
    /// of the content, so for real pagination at the chosen paper size we
    /// drive `WKWebView.printOperation(with:)` and tell `NSPrintInfo` to save
    /// to PDF. The print operation honours `@page` / page-break CSS rules and
    /// natively paginates — `createPDF` does not.
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

    /// Optional TOC HTML to prepend to the live preview before the print
    /// operation runs. Set by `WritDocument.exportPDF` when the user has
    /// enabled the "Include TOC" setting. `exportPDF` injects the block,
    /// runs the print, and removes the block again on completion — so the
    /// visible preview is back to its normal state by the time the user
    /// sees the result.
    var pendingExportTOC: String?

    /// Optional document-header HTML (`<header class="writ-doc-header">…`)
    /// to prepend to the live preview before printing. Set by
    /// `WritDocument.exportPDF` when front matter carries any of
    /// title / author / date / description. When present, the export
    /// also flips `body.writ-export` so the bundled CSS hides the
    /// dimmed `<dl class="writ-front-matter">` card for the duration
    /// of the print. Both are torn down on completion.
    var pendingExportDocHeader: String?

    func exportPDF(to url: URL, then: (() -> Void)? = nil) {
        // The user-supplied `then` runs first on completion, then any
        // pre-existing `onExportFinished`, and finally the handler is
        // restored. Lets callers attach cleanup without trampling each
        // other.
        let originalOnFinished = onExportFinished
        let toc = (pendingExportTOC?.isEmpty == false) ? pendingExportTOC : nil
        let docHeader = (pendingExportDocHeader?.isEmpty == false) ? pendingExportDocHeader : nil
        let fontScale = ExportService.pdfFontScalePercent
        let needsFontScale = fontScale != 100
        // Wrap the completion so it tears down every injected block in
        // reverse-creation order, runs the caller's `then`, then
        // restores the original `onExportFinished`. Always wrapped —
        // even when nothing was injected — so the `then`/restore wiring
        // is uniform.
        onExportFinished = { [weak self] finishedURL, ok in
            if needsFontScale { self?.removePDFExportFontScale() }
            if docHeader != nil { self?.removePDFExportDocHeader() }
            if toc != nil { self?.removePDFExportTOC() }
            then?()
            originalOnFinished?(finishedURL, ok)
            self?.onExportFinished = originalOnFinished
            self?.pendingExportTOC = nil
            self?.pendingExportDocHeader = nil
        }
        // Compose the pre-print pipeline back-to-front: each stage
        // calls the next one in its completion handler.
        let runExport: () -> Void = { [weak self] in self?.exportPDFImpl(to: url) }
        let afterFontScale: () -> Void = runExport
        let afterDocHeader: () -> Void = { [weak self] in
            if needsFontScale {
                self?.insertPDFExportFontScale(fontScale, completion: afterFontScale)
            } else {
                afterFontScale()
            }
        }
        let afterTOC: () -> Void = { [weak self] in
            if let docHeader {
                self?.insertPDFExportDocHeader(docHeader, completion: afterDocHeader)
            } else {
                afterDocHeader()
            }
        }
        if let toc {
            insertPDFExportTOC(toc, completion: afterTOC)
        } else {
            afterTOC()
        }
    }

    /// Inserts an export-only TOC block at the top of `#writ-content`.
    /// The block carries a sentinel id so `removePDFExportTOC` can
    /// take it out again after the print operation finishes.
    private func insertPDFExportTOC(_ tocHTML: String, completion: @escaping () -> Void) {
        let escaped = tocHTML
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
        let js = """
            (function(){
              var root = document.getElementById('writ-content');
              if (!root) return;
              var holder = document.createElement('div');
              holder.id = 'writ-export-toc';
              holder.innerHTML = `\(escaped)`;
              root.insertBefore(holder, root.firstChild);
            })()
            """
        webView.evaluateJavaScript(js) { _, _ in completion() }
    }

    private func removePDFExportTOC() {
        let js = """
            (function(){
              var el = document.getElementById('writ-export-toc');
              if (el && el.parentNode) el.parentNode.removeChild(el);
            })()
            """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Inserts the export-only `<header class="writ-doc-header">` block
    /// above all content inside `#writ-content` AND flips
    /// `body.writ-export` so the bundled CSS hides the dimmed
    /// `<dl class="writ-front-matter">` card. Both are torn down by
    /// `removePDFExportDocHeader()` after the print operation finishes.
    private func insertPDFExportDocHeader(_ headerHTML: String, completion: @escaping () -> Void) {
        let escaped = headerHTML
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
        let js = """
            (function(){
              var root = document.getElementById('writ-content');
              if (!root) return;
              var prior = document.getElementById('writ-export-doc-header');
              if (prior && prior.parentNode) prior.parentNode.removeChild(prior);
              var holder = document.createElement('div');
              holder.id = 'writ-export-doc-header';
              holder.innerHTML = `\(escaped)`;
              root.insertBefore(holder, root.firstChild);
              document.body.classList.add('writ-export');
            })()
            """
        webView.evaluateJavaScript(js) { _, _ in completion() }
    }

    private func removePDFExportDocHeader() {
        let js = """
            (function(){
              var el = document.getElementById('writ-export-doc-header');
              if (el && el.parentNode) el.parentNode.removeChild(el);
              document.body.classList.remove('writ-export');
            })()
            """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Injects a `@media print { html { font-size: <pct>% } }` style tag
    /// so the WKWebView print path scales body + heading rhythm down to
    /// the user's PDF density preference. `html` is the right scope:
    /// headings sized in `rem` follow the root, and `em`-based child
    /// rules cascade from `body`.
    private func insertPDFExportFontScale(_ percent: Int, completion: @escaping () -> Void) {
        let clamped = min(100, max(60, percent))
        let js = """
            (function(){
              var prior = document.getElementById('writ-export-font-scale');
              if (prior && prior.parentNode) prior.parentNode.removeChild(prior);
              var style = document.createElement('style');
              style.id = 'writ-export-font-scale';
              style.textContent = '@media print { html { font-size: \(clamped)% } }';
              document.head.appendChild(style);
            })()
            """
        webView.evaluateJavaScript(js) { _, _ in completion() }
    }

    private func removePDFExportFontScale() {
        let js = """
            (function(){
              var el = document.getElementById('writ-export-font-scale');
              if (el && el.parentNode) el.parentNode.removeChild(el);
            })()
            """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    private func exportPDFImpl(to url: URL) {
        let host = webView
        let target = url
        let paper = ExportService.pdfPaperSize.pointSize
        previewLog.notice("[pdf] entry target=\(target.path, privacy: .public) paper=\(ExportService.pdfPaperSize.rawValue, privacy: .public) size=\(paper.width)x\(paper.height)")
        previewLog.notice("[pdf] webView frame=\(String(describing: host?.frame), privacy: .public)")

        // Probe how loaded the WebKit content is before we begin so we can
        // tell "PDF export is slow because there's a lot of mermaid" from
        // "PDF export is hung in the print operation".
        host?.evaluateJavaScript("""
            (function() {
              var imgs = document.querySelectorAll('img').length;
              var pre = document.querySelectorAll('pre').length;
              var mermaid = document.querySelectorAll('.writ-mermaid').length;
              var mermaidSvgs = document.querySelectorAll('.writ-mermaid svg').length;
              var math = document.querySelectorAll('.writ-math-block,.writ-math-inline').length;
              var bodyLen = (document.body.innerHTML || '').length;
              return JSON.stringify({imgs, pre, mermaid, mermaidSvgs, math, bodyLen});
            })()
        """) { value, _ in
            previewLog.notice("[pdf] dom snapshot: \(String(describing: value), privacy: .public)")
        }

        // After settle delay, run the paginated print path. If it
        // produces an unusable file (missing or tiny), we fall back
        // to WKWebView.createPDF — single page, but reliable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            previewLog.notice("[pdf] settle delay elapsed, building NSPrintInfo")
            guard let host else {
                previewLog.error("[pdf] aborting: webview gone")
                self?.onExportFinished?(target, false)
                return
            }

            // Per-document NSPrintInfo (not the shared one — the
            // shared instance can carry stale jobSavingURL across
            // exports and we'd write into the previous target).
            let info = NSPrintInfo()
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = target as NSURL
            info.paperSize = paper
            // `paperSize` must be matched by the bounds inside the
            // dictionary; some macOS releases clear `paperSize`
            // back to the shared default if the matched bounds key
            // isn't set explicitly.
            info.dictionary()[NSPrintInfo.AttributeKey.paperSize] = NSValue(size: paper)
            info.topMargin = 36
            info.bottomMargin = 36
            info.leftMargin = 36
            info.rightMargin = 36
            info.orientation = .portrait
            info.horizontalPagination = .fit
            info.verticalPagination = .automatic
            info.isHorizontallyCentered = false
            info.isVerticallyCentered = false

            previewLog.notice("[pdf] printOperation(with:) building")
            let op = host.printOperation(with: info)
            op.showsPrintPanel = false
            op.showsProgressPanel = false

            // `NSPrintOperation.run()` is synchronous and blocks the calling
            // thread until the print job is finished. For WKWebView's print
            // pipeline that's a deadlock: the operation needs to IPC with
            // the WebContent process to lay out the content into pages, but
            // the IPC can't be serviced because the main thread is blocked
            // inside run().
            //
            // `runModal(for:delegate:didRun:contextInfo:)` with panels
            // disabled doesn't actually show a panel — it runs the
            // operation in a modal session that yields to the runloop, so
            // WebContent IPC can complete. We're notified via the @objc
            // selector when it finishes.
            let runStart = Date()
            let heartbeat = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            heartbeat.schedule(deadline: .now() + 1, repeating: 1)
            heartbeat.setEventHandler { @Sendable in
                let elapsed = Date().timeIntervalSince(runStart)
                os_log("[pdf] heartbeat: runModal in flight for %.1fs", log: previewOsLog, type: .info, elapsed)
            }
            heartbeat.resume()

            // The completion handler needs to outlive this scope — store
            // it on self so it isn't deallocated before the @objc
            // callback fires.
            let completion = PrintCompletionHandler(target: target, runStart: runStart, heartbeat: heartbeat) { [weak self] url, ok in
                self?.printDidComplete(url, success: ok, runStart: runStart, heartbeat: heartbeat)
            }
            self?.activePrintCompletion = completion

            guard let window = host.window ?? NSApplication.shared.mainWindow else {
                previewLog.error("[pdf] no host window for runModal — falling back to run()")
                let started = op.run()
                heartbeat.cancel()
                let exists = FileManager.default.fileExists(atPath: target.path)
                let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? 0
                previewLog.notice("[pdf] fallback op.run() returned \(started), exists=\(exists), size=\(size)")
                self?.onExportFinished?(target, exists && size > 0)
                self?.activePrintCompletion = nil
                return
            }

            previewLog.notice("[pdf] runModal(for:delegate:didRun:contextInfo:) entering")
            op.runModal(
                for: window,
                delegate: completion,
                didRun: #selector(PrintCompletionHandler.printOperationDidRun(_:success:contextInfo:)),
                contextInfo: nil
            )
        }
    }

    /// Strong reference to the print-completion callback target so it
    /// survives the async `runModal` callback path.
    private var activePrintCompletion: PrintCompletionHandler?

    fileprivate func printDidComplete(_ url: URL, success: Bool, runStart: Date, heartbeat: DispatchSourceTimer) {
        heartbeat.cancel()
        let duration = Date().timeIntervalSince(runStart)
        let exists = FileManager.default.fileExists(atPath: url.path)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        previewLog.notice("[pdf] runModal completed: success=\(success), duration=\(String(format: "%.2fs", duration), privacy: .public), exists=\(exists), size=\(size)")

        // Blank-PDF defense. macOS 26 has been intermittently dropping
        // the runModal .save output — the print operation returns
        // success=true but the file is either missing or contains a
        // single blank page (<2 KB). When that happens, fall back to
        // WKWebView.createPDF which captures the live WebView content
        // directly. Single page, but legible content beats a blank
        // multi-pager.
        let suspect = !exists || size < 2048
        if suspect {
            previewLog.notice("[pdf] suspicious output (size=\(size)); falling back to createPDF")
            fallbackCreatePDF(to: url) { [weak self] ok in
                self?.onExportFinished?(url, ok)
                self?.activePrintCompletion = nil
            }
            return
        }
        onExportFinished?(url, exists && size > 0)
        activePrintCompletion = nil
    }

    /// Fallback: render the WebView contents to a single-page PDF via
    /// the modern API. Sidesteps the NSPrintInfo / jobSavingURL dance
    /// entirely.
    private func fallbackCreatePDF(to url: URL, completion: @escaping (Bool) -> Void) {
        guard let host = webView else { completion(false); return }
        let config = WKPDFConfiguration()
        config.rect = nil
        host.createPDF(configuration: config) { result in
            switch result {
            case .success(let data):
                do {
                    try data.write(to: url, options: .atomic)
                    previewLog.notice("[pdf] createPDF wrote \(data.count) bytes")
                    completion(true)
                } catch {
                    previewLog.error("[pdf] createPDF write failed: \(error.localizedDescription, privacy: .public)")
                    completion(false)
                }
            case .failure(let err):
                previewLog.error("[pdf] createPDF failed: \(err.localizedDescription, privacy: .public)")
                completion(false)
            }
        }
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

        // Same-document fragment-only navigation (`[Foo](#section)`):
        // let WebKit scroll to the anchor in the preview shell. Without
        // this, fragment clicks fall through to the external-handoff
        // path below and the user gets a "Writ is trying to open
        // preview.html" warning instead of the expected scroll.
        if action.navigationType == .linkActivated,
           url.fragment != nil,
           let current = webView.url,
           url.path == current.path,
           url.host == current.host,
           url.scheme == current.scheme {
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

/// NSObject target used by `NSPrintOperation.runModal(for:delegate:didRun:contextInfo:)`.
/// AppKit calls back via a fixed @objc selector when the print job finishes;
/// we forward that into a Swift closure so the calling view controller can
/// finish in idiomatic Swift.
final class PrintCompletionHandler: NSObject {
    private let target: URL
    private let runStart: Date
    private let heartbeat: DispatchSourceTimer
    private let completion: (URL, Bool) -> Void

    init(target: URL, runStart: Date, heartbeat: DispatchSourceTimer, completion: @escaping (URL, Bool) -> Void) {
        self.target = target
        self.runStart = runStart
        self.heartbeat = heartbeat
        self.completion = completion
        super.init()
    }

    @objc func printOperationDidRun(_ printOperation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        let exists = FileManager.default.fileExists(atPath: target.path)
        let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? 0
        previewLog.notice("[pdf] printOperationDidRun: success=\(success), exists=\(exists), size=\(size)")
        completion(target, success && exists && size > 0)
    }
}
