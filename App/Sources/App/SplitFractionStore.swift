import Foundation

/// Where the editor/preview divider fraction lives between launches.
///
/// Injected rather than reached for directly so that tests can drive this
/// without touching the real defaults — and so no test run can leave a
/// fraction behind in the user's `UserDefaults`.
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
@MainActor
final class UserDefaultsSplitFractionStorage: SplitFractionStorage {
    static let defaultsKey = "WritEditorPreviewSplitFraction"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var splitFraction: Double? {
        get {
            let v = defaults.double(forKey: Self.defaultsKey)
            return v > 0 ? v : nil
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Self.defaultsKey)
                return
            }
            defaults.set(newValue, forKey: Self.defaultsKey)
        }
    }
}

/// The editor/preview divider fraction: editor width over editing-area
/// width, persisted across launches.
@MainActor
final class SplitFractionStore {
    /// An even split, used when nothing has been stored yet.
    static let fallback = 0.5

    private let storage: SplitFractionStorage

    init(storage: SplitFractionStorage = UserDefaultsSplitFractionStorage()) {
        self.storage = storage
    }

    var stored: Double {
        storage.splitFraction ?? Self.fallback
    }

    /// Returns true if the value was persisted, false if it was rejected as
    /// not describing two visible panes — the caller logs the outcome.
    @discardableResult
    func splitDidResize(editorWidth: Double, previewWidth: Double) -> Bool {
        let total = editorWidth + previewWidth
        guard total > 0, editorWidth > 0, previewWidth > 0 else { return false }
        storage.splitFraction = editorWidth / total
        return true
    }
}
