import Cocoa
import WritCore
import WritParser
import WritRender

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
        self.scheduler = PreviewScheduler(parser: parser)
    }

    deinit {
        pumpTask?.cancel()
    }

    func attach(preview: PreviewViewController, statusBar: StatusBarViewController) {
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
        statusBar?.update(byteCount: source.utf8.count, lineCount: nil, status: nil)
        Task { await scheduler.scheduleUpdate(source: source) }
    }

    func forceRefresh(source: String) {
        statusBar?.update(byteCount: source.utf8.count, lineCount: nil, status: nil)
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
            statusBar?.update(byteCount: nil, lineCount: nil, status: .rendering(revision: revision))
        case .completed(let parsed):
            currentParsedDocument = parsed
            let payload = PreviewBridgePayload(revision: parsed.revision, html: parsed.html, blocks: parsed.blocks, theme: theme, documentBaseURL: documentDirectory?.absoluteString)
            preview?.apply(payload)
            let total = parsed.parseDuration + parsed.renderDuration
            statusBar?.update(byteCount: nil, lineCount: nil, status: .current(revision: parsed.revision, duration: total))
        case .cancelled(let revision):
            statusBar?.update(byteCount: nil, lineCount: nil, status: .stale(revision: revision))
        case .failed(let revision, let message):
            statusBar?.update(byteCount: nil, lineCount: nil, status: .failed(revision: revision, message: message))
        }
    }
}
