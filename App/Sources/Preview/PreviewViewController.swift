import Cocoa
import WebKit
import os
import WritCore
import WritRender

private let previewLog = Logger(subsystem: "org.ceesaxp.Writ", category: "preview")

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
    private(set) var lastRenderedRevision: DocumentRevision = .zero

    private var navHelper: PreviewNavigationHelper!
    private var messageHelper: PreviewMessageHelper!

    var onReady: (() -> Void)?
    var onRendered: ((DocumentRevision) -> Void)?

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        let messageHelper = PreviewMessageHelper()
        controller.add(messageHelper, name: "writ")
        self.messageHelper = messageHelper
        configuration.userContentController = controller

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
    /// Document directory used to expand the read-access scope so relative
    /// image references in the markdown source resolve to neighbouring files.
    var documentDirectory: URL?

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
        // The widest enclosing directory that contains both the shell and the
        // document gives WKWebView permission to load images that live next
        // to the document. Falls back to the bundle's Resources when no doc
        // URL is known yet.
        let accessURL = widestAccessScope(forShell: indexURL, documentDir: documentDirectory)
        webView.loadFileURL(indexURL, allowingReadAccessTo: accessURL)
    }

    private func widestAccessScope(forShell shellURL: URL, documentDir: URL?) -> URL {
        guard let documentDir else {
            return Bundle.main.resourceURL ?? shellURL.deletingLastPathComponent()
        }
        let bundleResources = Bundle.main.resourceURL ?? shellURL.deletingLastPathComponent()
        return commonAncestor(bundleResources, documentDir)
    }

    private func commonAncestor(_ a: URL, _ b: URL) -> URL {
        let aComponents = a.standardizedFileURL.pathComponents
        let bComponents = b.standardizedFileURL.pathComponents
        var common: [String] = []
        for (x, y) in zip(aComponents, bComponents) {
            if x == y { common.append(x) } else { break }
        }
        if common.isEmpty || common == ["/"] {
            return URL(fileURLWithPath: "/")
        }
        return URL(fileURLWithPath: common.joined(separator: "/"))
    }

    func didFinishNavigationCallback() {
        // Probe-back: if the JS side hasn't announced "ready" within a short
        // window after navigation finishes, ask it to. Defends against a cold
        // WebKit launch where the first script-message round-trip is dropped.
        let probeWebView = webView
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, !self.isReady else { return }
            previewLog.notice("ready signal missing after 2s — probing")
            probeWebView?.evaluateJavaScript("window.Writ && window.Writ.markReady && window.Writ.markReady()", completionHandler: nil)
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

    func exportPDF(to url: URL) {
        let config = WKPDFConfiguration()
        webView.createPDF(configuration: config) { result in
            switch result {
            case .success(let data):
                do { try data.write(to: url) }
                catch { previewLog.error("PDF write failed: \(error.localizedDescription, privacy: .public)") }
            case .failure(let error):
                previewLog.error("PDF creation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// Plain NSObject delegate target — avoids any Swift 6 isolation oddities with
/// the @MainActor view controller conforming to ObjC delegate protocols.
final class PreviewNavigationHelper: NSObject, WKNavigationDelegate {
    weak var owner: PreviewViewController?

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

final class PreviewMessageHelper: NSObject, WKScriptMessageHandler {
    weak var owner: PreviewViewController?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "writ" else { return }
        let body = message.body as? [String: Any] ?? [:]
        let type = body["type"] as? String ?? "?"
        owner?.didReceiveMessage(type: type, body: body)
    }
}
