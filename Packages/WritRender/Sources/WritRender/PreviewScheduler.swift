import Foundation
import WritCore
import WritParser

/// Coordinates debouncing, off-main parsing, and stale-result rejection.
///
/// Usage:
///   1. The editor calls ``scheduleUpdate(source:)`` after every accepted edit.
///   2. The scheduler debounces and starts an off-main parse task.
///   3. When the task completes, the result is delivered through ``output``
///      iff its revision is still the most recent accepted one.
///   4. ``forceRefresh(source:)`` bypasses the debounce (for manual refresh).
///
/// The scheduler stores no UI state — callers are responsible for moving
/// updates onto the main actor before touching `WKWebView`.
public actor PreviewScheduler {
    public enum Event: Sendable {
        case started(DocumentRevision)
        case completed(ParsedDocument)
        case cancelled(DocumentRevision)
        case failed(DocumentRevision, String)
    }

    private let parser: any MarkdownParser
    private let largeMode: LargeDocumentMode
    private var nextRevision: UInt64 = 1
    private var latestAccepted: DocumentRevision = .zero
    private var pendingTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private let outputContinuation: AsyncStream<Event>.Continuation

    public nonisolated let output: AsyncStream<Event>

    public init(parser: any MarkdownParser, largeMode: LargeDocumentMode = LargeDocumentMode()) {
        self.parser = parser
        self.largeMode = largeMode
        var continuation: AsyncStream<Event>.Continuation!
        self.output = AsyncStream { continuation = $0 }
        self.outputContinuation = continuation
    }

    deinit {
        outputContinuation.finish()
    }

    public func scheduleUpdate(source: String) {
        let revision = makeRevision()
        let snapshot = DocumentSnapshot(revision: revision, source: source)
        latestAccepted = revision

        let debounce = largeMode.debounce(for: snapshot)

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            if Task.isCancelled { return }
            await self?.run(snapshot)
        }
    }

    public func forceRefresh(source: String) {
        let revision = makeRevision()
        let snapshot = DocumentSnapshot(revision: revision, source: source)
        latestAccepted = revision
        debounceTask?.cancel()
        debounceTask = nil
        Task { [weak self] in
            await self?.run(snapshot)
        }
    }

    public func cancelAll() {
        debounceTask?.cancel()
        pendingTask?.cancel()
        debounceTask = nil
        pendingTask = nil
    }

    private func makeRevision() -> DocumentRevision {
        defer { nextRevision &+= 1 }
        return DocumentRevision(nextRevision)
    }

    private func run(_ snapshot: DocumentSnapshot) {
        pendingTask?.cancel()
        outputContinuation.yield(.started(snapshot.revision))

        let parser = self.parser
        // `.utility` (not `.userInitiated`) so a slow parse on a large doc
        // can't preempt the main thread mid-keystroke. The user only sees
        // the parsed preview after a debounce + parse, so prioritizing it
        // above background work but below interactive input is the right
        // shape.
        let task = Task.detached(priority: .utility) { [outputContinuation] in
            do {
                let parsed = try parser.parse(snapshot)
                if Task.isCancelled {
                    outputContinuation.yield(.cancelled(snapshot.revision))
                    return
                }
                outputContinuation.yield(.completed(parsed))
            } catch {
                outputContinuation.yield(.failed(snapshot.revision, String(describing: error)))
            }
        }
        pendingTask = Task { [weak self] in
            _ = await task.value
            await self?.markCompleted(snapshot.revision)
        }
    }

    private func markCompleted(_ revision: DocumentRevision) {
        if revision == latestAccepted {
            pendingTask = nil
        }
    }

    /// Returns true if the consumer should accept this event for UI update.
    public nonisolated func isRelevant(_ event: Event, against latest: DocumentRevision) -> Bool {
        switch event {
        case .started(let r), .cancelled(let r), .failed(let r, _):
            return r >= latest
        case .completed(let parsed):
            return parsed.revision >= latest
        }
    }
}
