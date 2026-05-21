import Testing
import Foundation
import WritCore
import WritParser
@testable import WritRender

@Suite("TechnicalBlockCache")
struct CacheTests {
    @Test("Cache stores and retrieves entries")
    func basicHit() {
        let cache = TechnicalBlockCache()
        let block = TechnicalBlock(id: "x", kind: .math, source: "x^2")
        let entry = TechnicalBlockCache.Entry(renderedHTML: "<svg/>", createdAt: .now, renderDuration: .milliseconds(1))
        cache.set(block, rendererVersion: "v1", entry: entry)
        let got = cache.get(block, rendererVersion: "v1")
        #expect(got?.renderedHTML == "<svg/>")
    }

    @Test("Different renderer version misses")
    func versionMiss() {
        let cache = TechnicalBlockCache()
        let block = TechnicalBlock(id: "x", kind: .math, source: "x^2")
        cache.set(block, rendererVersion: "v1", entry: .init(renderedHTML: "v1", createdAt: .now, renderDuration: .zero))
        #expect(cache.get(block, rendererVersion: "v2") == nil)
    }

    @Test("Identical content hits regardless of id")
    func contentHashHit() {
        let cache = TechnicalBlockCache()
        let a = TechnicalBlock(id: "a", kind: .mermaid, source: "graph TD")
        let b = TechnicalBlock(id: "b", kind: .mermaid, source: "graph TD")
        cache.set(a, rendererVersion: "v1", entry: .init(renderedHTML: "<svg/>", createdAt: .now, renderDuration: .zero))
        #expect(cache.get(b, rendererVersion: "v1") != nil)
    }

    @Test("LRU evicts least-recently-used entry")
    func lruEviction() {
        let cache = TechnicalBlockCache(capacity: 2)
        let a = TechnicalBlock(id: "a", kind: .math, source: "a")
        let b = TechnicalBlock(id: "b", kind: .math, source: "b")
        let c = TechnicalBlock(id: "c", kind: .math, source: "c")
        cache.set(a, rendererVersion: "v", entry: .init(renderedHTML: "A", createdAt: .now, renderDuration: .zero))
        cache.set(b, rendererVersion: "v", entry: .init(renderedHTML: "B", createdAt: .now, renderDuration: .zero))
        _ = cache.get(a, rendererVersion: "v")
        cache.set(c, rendererVersion: "v", entry: .init(renderedHTML: "C", createdAt: .now, renderDuration: .zero))
        #expect(cache.get(b, rendererVersion: "v") == nil)
        #expect(cache.get(a, rendererVersion: "v") != nil)
        #expect(cache.get(c, rendererVersion: "v") != nil)
    }
}

@Suite("PreviewBridgePayload")
struct BridgeTests {
    @Test("Payload encodes to valid JSON")
    func encode() throws {
        let block = TechnicalBlock(id: "MATH_0", kind: .math, source: "x^2")
        let payload = PreviewBridgePayload(revision: DocumentRevision(7), html: "<p>hi</p>", blocks: [block], theme: "light")
        let json = try payload.encodedAsJSON()
        #expect(json.contains("\"revision\":7"))
        #expect(json.contains("MATH_0"))
        #expect(json.contains("\"theme\":\"light\""))
    }
}

@Suite("PreviewScheduler")
struct SchedulerTests {
    @Test("Scheduler debounces and emits a single result")
    func debounce() async throws {
        let parser = WritParserFactory.make()
        let mode = LargeDocumentMode(thresholds: .init(byteThreshold: 1_000_000, lineThreshold: 1_000_000, debounceNormal: .milliseconds(50), debounceLarge: .seconds(1)))
        let scheduler = PreviewScheduler(parser: parser, largeMode: mode)

        // Burst 5 edits within the debounce window.
        for i in 0..<5 {
            await scheduler.scheduleUpdate(source: "# heading \(i)")
        }

        var completedRevisions: [UInt64] = []
        let iter = scheduler.output.makeAsyncIterator()
        var iter2 = iter
        try await Task.sleep(for: .milliseconds(200))
        for _ in 0..<10 {
            guard let event = await iter2.next() else { break }
            if case .completed(let parsed) = event {
                completedRevisions.append(parsed.revision.value)
                break
            }
        }
        #expect(completedRevisions == [5])
    }

