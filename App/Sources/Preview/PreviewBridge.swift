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

    /// Whether the newest render pass is allowed to resolve PlantUML
    /// remotely. Stashed rather than recomputed so `setTheme` can't
    /// silently disable rendering that is already in flight.
    private var plantUMLEnabled = false
    /// The in-flight remote resolve, if any. Exactly one at a time: a new
    /// render pass cancels its predecessor, which is the main thing
    /// keeping a typing burst from fanning out into a request per pause.
    private var plantUMLTask: Task<Void, Never>?
    /// Lives for the bridge's lifetime so repeats of an unchanged diagram
    /// are served locally instead of re-POSTed.
    private let plantUMLCache = TechnicalBlockCache()
    private var plantUMLResolver: PlantUMLBlockResolver?
    /// Endpoint the current resolver was built for. A change rebuilds the
    /// resolver, and because the endpoint string is also its
    /// `rendererVersion` the cache entries from the old server are left
    /// behind rather than served.
    private var plantUMLResolverEndpoint: String?

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
        plantUMLTask?.cancel()
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
            // Reuse the flag the render pass computed instead of asking
            // again: a theme switch must not flip a document that is
            // mid-resolve back to "not configured".
            let payload = PreviewBridgePayload(revision: parsed.revision, html: parsed.html, blocks: parsed.blocks, theme: theme, documentBaseURL: documentDirectory?.absoluteString, plantUMLEnabled: plantUMLEnabled)
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
        plantUMLTask?.cancel()
        plantUMLTask = nil
        Task { await scheduler.cancelAll() }
    }

    /// Kicks off the out-of-band PlantUML resolve for a finished render
    /// pass, replacing any resolve still running for an older one.
    ///
    /// Called only *after* the payload has been handed to the preview, so
    /// nothing here is on the path that makes the document appear.
    private func startPlantUMLResolve(for parsed: ParsedDocument, enabled: Bool) {
        plantUMLTask?.cancel()
        plantUMLTask = nil
        guard enabled, let endpoint = PlantUMLSettings.endpointURL else { return }

        let resolver = resolver(for: endpoint)
        let blocks = parsed.blocks.filter { $0.kind == .plantuml }
        let revision = parsed.revision
        plantUMLTask = Task { @MainActor [weak self] in
            let resolved = await resolver.resolve(blocks)
            guard let self, !Task.isCancelled else { return }
            // Drop a stale result rather than applying it: by the time the
            // server answered the user may well have typed on.
            guard self.currentParsedDocument?.revision.value == revision.value else {
                bridgeLog.notice("dropping stale plantuml result rev=\(revision.value)")
                return
            }
            guard !resolved.isEmpty else { return }
            self.preview?.applyResolvedBlocks(resolved, revision: revision.value)
        }
    }

    /// The resolver for `endpoint`, rebuilt when the endpoint changes.
    ///
    /// The endpoint string doubles as the cache's `rendererVersion`, so
    /// re-pointing Writ at a different server never serves a diagram the
    /// old one drew.
    private func resolver(for endpoint: URL) -> PlantUMLBlockResolver {
        let version = PlantUMLSettings.endpointURLString
        if let existing = plantUMLResolver, plantUMLResolverEndpoint == version {
            return existing
        }
        let resolver = PlantUMLBlockResolver(
            renderer: RemotePlantUMLRenderer(endpoint: endpoint),
            cache: plantUMLCache,
            rendererVersion: version
        )
        plantUMLResolver = resolver
        plantUMLResolverEndpoint = version
        return resolver
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
            let enabled = PlantUMLSettings.shouldRender(
                frontMatter: parsed.frontMatter,
                endpoint: PlantUMLSettings.endpointURL,
                blocks: parsed.blocks
            )
            plantUMLEnabled = enabled
            let payload = PreviewBridgePayload(revision: parsed.revision, html: parsed.html, blocks: parsed.blocks, theme: theme, documentBaseURL: documentDirectory?.absoluteString, plantUMLEnabled: enabled)
            if let p = preview {
                bridgeLog.notice("forwarding payload to preview")
                p.apply(payload)
            } else {
                bridgeLog.error("preview is nil; cannot forward payload")
            }
            // Strictly after the payload is on its way. The preview never
            // waits on the network: a document with a diagram appears as
            // fast as one without, and the SVG is patched in afterwards.
            startPlantUMLResolve(for: parsed, enabled: enabled)
            let total = parsed.parseDuration + parsed.renderDuration
            statusBar?.update(byteCount: nil, lineCount: nil, status: .current(revision: parsed.revision, duration: total))
        case .cancelled(let revision):
            statusBar?.update(byteCount: nil, lineCount: nil, status: .stale(revision: revision))
        case .failed(let revision, let message):
            statusBar?.update(byteCount: nil, lineCount: nil, status: .failed(revision: revision, message: message))
        }
    }
}
