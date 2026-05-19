import Foundation

/// Monotonically increasing identifier for a document source state.
///
/// Every accepted edit produces a new revision. Render jobs carry the revision
/// they were scheduled against so stale results can be discarded when a newer
/// revision has already been applied.
public struct DocumentRevision: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let value: UInt64

    public init(_ value: UInt64) { self.value = value }

    public static let zero = DocumentRevision(0)

    public func next() -> DocumentRevision { DocumentRevision(value &+ 1) }

    public static func < (lhs: DocumentRevision, rhs: DocumentRevision) -> Bool {
        lhs.value < rhs.value
    }

    public var description: String { "rev:\(value)" }
}
