import Testing
import Foundation

/// Locks in the undo/redo pattern that `App/Sources/Documents/WritDocument`
/// uses via `applyEditorText`. The real class is in the App target which
/// has no test bundle yet (Xcode 17 + Swift 6 + executable-host has an
/// unresolved build conflict around the swiftmodule output path). This
/// test stands in for that coverage by exercising the **same algorithm**
/// against a fake document that mirrors WritDocument's relevant
/// fragments. If you change WritDocument.applyEditorText, mirror the
/// change here.
@Suite("WritDocument undo/redo pattern")
@MainActor
struct UndoRedoPatternTests {
    /// Mirrors the state-mutation + inverse-closure pattern used by
    /// `WritDocument.applyEditorText`. Keep in sync.
    @MainActor
    final class FakeDocument {
        var sourceText: String = ""
        let undoManager: UndoManager
        private(set) var changeCount = 0

        init() {
            let mgr = UndoManager()
            // In the real app each user keystroke arrives in its own
            // run-loop cycle so NSUndoManager auto-groups them
            // individually. Tests run synchronously inside one cycle,
            // which would coalesce every edit into a single group.
            // Turn off auto-grouping and group each apply() call
            // explicitly so the test mirrors per-edit semantics.
            mgr.groupsByEvent = false
            self.undoManager = mgr
        }

        func applyEditorText(_ newText: String) {
            if newText == sourceText { return }
            let oldText = sourceText
            undoManager.beginUndoGrouping()
            sourceText = newText
            changeCount += 1
            undoManager.registerUndo(withTarget: self) { [oldText] target in
                target.applyEditorText(oldText)
            }
            undoManager.endUndoGrouping()
        }
    }

    @Test("Single edit undoes and redoes cleanly")
    func singleEditRoundTrip() {
        let doc = FakeDocument()
        doc.applyEditorText("Hello")
        #expect(doc.sourceText == "Hello")
        #expect(doc.undoManager.canUndo)

        doc.undoManager.undo()
        #expect(doc.sourceText == "")
        #expect(doc.undoManager.canRedo)

        doc.undoManager.redo()
        #expect(doc.sourceText == "Hello")
    }

    @Test("Multi-step history walks back and forward in order")
    func multiStepRoundTrip() {
        let doc = FakeDocument()
        doc.applyEditorText("one")
        doc.applyEditorText("one two")
        doc.applyEditorText("one two three")
        #expect(doc.sourceText == "one two three")

        doc.undoManager.undo()
        #expect(doc.sourceText == "one two")
        doc.undoManager.undo()
        #expect(doc.sourceText == "one")
        doc.undoManager.undo()
        #expect(doc.sourceText == "")

        doc.undoManager.redo()
        #expect(doc.sourceText == "one")
        doc.undoManager.redo()
        #expect(doc.sourceText == "one two")
        doc.undoManager.redo()
        #expect(doc.sourceText == "one two three")
    }

    @Test("New edit after undo truncates the redo stack")
    func branchInvalidatesRedo() {
        let doc = FakeDocument()
        doc.applyEditorText("A")
        doc.applyEditorText("AB")
        doc.undoManager.undo()
        #expect(doc.sourceText == "A")
        #expect(doc.undoManager.canRedo)

        doc.applyEditorText("AX")
        #expect(!doc.undoManager.canRedo, "new edit must discard the redo stack")
        #expect(doc.sourceText == "AX")

        doc.undoManager.undo()
        #expect(doc.sourceText == "A")
    }

    @Test("Re-applying identical text registers no undo entry")
    func identicalTextIsNoop() {
        let doc = FakeDocument()
        doc.applyEditorText("same")
        let undoBefore = doc.undoManager.canUndo
        let countBefore = doc.changeCount

        doc.applyEditorText("same")

        #expect(doc.undoManager.canUndo == undoBefore)
        #expect(doc.changeCount == countBefore, "no-op edit must not bump change counter")
    }
}
