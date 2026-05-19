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

    @Test("Word count returns zero for empty string")
    func wordsEmpty() {
        #expect(DocumentSnapshot.wordCount(in: "") == 0)
    }

    @Test("Word count counts simple words")
    func wordsSimple() {
        #expect(DocumentSnapshot.wordCount(in: "hello world") == 2)
        #expect(DocumentSnapshot.wordCount(in: "  leading and trailing  ") == 3)
    }

    @Test("Word count handles punctuation as boundaries")
    func wordsPunct() {
        #expect(DocumentSnapshot.wordCount(in: "Hello, world! How's it?") == 4)
    }

    @Test("Word count handles unicode letters")
    func wordsUnicode() {
        #expect(DocumentSnapshot.wordCount(in: "café résumé 日本語") == 3)
    }

    @Test("lineColumn handles empty string at any offset without crashing")
    func lineColEmpty() {
        #expect(DocumentSnapshot.lineColumn(in: "", utf16Offset: 0) == (1, 1))
        // Offset past end must be clamped, not crash.
        #expect(DocumentSnapshot.lineColumn(in: "", utf16Offset: 42) == (1, 1))
    }

    @Test("lineColumn counts column at end of line")
    func lineColEnd() {
        let (line, col) = DocumentSnapshot.lineColumn(in: "# Fresh", utf16Offset: 7)
        #expect(line == 1)
        #expect(col == 8)
    }

    @Test("lineColumn handles newlines")
    func lineColNewlines() {
        // offset 4 lands on the 'c' of "c\nd" after walking "a\nb\n"
        let (line, col) = DocumentSnapshot.lineColumn(in: "a\nb\nc\nd", utf16Offset: 5)
        #expect(line == 3)
        #expect(col == 2)
    }

    @Test("lineColumn clamps negative and past-end offsets")
    func lineColClamp() {
        let src = "abc"
        #expect(DocumentSnapshot.lineColumn(in: src, utf16Offset: -10) == (1, 1))
        #expect(DocumentSnapshot.lineColumn(in: src, utf16Offset: 100) == (1, 4))
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
