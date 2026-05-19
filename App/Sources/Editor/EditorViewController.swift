import Cocoa
import WritCore

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

protocol EditorViewControllerDelegate: AnyObject {
    func editor(_ controller: EditorViewController, didChangeText newText: String)
    func editor(_ controller: EditorViewController, didChangeSelectionTo location: (line: Int, column: Int))
    func editor(_ controller: EditorViewController, didScrollToRatio ratio: Double)
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
        guard let contentView = scrollView.contentView as NSClipView? else { return }
        let docHeight = scrollView.documentView?.frame.height ?? 0
        let visibleHeight = contentView.bounds.height
        let scrollable = max(1, docHeight - visibleHeight)
        let ratio = Double(contentView.bounds.origin.y / scrollable).clamped(to: 0...1)
        // Filter sub-percent jitter to avoid spamming the bridge.
        if abs(ratio - lastScrollRatio) < 0.005 { return }
        lastScrollRatio = ratio
        delegate?.editor(self, didScrollToRatio: ratio)
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
        let result = DocumentSnapshot.lineColumn(in: currentSource, utf16Offset: offset)
        return (result.line, result.column)
    }

    // MARK: - Insert helpers (wired from Insert menu)

    func insertCodeBlock() {
        insertBlockTemplate(prefix: "```\n", placeholder: "code", suffix: "\n```")
    }

    func insertMathBlock() {
        insertBlockTemplate(prefix: "$$\n", placeholder: "x^2 + y^2 = z^2", suffix: "\n$$")
    }

    func insertMermaidBlock() {
        insertBlockTemplate(prefix: "```mermaid\n", placeholder: "graph TD\n  A --> B", suffix: "\n```")
    }

    private func insertBlockTemplate(prefix: String, placeholder: String, suffix: String) {
        let selection = textView.selectedRange()
        let block = "\(prefix)\(placeholder)\(suffix)\n"
        // Ensure a blank line above and below so the fence is in its own block.
        let storage = textView.textStorage
        let needsLeadingBlank: Bool = {
            guard let storage, selection.location > 0 else { return false }
            let prevIdx = selection.location - 1
            let prev = (storage.string as NSString).substring(with: NSRange(location: max(0, prevIdx - 1), length: min(2, prevIdx + 1)))
            return !prev.hasSuffix("\n\n") && !prev.isEmpty
        }()
        let toInsert = (needsLeadingBlank ? "\n" : "") + block
        textView.insertText(toInsert, replacementRange: selection)
        // Select the placeholder so the user can immediately type to replace it.
        let placeholderStart = selection.location + (needsLeadingBlank ? 1 : 0) + (prefix as NSString).length
        let placeholderRange = NSRange(location: placeholderStart, length: (placeholder as NSString).length)
        textView.setSelectedRange(placeholderRange)
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
