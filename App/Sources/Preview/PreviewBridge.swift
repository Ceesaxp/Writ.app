import Cocoa
import os
import WritCore
import WritParser
import WritRender

private let bridgeLog = Logger(subsystem: "org.ceesaxp.Writ", category: "bridge")

/// Connects ``PreviewScheduler`` events to a ``PreviewViewController`` on the
/// main actor.
///
/// One bridge per document — owned by ``WritDocument``. The bridge:
/// 1. Forwards edit notifications and manual refreshes to the scheduler.
/// 2. Listens to the scheduler's `AsyncStream` for parser results.
/// 3. Discards stale results before dispatching to the WebView.
/// 4. Surfaces render status to the status bar.
@MainActor
final class PreviewBridge {
    private let scheduler: PreviewScheduler
    private weak var preview: PreviewViewController?
    private weak var statusBar: StatusBarViewController?
    private(set) var theme: String = "auto"
    private(set) var currentParsedDocument: ParsedDocument?
    private var pumpTask: Task<Void, Never>?

    /// Directory of the document on disk, used so relative image references
    /// resolve from the preview's perspective. Updated when the document
    /// gains or changes its file URL.
    var documentDirectory: URL?

    init(parser: any MarkdownParser) {
        let mode = LargeDocumentMode(thresholds: .fromDefaults())
        self.scheduler = PreviewScheduler(parser: parser, largeMode: mode)
    }

    deinit {
        pumpTask?.cancel()
    }

    func attach(preview: PreviewViewController, statusBar: StatusBarViewController) {
        bridgeLog.notice("attach(preview:statusBar:)")
        self.preview = preview
        self.statusBar = statusBar
        startPumpIfNeeded()
    }

    func setTheme(_ theme: String) {
        self.theme = theme
        if let parsed = currentParsedDocument {
            let payload = PreviewBridgePayload(revision: parsed.revision, html: parsed.html, blocks: parsed.blocks, theme: theme, documentBaseURL: documentDirectory?.absoluteString)
            preview?.apply(payload)
        }
    }

    func scheduleUpdate(source: String) {
        // The editor delegate already updated the status bar with the
        // byte count on the keystroke; skipping a duplicate update here
        // saves an `utf8.count` walk per call (O(N) for NSString-bridged
        // strings, which `NSTextView.string` returns).
        Task { await scheduler.scheduleUpdate(source: source) }
    }

    func forceRefresh(source: String) {
        Task { await scheduler.forceRefresh(source: source) }
    }

    func cancelAll() {
        Task { await scheduler.cancelAll() }
    }

    private func startPumpIfNeeded() {
        if pumpTask != nil { return }
        let stream = scheduler.output
        pumpTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: PreviewScheduler.Event) {
        switch event {
        case .started(let revision):
            bridgeLog.notice("scheduler.started rev=\(revision.value)")
            statusBar?.update(byteCount: nil, lineCount: nil, status: .rendering(revision: revision))
        case .completed(let parsed):
            bridgeLog.notice("scheduler.completed rev=\(parsed.revision.value) html=\(parsed.html.utf8.count)B blocks=\(parsed.blocks.count)")
            currentParsedDocument = parsed
            let payload = PreviewBridgePayload(revision: parsed.revision, html: parsed.html, blocks: parsed.blocks, theme: theme, documentBaseURL: documentDirectory?.absoluteString)
            if let p = preview {
                bridgeLog.notice("forwarding payload to preview")
                p.apply(payload)
            } else {
                bridgeLog.error("preview is nil; cannot forward payload")
            }
            let total = parsed.parseDuration + parsed.renderDuration
            statusBar?.update(byteCount: nil, lineCount: nil, status: .current(revision: parsed.revision, duration: total))
        case .cancelled(let revision):
            statusBar?.update(byteCount: nil, lineCount: nil, status: .stale(revision: revision))
        case .failed(let revision, let message):
            statusBar?.update(byteCount: nil, lineCount: nil, status: .failed(revision: revision, message: message))
        }
    }
}
