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

    /// Persisted preference for issue #1: when ON, the spell checker
    /// ignores text inside inline code (`` `…` ``) and fenced code
    /// blocks. Default OFF so existing behavior is preserved unless
    /// the user opts in.
    static let skipSpellCheckInCodeDefaultsKey = "WritSkipSpellCheckInCode"
    static var skipSpellCheckInCodeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: skipSpellCheckInCodeDefaultsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: skipSpellCheckInCodeDefaultsKey)
            NotificationCenter.default.post(name: EditorViewController.skipSpellCheckInCodeDidChange, object: nil)
        }
    }
    static let skipSpellCheckInCodeDidChange = Notification.Name("org.ceesaxp.Writ.skipSpellCheckInCodeDidChange")

    /// UTF-16 ranges that the spell-check filter should skip — inline
    /// code + fenced code blocks. Updated after every highlight pass.
    /// Used by `textView(_:didCheckTextIn:…)` to filter out spell-check
    /// results that fall inside code.
    private var spellCheckSkipRanges: [NSRange] = []

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
        // Seed the locked-line-height paragraph style into the typing
        // attributes from the start. Without this, any path that styles
        // text from typing attributes before the user first moves the
        // caret (`textView.string =` assignment, paste-as-plain-text
        // into an empty document) would fall back to natural metrics
        // and render with a different line height than setSource'd text.
        textView.defaultParagraphStyle = Self.fixedLineHeightParagraphStyle(for: Self.editorFont())
        textView.typingAttributes = defaultAttributes()
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
        // Re-run spell check when the "skip in code" preference flips
        // so any stale red squiggles inside `code` get cleared
        // (or, when turning the option off, restored).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(skipSpellCheckPreferenceDidChange(_:)),
            name: EditorViewController.skipSpellCheckInCodeDidChange,
            object: nil
        )
        // Apply source-view line-height changes live to every open editor.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(editorLineHeightPreferenceDidChange(_:)),
            name: EditorViewController.editorLineHeightDidChange,
            object: nil
        )
    }

    @objc private func editorFontPreferenceDidChange(_ note: Notification) {
        applyFontPreference()
        // Line height derives from the base font's metrics, so a font
        // change must recompute the locked paragraph height as well.
        applyLineHeightPreference()
    }

    @objc private func editorLineHeightPreferenceDidChange(_ note: Notification) {
        applyLineHeightPreference()
    }

    @objc private func skipSpellCheckPreferenceDidChange(_ note: Notification) {
        if EditorViewController.skipSpellCheckInCodeEnabled {
            // Going ON: clear any spelling-state attributes already
            // drawn inside code ranges so existing red squiggles
            // disappear immediately.
            clearSpellingStateInCodeRanges()
        } else {
            // Going OFF: re-run spell check across the whole document
            // so previously-suppressed code-range words come back as
            // squiggles where appropriate.
            textView.checkTextInDocument(nil)
        }
    }

    /// Clears any spell-check squiggles already drawn on code ranges.
    /// `.spellingState` is a temporary (rendering) attribute, not a
    /// storage attribute — under TK1 the NSText.setSpellingState path
    /// is the one that updates NSLayoutManager's temporary-attribute
    /// store.
    fileprivate func clearSpellingStateInCodeRanges() {
        guard !spellCheckSkipRanges.isEmpty else { return }
        let docLength = (textView.string as NSString).length
        for range in spellCheckSkipRanges {
            let clamped = NSIntersectionRange(range, NSRange(location: 0, length: docLength))
            guard clamped.length > 0 else { continue }
            textView.setSpellingState(0, range: clamped)
        }
    }

    private var lastScrollRatio: Double = 0

    /// Expected clip-view origin after a programmatic scroll. A scroll
    /// notification whose origin matches this value is our own scroll
    /// landing — swallowed so it can't echo back to the preview. Any
    /// other origin means the user moved the view: clear the expectation
    /// and resume broadcasting. Deterministic replacement for the old
    /// fixed-delay suppression flag, whose overlapping 0.25 s timers
    /// leaked during continuous wheel scrolling and let block-start
    /// echoes snap the viewport backwards.
    private var expectedScrollOriginY: CGFloat?

    @objc private func scrollViewDidScroll(_ note: Notification) {
        guard let contentView = scrollView.contentView as NSClipView? else { return }
        let originY = contentView.bounds.origin.y
        if let expected = expectedScrollOriginY {
            if abs(originY - expected) < 2 { return }
            expectedScrollOriginY = nil
        }
        let docHeight = scrollView.documentView?.frame.height ?? 0
        let visibleHeight = contentView.bounds.height
        let scrollable = max(1, docHeight - visibleHeight)
        let ratio = Double(originY / scrollable).clamped(to: 0...1)
        if abs(ratio - lastScrollRatio) < 0.005 { return }
        lastScrollRatio = ratio
        delegate?.editor(self, didScrollToRatio: ratio, topSourceLine: topVisibleSourceLine())
    }

    /// Programmatically scroll so the given 1-indexed source line is at
    /// the top of the visible area. Used by the preview → editor scroll
    /// sync. Records the target origin so the resulting scroll
    /// notification is recognised as our own and not re-broadcast.
    func scrollToSourceLine(_ line: Int) {
        guard let layoutManager = textView.layoutManager else { return }
        // Map 1-indexed line → UTF-16 offset → glyph → line-fragment frame.
        let utf16 = currentSource.utf16
        var lineIndex = 1
        var consumed = 0
        var idx = utf16.startIndex
        while idx < utf16.endIndex && lineIndex < line {
            if utf16[idx] == 0x0A { lineIndex += 1 }
            idx = utf16.index(after: idx)
            consumed += 1
        }
        let docLength = layoutManager.numberOfGlyphs
        guard consumed <= (textView.string as NSString).length else { return }
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: consumed)
        guard glyphIndex <= docLength else { return }
        let lineRect = layoutManager.lineFragmentRect(
            forGlyphAt: min(glyphIndex, max(0, docLength - 1)),
            effectiveRange: nil
        )
        // lineFragmentRect is in container coords; translate to textView.
        // Clamp to the scrollable range up front: setBoundsOrigin posts
        // the bounds-changed notification synchronously, so the expected
        // origin must equal where the clip view actually lands or our
        // own scroll gets mis-classified as user input.
        let y = lineRect.minY + textView.textContainerOrigin.y
        let docHeight = scrollView.documentView?.frame.height ?? 0
        let maxOriginY = max(0, docHeight - scrollView.contentView.bounds.height)
        let targetY = min(max(0, y), maxOriginY)
        expectedScrollOriginY = targetY
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Current scroll position as (proportional ratio, 1-indexed top
    /// source line). Used by the window controller's one-shot pane
    /// alignment when a mode switch reveals the preview.
    func currentScrollPosition() -> (ratio: Double, topLine: Int) {
        let contentView = scrollView.contentView
        let docHeight = scrollView.documentView?.frame.height ?? 0
        let scrollable = max(1, docHeight - contentView.bounds.height)
        let ratio = Double(contentView.bounds.origin.y / scrollable).clamped(to: 0...1)
        return (ratio, topVisibleSourceLine())
    }

    /// Computes the 1-indexed source line at the top of the editor's
    /// visible area. Used for block-aware preview scroll sync — the bridge
    /// passes this to the preview so it can align the matching block.
    private func topVisibleSourceLine() -> Int {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return 1 }
        let containerOrigin = textView.textContainerOrigin
        let visibleRect = scrollView.contentView.bounds
        let containerVisible = NSRect(
            x: visibleRect.minX - containerOrigin.x,
            y: visibleRect.minY - containerOrigin.y,
            width: visibleRect.width,
            height: visibleRect.height
        )
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: containerVisible, in: textContainer)
        let firstChar = layoutManager.characterIndexForGlyph(at: visibleGlyphs.location)
        return DocumentSnapshot.lineColumn(in: currentSource, utf16Offset: firstChar).line
    }

    private func makeTextView() -> NSTextView {
        // TK1 stack. macOS 14+ NSTextView defaults to TextKit 2, whose lazy
        // viewport-based layout caused visible keystroke latency on
        // multi-hundred-line docs (paints had to wait for fragment
        // re-measurement even after sub-ms storage edits). TK1 lays out
        // eagerly which is faster for the doc sizes Writ targets, and it
        // sidesteps a class of TK2-specific quirks (snap-on-Enter from
        // fragment-height recompute, ensuresLayout cost inside gutter
        // draw, font-change re-measurement after attribute edits).
        //
        // Order matters: storage owns the layout manager, layout manager
        // owns the container, NSTextView is initialised with the
        // container. Passing a TK1 container (one whose `layoutManager`
        // is non-nil) is what locks the textView into the TK1 path.
        let frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)
        let textView = WritTextView(frame: frame, textContainer: textContainer)
        // Runtime proof of which TextKit path we're on. If the migration
        // worked we expect `layoutManager` non-nil and `textLayoutManager`
        // nil. If it's the other way around, NSTextView ignored our
        // container and instantiated a fresh TK2 stack — and the
        // perf hunt needs to look elsewhere.
        LatencyProbe.log.notice(
            "textView built — textKit1=\(textView.layoutManager != nil, privacy: .public) textKit2=\(textView.textLayoutManager != nil, privacy: .public)"
        )
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
        // Route through setSource rather than `textView.string =` — the
        // string setter styles the whole document from the caret's
        // typing attributes, so a foreign paragraph style at the caret
        // (e.g. inherited from previously pasted rich text) would
        // spread document-wide. setSource rebuilds with the canonical
        // default attributes.
        setSource(currentSource)
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
        let naturalHeight = font.ascender + abs(font.descender) + font.leading
        let lineHeight = naturalHeight * Self.lineHeightMultiple
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        return style
    }

    static let lineHeightDefaultsKey = "WritEditorLineHeightMultiple"

    /// Comfortable default — ~25% over the font's natural metrics.
    static let lineHeightMultipleDefault: CGFloat = 1.25

    /// Allowed range for the source-view line-height multiple. `1.0` is
    /// the tight, default-metrics look; `1.5` is airy. Preferences steps
    /// between these in 0.05 increments.
    static let lineHeightMultipleRange: ClosedRange<CGFloat> = 1.0...1.5

    /// Vertical breathing room applied on top of the font's natural line
    /// height. Applied as a fixed multiple (not `lineHeightMultiple` on the
    /// paragraph style) so `minimumLineHeight == maximumLineHeight` stays
    /// exact and the highlighter's per-fragment font swaps can't shift line
    /// positions. Persisted in UserDefaults; changes post
    /// `editorLineHeightDidChange` so every open editor re-applies live.
    static var lineHeightMultiple: CGFloat {
        get {
            guard UserDefaults.standard.object(forKey: lineHeightDefaultsKey) != nil else {
                return lineHeightMultipleDefault
            }
            let raw = CGFloat(UserDefaults.standard.double(forKey: lineHeightDefaultsKey))
            return min(lineHeightMultipleRange.upperBound, max(lineHeightMultipleRange.lowerBound, raw))
        }
        set {
            let clamped = min(lineHeightMultipleRange.upperBound, max(lineHeightMultipleRange.lowerBound, newValue))
            UserDefaults.standard.set(Double(clamped), forKey: lineHeightDefaultsKey)
            NotificationCenter.default.post(name: editorLineHeightDidChange, object: nil)
        }
    }

    static let editorLineHeightDidChange = Notification.Name("org.ceesaxp.Writ.editorLineHeightDidChange")

    /// Re-apply the current line-height multiple to the live text view +
    /// existing storage. Called from the line-height notification observer
    /// (wired in viewWillAppear). Mirrors `applyFontPreference`: the
    /// highlighter preserves `.paragraphStyle`, so re-adding the recomputed
    /// style across the whole range is the single re-application point.
    func applyLineHeightPreference() {
        let style = Self.fixedLineHeightParagraphStyle(for: Self.editorFont())
        if let storage = textView.textStorage {
            let range = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.addAttribute(.paragraphStyle, value: style, range: range)
            storage.endEditing()
        }
        textView.defaultParagraphStyle = style
        textView.typingAttributes[.paragraphStyle] = style
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

    /// Filter spell-check results so words inside code (inline or
    /// fenced block) aren't flagged. Gated on the `skipSpellCheckInCode`
    /// preference — when off, the original results pass through
    /// untouched. Issue #1.
    func textView(
        _ textView: NSTextView,
        didCheckTextIn range: NSRange,
        types checkingTypes: NSTextCheckingTypes,
        options: [NSSpellChecker.OptionKey: Any],
        results: [NSTextCheckingResult],
        orthography: NSOrthography,
        wordCount: Int
    ) -> [NSTextCheckingResult] {
        guard Self.skipSpellCheckInCodeEnabled else { return results }
        guard !spellCheckSkipRanges.isEmpty else { return results }
        return results.filter { result in
            !spellCheckSkipRanges.contains { skip in
                NSIntersectionRange(skip, result.range).length > 0
            }
        }
    }

    func textDidChange(_ notification: Notification) {
        guard !suppressDelegateBroadcast else { return }
        let start = LatencyProbe.enabled ? CFAbsoluteTimeGetCurrent() : 0
        let text = textView.string
        currentSource = text
        delegate?.editor(self, didChangeText: text)
        scheduleHighlight()
        if LatencyProbe.enabled {
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            LatencyProbe.log.info("textDidChange total \(ms, format: .fixed(precision: 2))ms (doc=\(text.utf8.count, privacy: .public)B)")
        }
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
            // Stash all-code ranges for the spell-check skip filter.
            self.spellCheckSkipRanges = self.syntaxHighlighter.allCodeRanges
            if EditorViewController.skipSpellCheckInCodeEnabled {
                // Clear any spell-check squiggles the spell checker
                // may have drawn on code words *before* the highlighter
                // detected the range (the spell checker can race ahead
                // of our 80ms throttle on fresh typing).
                self.clearSpellingStateInCodeRanges()
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
