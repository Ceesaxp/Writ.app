import Cocoa
import WritCore
import WritParser

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

protocol EditorViewControllerDelegate: AnyObject {
    func editor(_ controller: EditorViewController, didChangeText newText: String)
    func editor(_ controller: EditorViewController, didChangeSelectionTo location: (line: Int, column: Int))
    func editor(_ controller: EditorViewController, didScrollToRatio ratio: Double, topSourceLine: Int)
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
    private var containerView: NSView!
    private var gutter: LineNumberGutter?
    private var gutterWidthConstraint: NSLayoutConstraint?
    private var scrollLeadingConstraint: NSLayoutConstraint?
    private var currentSource: String = ""
    private var suppressDelegateBroadcast = false
    private let syntaxHighlighter = MarkdownSyntaxHighlighter()
    private var highlightThrottle: Task<Void, Never>?

    /// Persisted preference key for showing line numbers.
    /// Default is off — the ruler currently attaches at the correct
    /// thickness but doesn't render visibly with TextKit 2; tracked in
    /// TODO.md as a known M3 limitation.
    static let lineNumbersDefaultsKey = "WritShowLineNumbers"
    static var lineNumbersEnabled: Bool {
        get {
            // Default ON: first launch shows line numbers. Users can toggle
            // off via View > Show Line Numbers (⌥⌘L) and the preference
            // persists.
            if UserDefaults.standard.object(forKey: lineNumbersDefaultsKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: lineNumbersDefaultsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: lineNumbersDefaultsKey) }
    }

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

        // Wrap the scroll view in a container so a custom line-number gutter
        // can sit alongside it (we don't use NSRulerView — see
        // LineNumberGutter for the reason).
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        let leading = scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            leading,
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        self.scrollLeadingConstraint = leading
        self.containerView = container
        self.view = container

