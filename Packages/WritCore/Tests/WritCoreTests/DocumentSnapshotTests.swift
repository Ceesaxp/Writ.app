import Testing
@testable import WritCore

@Suite("DocumentSnapshot")
struct DocumentSnapshotTests {
    @Test("Empty snapshot has zero counts")
    func emptyCounts() {
        let s = DocumentSnapshot.empty
        #expect(s.byteCount == 0)
        #expect(s.lineCount == 0)
        #expect(s.revision == .zero)
    }

    @Test("Line count includes single trailing line without newline")
    func singleLine() {
        let s = DocumentSnapshot(revision: .zero, source: "hello world")
        #expect(s.lineCount == 1)
        #expect(s.byteCount == 11)
    }

    @Test("Line count matches number of explicit newlines plus one")
    func multipleLines() {
        let s = DocumentSnapshot(revision: .zero, source: "a\nb\nc")
        #expect(s.lineCount == 3)
    }

    @Test("Revision next produces strictly greater value")
    func revisionMonotonic() {
        let r = DocumentRevision(5)
        #expect(r.next() > r)
    }
}

@Suite("LargeDocumentMode")
struct LargeDocumentModeTests {
    @Test("Small document is not large")
    func smallNotLarge() {
        let mode = LargeDocumentMode()
        let s = DocumentSnapshot(revision: .zero, source: "small")
        #expect(!mode.isLarge(s))
        #expect(mode.debounce(for: s) == mode.thresholds.debounceNormal)
    }

    @Test("Document over byte threshold is large")
    func byteThreshold() {
        let mode = LargeDocumentMode(thresholds: .init(byteThreshold: 10, lineThreshold: 1_000_000))
        let s = DocumentSnapshot(revision: .zero, source: String(repeating: "x", count: 100))
        #expect(mode.isLarge(s))
        #expect(mode.debounce(for: s) == mode.thresholds.debounceLarge)
    }

    @Test("Document over line threshold is large")
    func lineThreshold() {
        let mode = LargeDocumentMode(thresholds: .init(byteThreshold: 1_000_000, lineThreshold: 3))
        let s = DocumentSnapshot(revision: .zero, source: "a\nb\nc\nd\ne")
        #expect(mode.isLarge(s))
    }
}