    /// Backs the View → Refresh Preview (⌘R) command on
    /// `DocumentWindowController`, which calls
    /// `PreviewBridge.forceRefresh` → `PreviewScheduler.forceRefresh`.
    /// Even when the source text is identical to the most recently
    /// rendered revision, manual refresh must emit a new `.completed`
    /// event so the WebView reflows (handy when the user has
    /// hand-edited the preview DOM, the scheme handler base directory
    /// changed, etc.).
    @Test("forceRefresh emits a fresh completed event for unchanged source")
    func manualRefreshBumpsRevision() async throws {
        let parser = WritParserFactory.make()
        let mode = LargeDocumentMode(thresholds: .init(byteThreshold: 1_000_000, lineThreshold: 1_000_000, debounceNormal: .milliseconds(50), debounceLarge: .seconds(1)))
        let scheduler = PreviewScheduler(parser: parser, largeMode: mode)
        let source = "# heading\n\nbody paragraph"

        var iter = scheduler.output.makeAsyncIterator()
        await scheduler.scheduleUpdate(source: source)

        // Wait for the first `.completed`.
        var firstRevision: UInt64 = 0
        var firstHTML = ""
        outer: for _ in 0..<10 {
            guard let event = await iter.next() else { break }
            if case .completed(let parsed) = event {
                firstRevision = parsed.revision.value
                firstHTML = parsed.html
                break outer
            }
        }
        #expect(firstRevision > 0, "first scheduleUpdate must produce a completed event")

        // Now force a refresh with the SAME source. The scheduler must
        // accept it and emit another completed event with a higher
        // revision number — debouncing must not silently drop it.
        await scheduler.forceRefresh(source: source)
        var secondRevision: UInt64 = 0
        var secondHTML = ""
        outer2: for _ in 0..<10 {
            guard let event = await iter.next() else { break }
            if case .completed(let parsed) = event {
                secondRevision = parsed.revision.value
                secondHTML = parsed.html
                break outer2
            }
        }
        #expect(secondRevision > firstRevision, "forceRefresh must bump the revision past the prior completed one")
        #expect(secondHTML == firstHTML, "identical source must render to identical HTML across the refresh")
    }

    /// Subtler ⌘R behaviour: if the user fires manual-refresh during
    /// the debounce window of a normal edit, both the original edit
    /// and the refresh count as work for the scheduler — but only the
    /// later (manually-refreshed) revision should emerge. Verifies
    /// `forceRefresh` cancels the in-flight debounce.
    @Test("forceRefresh cancels a pending debounced edit")
    func manualRefreshOverridesDebounce() async throws {
        let parser = WritParserFactory.make()
        let mode = LargeDocumentMode(thresholds: .init(byteThreshold: 1_000_000, lineThreshold: 1_000_000, debounceNormal: .milliseconds(200), debounceLarge: .seconds(1)))
        let scheduler = PreviewScheduler(parser: parser, largeMode: mode)

        // Queue an edit (will sit in the 200ms debounce window),
        // then immediately fire a manual refresh with a *different*
        // body. The debounced edit should be cancelled; only the
        // refresh result reaches us.
        await scheduler.scheduleUpdate(source: "# edit-A")
        await scheduler.forceRefresh(source: "# refresh-B")

        var iter = scheduler.output.makeAsyncIterator()
        var sawARevision = false
        var refreshSeen = false
        // Drain up to a few events. Wait long enough that the
        // cancelled debounce would have fired if it weren't cancelled.
        try await Task.sleep(for: .milliseconds(400))
        for _ in 0..<10 {
            guard let event = await iter.next() else { break }
            if case .completed(let parsed) = event {
                if parsed.html.contains("refresh-B") { refreshSeen = true }
                if parsed.html.contains("edit-A") { sawARevision = true }
                if refreshSeen { break }
            }
        }
        #expect(refreshSeen, "refresh result must reach the consumer")
        #expect(!sawARevision, "cancelled debounce must not deliver edit-A")
    }
}
