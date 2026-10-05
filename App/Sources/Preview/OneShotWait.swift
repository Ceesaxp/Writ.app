import Foundation

/// A single-use latch for "wait for this to happen, but not forever".
///
/// Exactly one of two outcomes is delivered, exactly once:
///
///   * `signal()` arrives first → `completion(true)`
///   * `timeout` elapses first  → `completion(false)`
///
/// Whichever loses the race is ignored, including a `signal()` that arrives
/// after the deadline. The completion closure is released the instant it
/// runs, so a wait that is armed and then overtaken holds nothing.
///
/// Each wait is its own identity. The PDF-export path previously shared one
/// monotonic token between every wait, so arming a second wait retired the
/// first one *without calling its completion*: the export behind it never
/// wrote a file, never reported a failure, and left its chained hook closure
/// installed forever — a retain cycle through the whole document graph.
///
/// Main-queue only. The export path is all main-actor code, so the latch is
/// armed, signalled and inspected there and needs no locking.
final class OneShotWait {
    private var completion: ((Bool) -> Void)?

    /// True once the outcome has been delivered. Lets an owner prune
    /// finished waits out of a pending-waits list from inside the
    /// completion itself.
    private(set) var hasFired = false

    /// Arms the wait. The block scheduled against `timeout` holds the only
    /// strong reference the latch needs to survive, so callers can arm one
    /// and forget it.
    init(timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        self.completion = completion
        // `asyncAfter` takes a `@Sendable` closure and the latch is not
        // Sendable (it holds a plain completion closure), so Swift 6 region
        // isolation will not let it cross the hop on its own. The hand-off
        // is safe: the latch is armed, signalled and fired on the main queue
        // only, which is where this block runs too.
        nonisolated(unsafe) let latch = self
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, timeout)) {
            latch.fire(false)
        }
    }

    /// Reports success, unless the deadline already reported failure.
    func signal() {
        fire(true)
    }

    private func fire(_ outcome: Bool) {
        guard let completion else { return }
        self.completion = nil
        hasFired = true
        completion(outcome)
    }
}

/// The set of waits currently listening for one condition.
///
/// Holding the waits in a group, rather than chaining them onto a
/// single-slot `var onSomething: (() -> Void)?` hook, is what lets several
/// of them be outstanding at once: a hook has room for one chained closure,
/// so the second wait to arm overwrites the first and the save/restore
/// dance around it strands whatever was there.
struct OneShotWaitGroup {
    private var pending: [OneShotWait] = []

    /// Arms a wait for this condition.
    ///
    /// Waits that have already finished are pruned here rather than from
    /// inside a completion — a completion that reached back into the group
    /// would be mutating it while it is already being mutated.
    mutating func arm(timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        pending.removeAll { $0.hasFired }
        pending.append(OneShotWait(timeout: timeout, completion: completion))
    }

    /// Hands back everything waiting and empties the group, so the caller
    /// can signal them with the group no longer being accessed. Signalling
    /// from inside the group would hold exclusive access to it for the whole
    /// cascade, and a completion that arms a new wait would trap.
    mutating func takePending() -> [OneShotWait] {
        let waits = pending
        pending.removeAll()
        return waits
    }
}
