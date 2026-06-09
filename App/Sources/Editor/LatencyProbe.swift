import Foundation
import os

/// Lightweight latency-measurement helper for the keystroke path.
///
/// Gated on the `WRIT_LOG_LATENCY` env var so it adds no overhead in
/// production builds. Run with `WRIT_LOG_LATENCY=1` and `log stream
/// --predicate 'category == "latency"' --info` to see per-call timings.
enum LatencyProbe {
    static let log = Logger(subsystem: "org.ceesaxp.Writ", category: "latency")
    static let enabled: Bool = ProcessInfo.processInfo.environment["WRIT_LOG_LATENCY"] != nil

    /// Run `work` and log the elapsed wall-clock time under the given
    /// `name`. Returns the value `work` returned. When the probe is
    /// disabled, just calls through with zero overhead.
    @discardableResult
    static func measure<T>(_ name: String, doc size: Int? = nil, _ work: () -> T) -> T {
        guard enabled else { return work() }
        let start = CFAbsoluteTimeGetCurrent()
        let result = work()
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        if let size {
            log.info("\(name, privacy: .public) \(ms, format: .fixed(precision: 2))ms (doc=\(size, privacy: .public)B)")
        } else {
            log.info("\(name, privacy: .public) \(ms, format: .fixed(precision: 2))ms")
        }
        return result
    }
}
