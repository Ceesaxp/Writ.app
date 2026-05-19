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
        // Wait briefly past the debounce.
        try await Task.sleep(for: .milliseconds(200))
        for _ in 0..<10 {
            guard let event = await iter2.next() else { break }
            if case .completed(let parsed) = event {
                completedRevisions.append(parsed.revision.value)
                break
            }
        }
        // We expect at most one completion — for the latest revision (5).
        #expect(completedRevisions == [5])
    }
}
