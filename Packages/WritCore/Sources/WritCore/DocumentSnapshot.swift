import Foundation

/// Immutable snapshot of document source at a specific revision.
///
/// Snapshots are the only object that crosses thread boundaries between the
/// editor and the render pipeline. The source string is value-typed and the
/// revision lets the receiver discard stale work.
public struct DocumentSnapshot: Sendable, Hashable {
    public let revision: DocumentRevision
    public let source: String
    public let byteCount: Int
    public let lineCount: Int

    public init(revision: DocumentRevision, source: String) {
        self.revision = revision
        self.source = source
        self.byteCount = source.utf8.count
        self.lineCount = DocumentSnapshot.countLines(in: source)
    }

    public static let empty = DocumentSnapshot(revision: .zero, source: "")

    private static func countLines(in source: String) -> Int {
        if source.isEmpty { return 0 }
        var count = 1
        for ch in source.unicodeScalars where ch == "\n" { count += 1 }
        return count
    }

    /// Approximate word count. Single linear scan over Unicode scalars
    /// treating any run of letters/digits as one word — matches Pages /
    /// Microsoft Word behavior closely enough for a status-bar readout and
    /// scales linearly so it stays cheap on multi-megabyte documents.
    ///
    /// Apostrophes and hyphens that sit between word characters do not break
    /// a word ("How's", "well-known"). A trailing punctuation never starts a
    /// new word.
    public static func wordCount(in source: String) -> Int {
        var count = 0
        var inWord = false
        let scalars = Array(source.unicodeScalars)
        for i in scalars.indices {
            let scalar = scalars[i]
            let isWordChar = scalar.properties.isAlphabetic
                || ("0"..."9").contains(scalar)
                || scalar == "_"
            let isJoiner = (scalar == "'" || scalar == "\u{2019}" || scalar == "-")
                && inWord
                && i + 1 < scalars.endIndex
                && (scalars[i + 1].properties.isAlphabetic || ("0"..."9").contains(scalars[i + 1]))
            if isWordChar {
                if !inWord { count += 1; inWord = true }
            } else if isJoiner {
                // stay in current word
            } else {
                inWord = false
            }
        }
        return count
    }
}
