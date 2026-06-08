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
    // Internal so EditorFormatting extension (in a sibling file) can
    // sync after textStorage edits.
    var currentSource: String = ""
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

        // The WritTextView subclass paints its own full-width code-block
        // background in drawBackground(in:). Nothing more to wire up here.

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
        // Force the text view's frame width to track the clip view's
        // bounds width. Autoresizing-mask-based width tracking via
        // `.width` + `widthTracksTextView` is unreliable under
        // TextKit 2 (the document view sometimes ends up wider than
        // the clip view, producing horizontal overflow). Observe the
        // clip view's frame and pin the document view manually.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: scroll.contentView
        )

        // The async syntax highlighter applies an attribute-only pass
        // over the document. Under TextKit 2 attribute changes don't
        // always trigger a redraw of off-viewport regions; nudge the
        // textView whenever the storage finishes processing an
        // attribute edit. Character mutations are left to TextKit's
        // native path.
        textView.textStorage?.delegate = self
    }

    @objc private func clipViewFrameDidChange(_ note: Notification) {
        let clipWidth = scrollView.contentView.bounds.width
        guard clipWidth > 0 else { return }
        var frame = textView.frame
        // Preserve the textView's height (it tracks document length)
        // and clamp width to the clip view's bounds.
        if frame.width != clipWidth {
            frame.size.width = clipWidth
            textView.frame = frame
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        applyLineNumberPreference()
        // First-layout sync — the clip view's frame is final by the
        // time we reach viewWillAppear, but its frameDidChange
        // notification may have already fired during setup when the
        // bounds were still the default 200×200.
        clipViewFrameDidChange(Notification(name: NSView.frameDidChangeNotification))
        // Listen for font-preference updates so every open editor
        // applies the new family live, without needing to reopen
        // the document.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(editorFontPreferenceDidChange(_:)),
            name: EditorViewController.editorFontDidChange,
            object: nil
        )
    }

    @objc private func editorFontPreferenceDidChange(_ note: Notification) {
        applyFontPreference()
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
        // Custom NSTextView subclass paints a full-width background behind
        // fenced code-block ranges before super.drawBackground draws the
        // editor's normal background.
        let frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        let textContainer = NSTextContainer(size: NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude))
        let textLayoutManager = NSTextLayoutManager()
        textLayoutManager.textContainer = textContainer
        let textContentStorage = NSTextContentStorage()
        textContentStorage.addTextLayoutManager(textLayoutManager)
        let textView = WritTextView(frame: frame, textContainer: textContainer)
        return textView
    }

    /// Curated list of monospace families the picker offers. Order is
    /// preference order: SF Mono first because it's the system default
    /// on modern macOS, then the most common installed families. Any
    /// entry not actually installed on the host is filtered out at
    /// query time (see `availableFontFamilies`).
    static let candidateFontFamilies: [String] = [
        "SF Mono",
        "Menlo",
        "Monaco",
        "JetBrains Mono",
        "Iosevka",
        "Fira Code",
        "Courier New"
    ]

    static let fontFamilyDefaultsKey = "WritEditorFontFamily"

    /// Family-name preference. `nil` means "use system default" — we
    /// fall back to `NSFont.monospacedSystemFont` so we always render
    /// a real font even if a previously-persisted family was uninstalled.
    static var selectedFontFamily: String? {
        get {
            let raw = UserDefaults.standard.string(forKey: fontFamilyDefaultsKey)
            guard let raw, !raw.isEmpty else { return nil }
            return raw
        }
        set {
            if let v = newValue, !v.isEmpty {
                UserDefaults.standard.set(v, forKey: fontFamilyDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: fontFamilyDefaultsKey)
            }
            NotificationCenter.default.post(name: editorFontDidChange, object: nil)
        }
    }

    static let editorFontDidChange = Notification.Name("org.ceesaxp.Writ.editorFontDidChange")

    static func availableFontFamilies() -> [String] {
        let manager = NSFontManager.shared
        return candidateFontFamilies.filter { family in
            // availableMembers returns nil for uninstalled families.
            manager.availableMembers(ofFontFamily: family) != nil
        }
    }

    static func editorFont() -> NSFont {
        if let family = selectedFontFamily,
           let font = NSFont(name: family, size: 13.0) {
            return font
        }
        if let mono = NSFont(name: "SF Mono", size: 13.0) { return mono }
        return NSFont.monospacedSystemFont(ofSize: 13.0, weight: .regular)
    }

    /// Apply the current font preference to the live text view +
    /// existing storage. Called from the editor-font notification
    /// observer (wired in viewWillAppear).
    func applyFontPreference() {
        let font = Self.editorFont()
        textView.font = font
        if let storage = textView.textStorage {
            let range = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.addAttribute(.font, value: font, range: range)
            storage.endEditing()
        }
        scheduleHighlight()
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

    /// Paragraph style with `minimumLineHeight == maximumLineHeight` locked
    /// to the base editor font's natural line height. Without this, any
    /// `.font` change in the syntax highlighter (bold for `**strong**`,
    /// italic for `*emphasis*`, heavier weight for headings) would change
    /// each affected fragment's intrinsic height — and TextKit 2 would
    /// silently re-measure fragments above the viewport, shifting their
    /// cumulative Y values and snapping the visible top line. Locking line
    /// height means every line occupies the same vertical space regardless
    /// of which font is set on its characters, so the layout stays stable.
    private static func fixedLineHeightParagraphStyle(for font: NSFont) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let lineHeight = font.ascender + abs(font.descender) + font.leading
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        return style
    }

    private func defaultAttributes() -> [NSAttributedString.Key: Any] {
        let font = Self.editorFont()
        return [
            .font: font,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: Self.fixedLineHeightParagraphStyle(for: font)
        ]
    }

    // MARK: - Auto-pair (brackets, quotes, fences)

    // MARK: - NSTextViewDelegate

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        // Auto-pair (typing "*" with a selection to wrap, etc.) is
        // handled inside `WritTextView.insertText` rather than here.
        // That avoids nesting `shouldChangeText` calls inside the
        // delegate dispatch — which corrupts NSTextView's undo
        // bookkeeping so Cmd-Z stops mid-sequence.
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

    /// Inserts a YAML front-matter template at the top of the document
    /// with `title`, `author`, and `date_created` keys (date filled
    /// with today's date). The caret lands right after `title: ` so
    /// the user can start typing immediately. No-op if the document
    /// already has a front-matter block.
    func insertFrontMatter() {
        if FrontMatterExtractor.extract(textView.string) != nil { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        let today = formatter.string(from: Date())
        let template = "---\ntitle: \nauthor: \ndate_created: \(today)\n---\n\n"
        let topRange = NSRange(location: 0, length: 0)
        textView.insertText(template, replacementRange: topRange)
        // Position the caret after the `title: ` label so typing the
        // title is the user's next action.
        let caret = ("---\ntitle: " as NSString).length
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    /// Accumulator for character-edit ranges between highlight passes.
    /// The highlighter is debounced 80 ms — multiple keystrokes can
    /// land in that window. We pass the union to the highlighter so it
    /// can compute the minimal scope that needs re-styling.
    fileprivate var pendingEditScope: NSRange?

    private func scheduleHighlight() {
        highlightThrottle?.cancel()
        let snapshot = currentSource
        let storage = textView.textStorage
        let attrs = defaultAttributes()
        highlightThrottle = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            if Task.isCancelled { return }
            guard let self else { return }
            // Disable heavy highlighting on large documents to keep typing
            // responsive — only base attributes are applied.
            guard snapshot.utf8.count < 500_000 else { return }
            let scope = self.pendingEditScope
            self.pendingEditScope = nil
            // The highlighter's attribute changes are not part of the
            // user's editing history — they're a presentation layer.
            // Disable undo registration around the pass so Cmd-Z steps
            // through the user's text edits cleanly instead of
            // alternating between attribute-only and text changes.
            let undoMgr = self.textView.undoManager
            undoMgr?.disableUndoRegistration()
            await self.syntaxHighlighter.applyHighlight(
                to: storage,
                source: snapshot,
                baseAttributes: attrs,
                editedRange: scope
            )
            undoMgr?.enableUndoRegistration()
            // Push the code-block ranges to the WritTextView so its
            // drawBackground pass can paint full-width fills.
            if let writTextView = self.textView as? WritTextView {
                writTextView.codeBlockRanges = self.syntaxHighlighter.codeBlockRanges
            }
        }
    }
}

extension EditorViewController: @preconcurrency NSTextStorageDelegate {
    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        if editedMask.contains(.editedCharacters) {
            // Accumulate the edited range so the next highlight pass
            // can scope its attribute changes around it. The union
            // covers all edits that landed within the highlighter's
            // 80 ms debounce window.
            if let existing = pendingEditScope {
                pendingEditScope = NSUnionRange(existing, editedRange)
            } else {
                pendingEditScope = editedRange
            }
            return
        }
        // Pure attribute edits (the highlighter's own pass) don't
        // always trigger a redraw of off-viewport regions — nudge the
        // text view so the new styling paints.
        if editedMask.contains(.editedAttributes) {
            textView.needsDisplay = true
        }
    }
}