        // Observe scroll position so the bridge can propagate to the preview.
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scroll.contentView
        )
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        applyLineNumberPreference()
    }

    private var lastScrollRatio: Double = 0
    @objc private func scrollViewDidScroll(_ note: Notification) {
        if suppressScrollNotify { return }
        guard let contentView = scrollView.contentView as NSClipView? else { return }
        let docHeight = scrollView.documentView?.frame.height ?? 0
        let visibleHeight = contentView.bounds.height
        let scrollable = max(1, docHeight - visibleHeight)
        let ratio = Double(contentView.bounds.origin.y / scrollable).clamped(to: 0...1)
        if abs(ratio - lastScrollRatio) < 0.005 { return }
        lastScrollRatio = ratio
        delegate?.editor(self, didScrollToRatio: ratio, topSourceLine: topVisibleSourceLine())
    }

    /// Programmatically scroll so the given 1-indexed source line is at
    /// the top of the visible area. Used by the preview → editor scroll
    /// sync. Suppresses the editor's own scroll notification while it
    /// performs the scroll so the two panes don't ping-pong.
    private var suppressScrollNotify = false
    func scrollToSourceLine(_ line: Int) {
        guard let textLayoutManager = textView.textLayoutManager else { return }
        // Map 1-indexed line → UTF-16 offset → text-layout fragment → frame.
        let utf16 = currentSource.utf16
        var lineIndex = 1
        var consumed = 0
        var idx = utf16.startIndex
        while idx < utf16.endIndex && lineIndex < line {
            if utf16[idx] == 0x0A { lineIndex += 1 }
            idx = utf16.index(after: idx)
            consumed += 1
        }
        let docStart = textLayoutManager.documentRange.location
        guard let target = textLayoutManager.location(docStart, offsetBy: consumed) else { return }
        textLayoutManager.ensureLayout(for: NSTextRange(location: target))
        var targetY: CGFloat?
        textLayoutManager.enumerateTextLayoutFragments(from: target, options: [.ensuresLayout]) { fragment in
            targetY = fragment.layoutFragmentFrame.minY
            return false
        }
        guard let y = targetY else { return }
        suppressScrollNotify = true
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.suppressScrollNotify = false
        }
    }

    /// Computes the 1-indexed source line at the top of the editor's
    /// visible area. Used for block-aware preview scroll sync — the bridge
    /// passes this to the preview so it can align the matching block.
    private func topVisibleSourceLine() -> Int {
        guard let textLayoutManager = textView.textLayoutManager else { return 1 }
        let visibleY = scrollView.contentView.bounds.origin.y + textView.textContainerOrigin.y
        var topLine = 1
        textLayoutManager.enumerateTextLayoutFragments(
            from: textLayoutManager.textViewportLayoutController.viewportRange?.location,
            options: [.ensuresLayout]
        ) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.maxY < visibleY { return true }
            // First fragment at or below the visible top.
            let location = fragment.rangeInElement.location
            let offset = textLayoutManager.offset(
                from: textLayoutManager.documentRange.location,
                to: location
            )
            topLine = DocumentSnapshot.lineColumn(in: currentSource, utf16Offset: offset).line
            return false
        }
        return topLine
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

    private func applyLineNumberPreference() {
        let enabled = EditorViewController.lineNumbersEnabled
        if enabled {
            if gutter == nil {
                let newGutter = LineNumberGutter(textView: textView, clipView: scrollView.contentView)
                containerView.addSubview(newGutter)
                let width = newGutter.widthAnchor.constraint(equalToConstant: LineNumberGutter.defaultWidth)
                NSLayoutConstraint.activate([
                    newGutter.topAnchor.constraint(equalTo: containerView.topAnchor),
                    newGutter.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                    newGutter.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
                    width
                ])
                gutterWidthConstraint = width
                scrollLeadingConstraint?.isActive = false
                let newLeading = scrollView.leadingAnchor.constraint(equalTo: newGutter.trailingAnchor)
                newLeading.isActive = true
                scrollLeadingConstraint = newLeading
                gutter = newGutter
            }
            gutter?.isHidden = false
            gutter?.needsDisplay = true
        } else {
            gutter?.removeFromSuperview()
            gutter = nil
            gutterWidthConstraint = nil
            // Restore scroll-view-flush-left.
            scrollLeadingConstraint?.isActive = false
            let flushLeading = scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor)
            flushLeading.isActive = true
            scrollLeadingConstraint = flushLeading
        }
        containerView.needsLayout = true
        containerView.layoutSubtreeIfNeeded()
    }

    func toggleLineNumbers() {
        EditorViewController.lineNumbersEnabled.toggle()
        applyLineNumberPreference()
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

    // MARK: - Auto-pair (brackets, quotes, fences)

    /// Characters that auto-insert their closing pair when typed. The first
    /// element is what the user types; the second is what gets inserted
    /// after the cursor.
    private static let autoPairs: [(open: String, close: String)] = [
        ("(", ")"),
        ("[", "]"),
        ("{", "}"),
        ("\"", "\""),
        ("'", "'"),
        ("*", "*"),
        ("_", "_"),
        ("`", "`"),
        ("$", "$")
    ]

    /// Called from NSTextViewDelegate.shouldChangeText. If the user is about
    /// to insert a single auto-pair-open character at a collapsed selection,
    /// we insert both characters and place the cursor between them — and
    /// suppress the original change.
    private func handleAutoPair(replacementString: String?) -> Bool {
        guard let typed = replacementString, typed.count == 1 else { return false }
        let selected = textView.selectedRange()
        guard selected.length == 0 else {
            // Selection present: wrap the selection in the pair if the typed
            // character is one of the pair openers.
            for pair in Self.autoPairs where pair.open == typed {
                return wrapSelection(with: pair, range: selected)
            }
            return false
        }
        for pair in Self.autoPairs where pair.open == typed {
            // Skip auto-pair if the next character is the closing one we'd
            // insert — typing `)` next to `)` should just move past it,
            // typing `"` next to `"` shouldn't double up.
            let ns = textView.string as NSString
            if selected.location < ns.length {
                let next = ns.substring(with: NSRange(location: selected.location, length: 1))
                if next == pair.close { return false }
            }
            // Skip if the previous character is a word character and the
            // typed char is `'` (so contractions like "don't" still work).
            if pair.open == "'" && selected.location > 0 {
                let prev = ns.substring(with: NSRange(location: selected.location - 1, length: 1))
                if !prev.isEmpty, let scalar = prev.unicodeScalars.first,
                   scalar.properties.isAlphabetic { return false }
            }
            // Insert open + close, position cursor between them.
            let combined = pair.open + pair.close
            if textView.shouldChangeText(in: selected, replacementString: combined) {
                textView.textStorage?.replaceCharacters(in: selected, with: combined)
                textView.didChangeText()
                let between = NSRange(location: selected.location + (pair.open as NSString).length, length: 0)
                textView.setSelectedRange(between)
                currentSource = textView.string
                return true
            }
            return false
        }
        return false
    }

    private func wrapSelection(with pair: (open: String, close: String), range: NSRange) -> Bool {
        let ns = textView.string as NSString
        let selected = ns.substring(with: range)
        let combined = pair.open + selected + pair.close
        if textView.shouldChangeText(in: range, replacementString: combined) {
            textView.textStorage?.replaceCharacters(in: range, with: combined)
            textView.didChangeText()
            // Re-select the formerly-selected text inside the new pair.
            let inside = NSRange(location: range.location + (pair.open as NSString).length, length: (selected as NSString).length)
            textView.setSelectedRange(inside)
            currentSource = textView.string
            return true
        }
        return false
    }

    // MARK: - NSTextViewDelegate

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if handleAutoPair(replacementString: replacementString) { return false }
        return true
    }

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
        let result = DocumentSnapshot.lineColumn(in: currentSource, utf16Offset: offset)
        return (result.line, result.column)
    }

    // MARK: - Insert helpers (wired from Insert menu)

    func insertCodeBlock() { insertBlock(.code) }
    func insertMathBlock() { insertBlock(.math) }
    func insertMermaidBlock() { insertBlock(.mermaid) }

    private func insertBlock(_ template: BlockTemplate) {
        let selection = textView.selectedRange()
        let plan = template.plan(insertingAt: selection.location, in: textView.string)
        textView.insertText(plan.inserted, replacementRange: selection)
        textView.setSelectedRange(plan.placeholderRange)
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
