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
        // The read-access scope must be inside the app's sandbox grant or
        // WebKit refuses to load even the shell itself. Bundle Resources
        // covers the shell, vendor JS, and CSS. Document-relative images
        // need a custom URL scheme handler (deferred — tracked in TODO M2).
        let accessURL = Bundle.main.resourceURL ?? indexURL.deletingLastPathComponent()
        webView.loadFileURL(indexURL, allowingReadAccessTo: accessURL)
    }

    func didFinishNavigationCallback() {
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

    func didReceiveMessage(type: String, body: [String: Any]) {
        switch type {
        case "ready":
            isReady = true
            onReady?()
            if let pending = pendingPayload {
                pendingPayload = nil
                apply(pending)
            }
        case "rendered":
            if let r = body["revision"] as? UInt64 {
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
            pendingPayload = payload
            return
        }
        do {
            let json = try payload.encodedAsJSON()
            let js = "window.Writ && window.Writ.update(\(json))"
            lastAppliedPayload = payload
            webView.evaluateJavaScript(js) { [weak self] _, error in
                if let error {
                    previewLog.error("Writ.update failed: \(error.localizedDescription, privacy: .public)")
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

    /// Inserts an export-only TOC block at the top of `#writ-content`.
    /// Used by the PDF export flow when the user has enabled TOC in
    /// Settings; the block carries a sentinel id so `removePDFExportTOC`
    /// can take it out again after the print operation finishes.
    func insertPDFExportTOC(_ tocHTML: String, completion: @escaping () -> Void) {
        // Escape backticks/backslashes for safe embedding in JS template.
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

    func removePDFExportTOC() {
        let js = """
            (function(){
              var el = document.getElementById('writ-export-toc');
              if (el && el.parentNode) el.parentNode.removeChild(el);
            })()
            """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func exportPDF(to url: URL, then: (() -> Void)? = nil) {
        let originalOnFinished = onExportFinished
        if let then {
            // Chain the user's completion + the TOC-removal hook so
            // the export call site doesn't have to remember either.
            onExportFinished = { [weak self] finishedURL, ok in
                then()
                originalOnFinished?(finishedURL, ok)
                self?.onExportFinished = originalOnFinished
            }
        }
        exportPDFImpl(to: url)
    }

    private func exportPDFImpl(to url: URL) {
        let host = webView
        let target = url
        previewLog.notice("[pdf] entry: target=\(target.path, privacy: .public)")

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

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            previewLog.notice("[pdf] settle delay elapsed, building NSPrintInfo")
            guard let host else {
                previewLog.error("[pdf] aborting: webview gone")
                self?.onExportFinished?(target, false)
                return
            }

            let info = NSPrintInfo()
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = target as NSURL
            info.paperSize = NSSize(width: 612, height: 792) // US Letter
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
            previewLog.notice("[pdf] op built, showsPrintPanel=\(op.showsPrintPanel) showsProgressPanel=\(op.showsProgressPanel)")

            // `NSPrintOperation.run()` is synchronous and blocks the calling
            // thread until the print job is finished. For WKWebView's print
            // pipeline that's a deadlock: the operation needs to IPC with
            // the WebContent process to lay out the content into pages, but
            // the IPC can't be serviced because the main thread is blocked
            // inside run(). Confirmed by 38s of heartbeats with no return
            // on integration-architecture.md (4 Mermaid SVGs, 8 <pre>, ~100KB
            // body HTML).
            //
            // The fix is `runModal(for:delegate:didRun:contextInfo:)`. With
            // showsPrintPanel = false it doesn't actually show a panel — it
            // just runs the operation in a modal session that yields to the
            // runloop, so WebContent IPC can complete. We're notified via
            // the @objc selector when it finishes.
            let runStart = Date()
            let heartbeat = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            heartbeat.schedule(deadline: .now() + 1, repeating: 1)
            heartbeat.setEventHandler { @Sendable in
                let elapsed = Date().timeIntervalSince(runStart)
                os_log("[pdf] heartbeat: runModal in flight for %.1fs", log: previewOsLog, type: .info, elapsed)
            }
            heartbeat.resume()

            // The completion handler needs to outlive this scope — store it
            // on self so it isn't deallocated before the @objc callback fires.
            let completion = PrintCompletionHandler(target: target, runStart: runStart, heartbeat: heartbeat) { [weak self] url, ok in
                self?.onExportFinished?(url, ok)
            }
            self?.activePrintCompletion = completion

            guard let window = host.window ?? NSApplication.shared.mainWindow else {
                previewLog.error("[pdf] no host window for runModal — falling back to run()")
                let started = op.run()
                heartbeat.cancel()
                let exists = FileManager.default.fileExists(atPath: target.path)
                let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? 0
                previewLog.notice("[pdf] fallback op.run() returned \(started), file exists=\(exists), size=\(size)")
                self?.onExportFinished?(target, exists && size > 0)
                self?.activePrintCompletion = nil
                return
            }

            previewLog.notice("[pdf] runModal(for:delegate:didRun:contextInfo:) entering")
            os_log("[pdf] runModal entering (non-blocking, will service runloop)", log: previewOsLog, type: .info)
            op.runModal(
                for: window,
                delegate: completion,
                didRun: #selector(PrintCompletionHandler.printOperationDidRun(_:success:contextInfo:)),
                contextInfo: nil
            )
        }
    }

    /// Strong reference to the print-completion callback target so it survives
    /// the async `runModal` callback path.
    private var activePrintCompletion: PrintCompletionHandler?

    fileprivate func printDidComplete(_ url: URL, success: Bool, runStart: Date, heartbeat: DispatchSourceTimer) {
        heartbeat.cancel()
        let duration = Date().timeIntervalSince(runStart)
        let exists = FileManager.default.fileExists(atPath: url.path)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        os_log("[pdf] runModal completed after %.2fs", log: previewOsLog, type: .info, duration)
        previewLog.notice("[pdf] runModal completed: success=\(success), duration=\(String(format: "%.2fs", duration), privacy: .public), file exists=\(exists), size=\(size)")
        onExportFinished?(url, exists && size > 0)
        activePrintCompletion = nil
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
        heartbeat.cancel()
        let duration = Date().timeIntervalSince(runStart)
        os_log("[pdf] printOperationDidRun: success=%d after %.2fs", log: previewOsLog, type: .info, success ? 1 : 0, duration)
        let exists = FileManager.default.fileExists(atPath: target.path)
        let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? 0
        previewLog.notice("[pdf] printOperationDidRun: success=\(success), file exists=\(exists), size=\(size)")
        completion(target, success && exists && size > 0)
    }
}

final class PreviewMessageHelper: NSObject, WKScriptMessageHandler {
    weak var owner: PreviewViewController?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "writ" else { return }
        let body = message.body as? [String: Any] ?? [:]
        let type = body["type"] as? String ?? "?"
        owner?.didReceiveMessage(type: type, body: body)
    }
}
