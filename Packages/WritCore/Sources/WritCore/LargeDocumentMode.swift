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
            // 500ms is wider than typical inter-keystroke intervals at
            // normal typing speed (3–5 chars/sec ≈ 200–333ms gaps).
            // 250ms was firing a fresh parse after almost every single
            // character because the debounce kept elapsing between
            // strokes, which then hammered main with apply/IPC for every
            // keystroke and produced the visible "waxy" typing feel.
            debounceNormal: Duration = .milliseconds(500),
            debounceLarge: Duration = .milliseconds(1_500)
        ) {
            self.byteThreshold = byteThreshold
            self.lineThreshold = lineThreshold
            self.debounceNormal = debounceNormal
            self.debounceLarge = debounceLarge
        }

        public static let `default` = Thresholds()

        // MARK: - UserDefaults persistence (M3 Preferences pane)

        public static let byteThresholdDefaultsKey = "WritLargeDocByteThreshold"
        public static let lineThresholdDefaultsKey = "WritLargeDocLineThreshold"
        public static let debounceNormalDefaultsKey = "WritDebounceNormalMs"
        public static let debounceLargeDefaultsKey = "WritDebounceLargeMs"

        public static func fromDefaults(_ defaults: UserDefaults = .standard) -> Thresholds {
            let base = Thresholds.default
            let bytes = defaults.object(forKey: byteThresholdDefaultsKey) as? Int ?? base.byteThreshold
            let lines = defaults.object(forKey: lineThresholdDefaultsKey) as? Int ?? base.lineThreshold
            let normalMs = defaults.object(forKey: debounceNormalDefaultsKey) as? Int
            let largeMs = defaults.object(forKey: debounceLargeDefaultsKey) as? Int
            return Thresholds(
                byteThreshold: bytes,
                lineThreshold: lines,
                debounceNormal: normalMs.map { .milliseconds($0) } ?? base.debounceNormal,
                debounceLarge: largeMs.map { .milliseconds($0) } ?? base.debounceLarge
            )
        }

        public func persist(_ defaults: UserDefaults = .standard) {
            defaults.set(byteThreshold, forKey: Thresholds.byteThresholdDefaultsKey)
            defaults.set(lineThreshold, forKey: Thresholds.lineThresholdDefaultsKey)
            // Store debounces as Int milliseconds for human inspection.
            let normalMs = debounceNormal.components.seconds * 1000 + debounceNormal.components.attoseconds / 1_000_000_000_000_000
            let largeMs = debounceLarge.components.seconds * 1000 + debounceLarge.components.attoseconds / 1_000_000_000_000_000
            defaults.set(Int(normalMs), forKey: Thresholds.debounceNormalDefaultsKey)
            defaults.set(Int(largeMs), forKey: Thresholds.debounceLargeDefaultsKey)
        }
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
