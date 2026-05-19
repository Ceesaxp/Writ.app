import Cocoa

protocol EditorViewControllerDelegate: AnyObject {
    func editor(_ controller: EditorViewController, didChangeText newText: String)
    func editor(_ controller: EditorViewController, didChangeSelectionTo location: (line: Int, column: Int))
}

/// AppKit/TextKit-backed editor surface.
///
/// Implementation notes (per `docs/02-TECHNICAL-DESIGN.md` §3):
/// - Hosts a single `NSTextView` inside an `NSScrollView`.
/// - Enables TextKit 2 layout via `NSTextLayoutManager` (default in modern AppKit).
/// - Does **not** rebuild the attributed string on every keystroke. Source text
///   is plain; M2 will introduce range-aware syntax highlighting that paints
///   attributes on top.
/// - Emits the post-edit string through ``delegate`` for the document to
///   broker preview rendering.
final class EditorViewController: NSViewController, NSTextViewDelegate {
    weak var delegate: EditorViewControllerDelegate?

    private(set) var textView: NSTextView!
    private var scrollView: NSScrollView!
    private var currentSource: String = ""
    private var suppressDelegateBroadcast = false
    private let syntaxHighlighter = MarkdownSyntaxHighlighter()
    private var highlightThrottle: Task<Void, Never>?

    override func loadView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor

        let textView = makeTextView()
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 12
        textView.delegate = self
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.smartInsertDeleteEnabled = false
        textView.font = Self.editorFont()
        textView.textColor = .textColor
        textView.insertionPointColor = .controlAccentColor
        textView.usesFindBar = true
        textView.usesFindPanel = true
        textView.isIncrementalSearchingEnabled = true

        scroll.documentView = textView
        self.scrollView = scroll
        self.textView = textView
        self.view = scroll
    }

    private func makeTextView() -> NSTextView {
        // Force TextKit 2 layout. Available since macOS 13; on macOS 14+ this
        // is the default but we still set it explicitly.
        let textView = NSTextView(usingTextLayoutManager: true)
        return textView
    }

    static func editorFont() -> NSFont {
        if let mono = NSFont(name: "SF Mono", size: 13.0) { return mono }
        return NSFont.monospacedSystemFont(ofSize: 13.0, weight: .regular)
    }

    func setSource(_ source: String) {
        suppressDelegateBroadcast = true
        defer { suppressDelegateBroadcast = false }
        currentSource = source
        textView.textStorage?.beginEditing()
        textView.textStorage?.setAttributedString(NSAttributedString(string: source, attributes: defaultAttributes()))
        textView.textStorage?.endEditing()
        scheduleHighlight()
    }

    func reloadSource() {
        textView.string = currentSource
        scheduleHighlight()
    }

    private func defaultAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: Self.editorFont(),
            .foregroundColor: NSColor.textColor
        ]
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard !suppressDelegateBroadcast else { return }
        let text = textView.string
        currentSource = text
        delegate?.editor(self, didChangeText: text)
        scheduleHighlight()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        let selection = textView.selectedRange()
        let (line, column) = lineColumn(forOffset: selection.location)
        delegate?.editor(self, didChangeSelectionTo: (line, column))
    }

    private func lineColumn(forOffset offset: Int) -> (Int, Int) {
        let text = currentSource
        var line = 1
        var column = 1
        var idx = text.startIndex
        var consumed = 0
        while consumed < offset && idx < text.endIndex {
            if text[idx] == "\n" { line += 1; column = 1 } else { column += 1 }
            consumed += text.utf16.distance(from: text.utf16.startIndex, to: text.utf16.index(after: text.utf16.index(text.utf16.startIndex, offsetBy: consumed)))
            idx = text.index(after: idx)
        }
        return (line, column)
    }

    private func scheduleHighlight() {
        highlightThrottle?.cancel()
        let snapshot = currentSource
        let storage = textView.textStorage
        let attrs = defaultAttributes()
        highlightThrottle = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            if Task.isCancelled { return }
            // M0: viewport-aware highlighting is deferred to M3. For now we
            // disable heavy highlighting on large documents to keep typing
            // responsive — only basic default attributes are applied.
            guard snapshot.utf8.count < 500_000 else { return }
            await self?.syntaxHighlighter.applyHighlight(to: storage, source: snapshot, baseAttributes: attrs)
        }
    }
}
