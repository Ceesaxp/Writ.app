import Foundation

/// Heuristic that decides when a document is "large" enough to need the
/// degraded editing/preview mode described in the MVP plan.
///
/// Inputs are intentionally cheap to compute from a `DocumentSnapshot` so the
/// check can run on every accepted revision without expense.
public struct LargeDocumentMode: Sendable {
    public struct Thresholds: Sendable, Hashable {
        public var byteThreshold: Int
        public var lineThreshold: Int
        public var debounceNormal: Duration
        public var debounceLarge: Duration

        public init(
            byteThreshold: Int = 1_000_000,
            lineThreshold: Int = 20_000,
            debounceNormal: Duration = .milliseconds(250),
            debounceLarge: Duration = .milliseconds(1_500)
        ) {
            self.byteThreshold = byteThreshold
            self.lineThreshold = lineThreshold
            self.debounceNormal = debounceNormal
            self.debounceLarge = debounceLarge
        }

        public static let `default` = Thresholds()
    }

    public let thresholds: Thresholds

    public init(thresholds: Thresholds = .default) {
        self.thresholds = thresholds
    }

    public func isLarge(_ snapshot: DocumentSnapshot) -> Bool {
        snapshot.byteCount >= thresholds.byteThreshold
            || snapshot.lineCount >= thresholds.lineThreshold
    }

    public func debounce(for snapshot: DocumentSnapshot) -> Duration {
        isLarge(snapshot) ? thresholds.debounceLarge : thresholds.debounceNormal
    }
}
