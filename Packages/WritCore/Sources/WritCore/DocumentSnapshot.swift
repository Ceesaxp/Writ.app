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
}
