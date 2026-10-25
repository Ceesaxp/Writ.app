import AppKit
import XCTest

/// Headless harness for driving a real `WritTextView` from unit tests.
///
/// `TODO.md` recorded app-level NSTextView tests as blocked: a test bundle
/// with the app as its *test host* fought Swift 6 over the executable's
/// swiftmodule. The way around it is the one this bundle already uses for
/// everything else — no test host, production sources compiled straight in —
/// plus the observation that an `NSTextView` needs no run loop and no visible
/// window to respond to `insertText`, `deleteBackward`, `copy` or undo. It
/// only needs to be the first responder of *some* window.
///
/// So this is not a mock. It is the production view, on the production
/// TextKit 1 stack, driven synchronously.
@MainActor
final class TextViewHarness {
    let textView: WritTextView
    let textStorage: NSTextStorage
    let layoutManager: NSLayoutManager
    let textContainer: NSTextContainer
    private let window: NSWindow

    /// Builds the TextKit 1 stack in the same order `EditorViewController`
    /// does. The order is what locks the view onto TK1: storage owns the
    /// layout manager, the layout manager owns the container, and the view is
    /// initialised *with* that container. Hand `NSTextView` anything else and
    /// it quietly builds itself a TextKit 2 stack instead — which would make
    /// every assertion here a measurement of the wrong code.
    init(_ source: String = "") {
        textStorage = NSTextStorage()
        layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        textContainer = NSTextContainer(
            containerSize: NSSize(width: CGFloat(600), height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        textView = WritTextView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400),
            textContainer: textContainer
        )
        textView.isEditable = true
        textView.allowsUndo = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        // Off-screen, never ordered front. The window exists only so the text
        // view can become first responder and inherit an undo manager.
        window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scrollView.documentView = textView
        window.contentView = scrollView
        window.makeFirstResponder(textView)

        if !source.isEmpty {
            textView.string = source
        }
        layoutManager.ensureLayout(for: textContainer)
    }

    /// The document, with newlines made visible so a failure message is
    /// readable at a glance instead of wrapping across lines.
    var escaped: String {
        textView.string.replacingOccurrences(of: "\n", with: "⏎")
    }

    /// Asserts the TextKit 1 stack really is in place. Call it in any test
    /// whose result would be meaningless on TK2.
    func assertTextKit1(_ file: StaticString = #filePath, _ line: UInt = #line) {
        XCTAssertNotNil(textView.layoutManager, "expected TextKit 1: layoutManager is nil", file: file, line: line)
        XCTAssertNil(textView.textLayoutManager, "expected TextKit 1: a TextKit 2 stack was substituted", file: file, line: line)
    }
}

/// Proof that the harness drives the real view. If this class fails, nothing
/// else in a WritTextView test tells you anything.
final class WritTextViewHarnessTests: XCTestCase {
    @MainActor
    func testHarnessBuildsATextKit1View() {
        let harness = TextViewHarness("alpha one\nbb\n")
        harness.assertTextKit1()
        XCTAssertIdentical(harness.textView.layoutManager, harness.layoutManager)
    }

    @MainActor
    func testHarnessViewIsFirstResponderAndHasAnUndoManager() {
        let harness = TextViewHarness()
        XCTAssertIdentical(harness.textView.window?.firstResponder, harness.textView)
        XCTAssertNotNil(harness.textView.undoManager)
    }

    @MainActor
    func testHarnessDrivesTypingSynchronously() {
        let harness = TextViewHarness("alpha\n")
        harness.textView.setSelectedRange(NSRange(location: 0, length: 5))
        harness.textView.insertText("beta", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(harness.escaped, "beta⏎")
    }

    @MainActor
    func testHarnessDrivesUndoSynchronously() {
        let harness = TextViewHarness("alpha\n")
        harness.textView.setSelectedRange(NSRange(location: 0, length: 5))
        harness.textView.insertText("beta", replacementRange: NSRange(location: NSNotFound, length: 0))
        harness.textView.breakUndoCoalescing()
        harness.textView.undoManager?.undo()
        XCTAssertEqual(harness.escaped, "alpha⏎", "one undo should restore the original document")
    }
}
