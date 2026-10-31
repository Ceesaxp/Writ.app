import XCTest

/// The transition gate is the fix for "the editor/preview split proportion
/// is not retained": drag the divider wider, quit, relaunch, pick Split —
/// and the preview comes back narrow.
///
/// Nothing was wrong with the *saving*. Entering split uncollapses the
/// preview at its 280pt `minimumThickness`, AppKit posts a resize
/// notification for that transient geometry, and the old code persisted it
/// before re-applying "the stored fraction" — which by then was the value
/// it had just overwritten. The bug's fixed point is the preview at its
/// minimum, which is exactly what the user saw.
///
/// These run in the hostless bundle: `SplitFractionStore` is Foundation-only
/// and its storage is injected, so the gate is testable without a window, a
/// run loop, or the real `UserDefaults`.
@MainActor
final class SplitFractionStoreTests: XCTestCase {

    /// In-memory stand-in for `UserDefaults`. Also keeps the suite from
    /// writing a fraction into the developer's own defaults.
    @MainActor
    private final class FakeStorage: SplitFractionStorage {
        var splitFraction: Double?

        init(splitFraction: Double? = nil) {
            self.splitFraction = splitFraction
        }
    }

    // The reporter's geometry, and the arithmetic that identified the bug:
    // a 1101pt-wide window with the outline collapsed and a `.paneSplitter`
    // divider (~9pt), preview pinned at its 280pt `minimumThickness`, gives
    // (1101 - 9 - 280) / (1101 - 9) = 0.7436. `~0.743` is the value found
    // persisted on that machine, which is how the clobber was confirmed.
    private static let clobberEditorWidth = 812.0
    private static let clobberPreviewWidth = 280.0
    private static let clobberFraction = 0.7436

    private static let tolerance = 0.0001

    // MARK: - The gate

    func testShouldNotPersistResizeDuringProgrammaticTransition() {
        let storage = FakeStorage(splitFraction: 0.5)
        let store = SplitFractionStore(storage: storage)

        store.beginTransition()
        let persisted = store.splitDidResize(
            editorWidth: Self.clobberEditorWidth,
            previewWidth: Self.clobberPreviewWidth
        )

        XCTAssertFalse(
            persisted,
            "geometry AppKit produced while uncollapsing a pane was persisted as if the user had dragged the divider"
        )
        XCTAssertEqual(
            store.stored, 0.5, accuracy: Self.tolerance,
            "the stored fraction was clobbered by the transition into split"
        )
    }

    func testShouldPersistResizeAfterRestoreLands() {
        let storage = FakeStorage(splitFraction: 0.5)
        let store = SplitFractionStore(storage: storage)

        store.beginTransition()
        store.restoreDidLand()
        let persisted = store.splitDidResize(
            editorWidth: Self.clobberEditorWidth,
            previewWidth: Self.clobberPreviewWidth
        )

        XCTAssertTrue(persisted, "a resize after the restore landed is the user dragging, and must be kept")
        XCTAssertEqual(store.stored, Self.clobberFraction, accuracy: Self.tolerance)
    }

    func testShouldSuppressResizeBeforeAnyRestoreHasLanded() {
        // The launch path: `defaultLaunchLayout == .split`, so the window's
        // first layout pass fires the notification before `showWindow`'s
        // deferred restore has run. No `beginTransition()` precedes it.
        let storage = FakeStorage(splitFraction: 0.68)
        let store = SplitFractionStore(storage: storage)

        let persisted = store.splitDidResize(
            editorWidth: Self.clobberEditorWidth,
            previewWidth: Self.clobberPreviewWidth
        )

        XCTAssertFalse(persisted, "a fresh store has not restored anything yet, so it cannot yet trust a resize")
        XCTAssertEqual(store.stored, 0.68, accuracy: Self.tolerance)
    }

    func testShouldReopenTheGateOnlyAfterEachTransition() {
        let storage = FakeStorage(splitFraction: 0.5)
        let store = SplitFractionStore(storage: storage)

        store.restoreDidLand()
        XCTAssertTrue(store.splitDidResize(editorWidth: 700, previewWidth: 300))
        XCTAssertEqual(store.stored, 0.7, accuracy: Self.tolerance)

        // A second layout switch: the gate must close again, not stay open
        // because a restore landed once.
        store.beginTransition()
        XCTAssertFalse(store.splitDidResize(editorWidth: 280, previewWidth: 812))
        XCTAssertEqual(store.stored, 0.7, accuracy: Self.tolerance)

        store.restoreDidLand()
        XCTAssertTrue(store.splitDidResize(editorWidth: 600, previewWidth: 400))
        XCTAssertEqual(store.stored, 0.6, accuracy: Self.tolerance)
    }

    // MARK: - Geometry that describes no usable split

    func testShouldRejectCollapsedPaneWidths() {
        for (editorWidth, previewWidth) in [(0.0, 1092.0), (1092.0, 0.0), (-8.0, 1092.0), (0.0, 0.0)] {
            let storage = FakeStorage(splitFraction: 0.62)
            let store = SplitFractionStore(storage: storage)
            store.restoreDidLand()

            let persisted = store.splitDidResize(editorWidth: editorWidth, previewWidth: previewWidth)

            XCTAssertFalse(persisted, "editor=\(editorWidth) preview=\(previewWidth) is a pane mid-collapse")
            XCTAssertEqual(store.stored, 0.62, accuracy: Self.tolerance, "editor=\(editorWidth) preview=\(previewWidth)")
        }
    }

    func testShouldRejectNonFiniteWidths() {
        for (editorWidth, previewWidth) in [(Double.nan, 1092.0), (1092.0, Double.nan), (.infinity, 1092.0), (1092.0, .infinity)] {
            let storage = FakeStorage(splitFraction: 0.62)
            let store = SplitFractionStore(storage: storage)
            store.restoreDidLand()

            let persisted = store.splitDidResize(editorWidth: editorWidth, previewWidth: previewWidth)

            XCTAssertFalse(persisted, "editor=\(editorWidth) preview=\(previewWidth) is not a measurement")
            XCTAssertEqual(store.stored, 0.62, accuracy: Self.tolerance, "editor=\(editorWidth) preview=\(previewWidth)")
        }
    }

    // MARK: - Reading the stored value

    func testShouldClampStoredFractionToBand() {
        let wide = SplitFractionStore(storage: FakeStorage(splitFraction: 0.98))
        XCTAssertEqual(wide.stored, SplitFractionStore.maximum, accuracy: Self.tolerance)

        let narrow = SplitFractionStore(storage: FakeStorage(splitFraction: 0.01))
        XCTAssertEqual(narrow.stored, SplitFractionStore.minimum, accuracy: Self.tolerance)
    }

    func testShouldFallBackToHalfWhenNothingStored() {
        let store = SplitFractionStore(storage: FakeStorage())
        XCTAssertEqual(store.stored, 0.5, accuracy: Self.tolerance)
    }
}
