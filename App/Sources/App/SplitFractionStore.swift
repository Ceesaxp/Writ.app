import Foundation

/// Where the editor/preview divider fraction lives between launches.
///
/// Injected rather than reached for directly so the tests can drive the
/// gate below without touching the real defaults — and so no test run can
/// leave a fraction behind in the user's `UserDefaults`.
@MainActor
protocol SplitFractionStorage: AnyObject {
    var splitFraction: Double? { get set }
}

/// `UserDefaults`-backed storage.
///
/// This file exists because `NSSplitView.autosaveName` crashed on macOS
/// Sequoia when display geometry changed during sleep (`-[__NSSetM copy]`
/// from inside `_autosaveSubviewLayoutIfNecessary`, reproducer 2026-06-10
/// wake-up crash). Deleting this in favour of `autosaveName` brings that
/// crash back.
///
/// The key is deliberately a new one rather than the key this replaced
/// (see git history), and the old value is deliberately *not* migrated
/// — nothing reads it any more. Every fraction ever
/// written under that key was produced by the clobber this store exists to
/// close, so it encodes the preview pinned at its 280pt `minimumThickness`
/// rather than anything the user chose. Migrating it would carry the
/// artifact forward; dropping it costs one reset to 50/50, once.
@MainActor
final class UserDefaultsSplitFractionStorage: SplitFractionStorage {
    static let defaultsKey = "WritSplitDividerFraction"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var splitFraction: Double? {
        // `double(forKey:)` cannot tell "absent" from 0, and 0 is a value
        // the clamp turns into `minimum` instead of letting `stored` fall
        // back to half — so read through `object(forKey:)`.
        get { defaults.object(forKey: Self.defaultsKey) as? Double }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Self.defaultsKey)
                return
            }
            defaults.set(newValue, forKey: Self.defaultsKey)
        }
    }
}

/// The editor/preview divider fraction, plus the gate that decides which
/// resize notifications are worth persisting.
///
/// A `NSSplitView.didResizeSubviewsNotification` carries no hint about who
/// caused the resize. Some of them are the user dragging the divider, which
/// is the only geometry worth keeping; the rest are AppKit laying out panes
/// it has just uncollapsed, at whichever thickness its own constraints
/// prefer. Persisting the second kind is what made the split proportion
/// appear not to be retained at all: the transient geometry overwrote the
/// user's fraction, and the restore that followed faithfully re-applied the
/// value it had just destroyed.
///
/// So the owner declares the boundary instead of trying to infer it:
/// ``beginTransition()`` before it touches the layout, ``restoreDidLand()``
/// once the persisted fraction is back in place. Everything in between
/// belongs to AppKit and is dropped.
@MainActor
final class SplitFractionStore {
    /// An even split, used when nothing has been stored yet.
    static let fallback = 0.5
    /// Narrowest editor share we will remember. Stops a stored fraction
    /// from reopening the window with one pane effectively invisible.
    static let minimum = 0.15
    static let maximum = 0.85

    private let storage: SplitFractionStorage

    /// Shut until a restore has landed.
    ///
    /// Starting shut is not just caution — it is what covers the launch
    /// path. When the default launch layout is already `.split` the window's
    /// first layout pass fires the resize notification before the restore
    /// that `showWindow` defers to the next runloop turn has run, so a gate
    /// that started open would let the launch geometry overwrite the stored
    /// fraction before anyone had seen the window.
    private var restoreHasLanded = false

    init(storage: SplitFractionStorage = UserDefaultsSplitFractionStorage()) {
        self.storage = storage
    }

    /// The persisted fraction, clamped into the band.
    var stored: Double {
        guard let value = storage.splitFraction, value.isFinite else {
            return Self.fallback
        }
        return Self.clamp(value)
    }

    /// A programmatic layout change is starting. Resize notifications are
    /// AppKit's until ``restoreDidLand()``, so they must not persist.
    func beginTransition() {
        restoreHasLanded = false
    }

    /// The persisted fraction has been re-applied; later resizes are the
    /// user dragging the divider.
    func restoreDidLand() {
        restoreHasLanded = true
    }

    /// Returns true if the value was persisted, false if it was suppressed
    /// by the gate or rejected as not describing two visible panes — the
    /// caller logs the outcome.
    @discardableResult
    func splitDidResize(editorWidth: Double, previewWidth: Double) -> Bool {
        // The gate, and the whole point of this type. Without it the
        // notification AppKit posts while uncollapsing the preview at its
        // 280pt `minimumThickness` is persisted as the user's choice.
        guard restoreHasLanded else { return false }
        guard editorWidth.isFinite, previewWidth.isFinite else { return false }
        // A zero or negative width is a pane mid-collapse, and its fraction
        // is 0 or 1 — never something to remember.
        guard editorWidth > 0, previewWidth > 0 else { return false }
        let total = editorWidth + previewWidth
        guard total > 0 else { return false }
        storage.splitFraction = Self.clamp(editorWidth / total)
        return true
    }

    private static func clamp(_ fraction: Double) -> Double {
        min(max(fraction, minimum), maximum)
    }
}
