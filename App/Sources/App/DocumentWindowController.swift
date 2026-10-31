import Cocoa
import os
import WritCore

private let dwcLog = Logger(subsystem: "org.ceesaxp.Writ", category: "window")

/// Owns the window, the split-view layout, and the wiring between editor,
/// preview, and the document. One controller per document window.
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    enum LayoutMode: String, CaseIterable { case source, preview, split }

    /// UserDefaults-backed default layout for newly-opened windows.
    /// `source` is the conservative default — opens fast and matches the
    /// "writing first, preview on demand" model.
    private static let defaultLayoutDefaultsKey = "WritDefaultLayoutMode"
    static var defaultLaunchLayout: LayoutMode {
        get {
            let raw = UserDefaults.standard.string(forKey: defaultLayoutDefaultsKey)
            return raw.flatMap(LayoutMode.init(rawValue:)) ?? .source
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultLayoutDefaultsKey)
        }
    }

    /// Holds the editor/preview divider fraction and decides which resize
    /// notifications are the user's. Per window: the gate tracks *this*
    /// window's layout transitions, even though the fraction it reads and
    /// writes is shared across windows.
    private let splitFraction = SplitFractionStore()

    let editor: EditorViewController
    let preview: PreviewViewController
    let statusBar: StatusBarViewController
    let outline: OutlineSidebarController
    private let splitController: NSSplitViewController
    private let containerController: NSViewController
    private var outlineSplitItem: NSSplitViewItem!
    private(set) var layoutMode: LayoutMode = DocumentWindowController.defaultLaunchLayout

    private let toolbarIdentifier = NSToolbar.Identifier("WritToolbar")
    private let layoutItemIdentifier = NSToolbarItem.Identifier("WritLayoutMode")

    private weak var writDocument: WritDocument?

    /// Debounce token for the expensive post-edit work (word count,
    /// outline rebuild). Both are O(N) over the document and add a
    /// solid 5–15 ms per keystroke on non-trivial docs — they don't
    /// need to update every keystroke. Cancel + reschedule on each
    /// edit; run after ~250 ms of quiet so the status bar / outline
    /// catch up between bursts of typing.
    private var deferredCountsTask: Task<Void, Never>?

    init(document: WritDocument) {
        self.writDocument = document
        self.editor = EditorViewController()
        self.preview = PreviewViewController()
        self.statusBar = StatusBarViewController()
        self.outline = OutlineSidebarController()
        self.splitController = NSSplitViewController()

        let split = splitController.splitView
        split.dividerStyle = .paneSplitter
        split.isVertical = true
        // Deliberately no `autosaveName` — AppKit's NSSplitView autosave
        // path crashes on macOS Sequoia when display configuration changes
        // during sleep/wake (`-[__NSSetM copy]` from inside
        // `_autosaveSubviewLayoutIfNecessary`, reproducer 2026-06-10
        // wake-up crash). We persist the divider fraction ourselves via
        // `SplitFractionStore` and the resize notification below.

        let outlineItem = NSSplitViewItem(sidebarWithViewController: outline)
        outlineItem.minimumThickness = 180
        outlineItem.maximumThickness = 360
        outlineItem.canCollapse = true
        outlineItem.collapseBehavior = .preferResizingSplitViewWithFixedSiblings
        outlineItem.isCollapsed = true // start hidden — toggle via View menu
        outlineSplitItem = outlineItem

        let editorItem = NSSplitViewItem(viewController: editor)
        editorItem.minimumThickness = 280
        editorItem.holdingPriority = .defaultLow
        // The editor and preview are alternates within one editing area, so
        // collapsing either must resize its sibling, never the split view
        // (and with it the window). Left at `.default` AppKit resolves this
        // to `preferResizingSplitViewWithFixedSiblings` — see `setLayout`
        // for how that ratcheted the window wider on every mode switch.
        // The header notes the `.default` mapping "may change over time",
        // which is reason enough to state the intent explicitly.
        editorItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView

        let previewItem = NSSplitViewItem(viewController: preview)
        previewItem.minimumThickness = 280
        previewItem.holdingPriority = .defaultLow
        previewItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView

        splitController.addSplitViewItem(outlineItem)
        splitController.addSplitViewItem(editorItem)
        splitController.addSplitViewItem(previewItem)

        // Apply the persisted default-launch layout *before* the window
        // first paints so users don't see a brief split-view flash before
        // we collapse a pane.
        switch DocumentWindowController.defaultLaunchLayout {
        case .source:
            previewItem.isCollapsed = true
        case .preview:
            editorItem.isCollapsed = true
        case .split:
            break
        }

        let container = NSViewController()
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 760))
        containerView.autoresizingMask = [.width, .height]
        container.view = containerView
        self.containerController = container

        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1200, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.contentViewController = container
        super.init(window: window)
        container.addChild(splitController)
        container.addChild(statusBar)

        let splitView = splitController.view
        let statusView = statusBar.view
        splitView.translatesAutoresizingMaskIntoConstraints = false
        statusView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(splitView)
        containerView.addSubview(statusView)

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: containerView.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: statusView.topAnchor),
            statusView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            statusView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            statusView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            statusView.heightAnchor.constraint(equalToConstant: 22)
        ])

        window.delegate = self
        installToolbar(on: window)

        // Persist the editor/preview divider position whenever the split
        // view changes size. Two independent gates filter what arrives
        // here, because this notification says nothing about who caused
        // the resize: the mode gate in `splitViewDidResize` (only `.split`
        // shows both panes), and the transition gate inside
        // `SplitFractionStore` (only once a restore has landed). The mode
        // gate alone is not enough — see `setLayout`.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(splitViewDidResize(_:)),
            name: NSSplitView.didResizeSubviewsNotification,
            object: splitController.splitView
        )

        editor.delegate = self
        document.bridge.attach(preview: preview, statusBar: statusBar)
        let docDir = document.fileURL?.deletingLastPathComponent()
        preview.documentDirectory = docDir
        document.bridge.documentDirectory = docDir
        preview.onPreviewScrolled = { [weak self] line in
            guard let self, self.layoutMode == .split else { return }
            self.editor.scrollToSourceLine(line)
        }
        outline.onSelectHeading = { [weak self] heading in
            guard let self else { return }
            // Scroll the editor first so the source line is on screen,
            // then nudge the preview directly. Editor's scroll-observer
            // is debounced/suppressed during programmatic scrolls and
            // wouldn't fire the editor→preview sync, so the preview
            // would otherwise stay where it was until the user touched
            // the editor.
            self.editor.scrollToSourceLine(heading.line)
            self.preview.scrollToSourceLine(heading.line, fallbackRatio: 0)
        }
        window.makeFirstResponder(editor.textView)
        window.setFrameAutosaveName("WritMainWindow")

        // When a real document opens, close any leftover empty-untitled
        // documents that the launch placeholder left behind. Only closes
        // documents that are still untitled (no fileURL) AND clean
        // (no edits) so we never lose user work.
        if document.fileURL != nil {
            DispatchQueue.main.async {
                Self.closeEmptyUntitledDocuments(except: document)
            }
        }
    }

    /// Closes every other open document that is still untitled and has no
    /// unsaved edits. Called whenever a saved-on-disk document opens so
    /// the launch placeholder doesn't linger.
    @MainActor
    static func closeEmptyUntitledDocuments(except keeper: NSDocument) {
        for doc in NSDocumentController.shared.documents {
            guard doc !== keeper else { continue }
            if doc.fileURL == nil && !doc.isDocumentEdited {
                doc.close()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    deinit {
        // PreviewBridge.cancelAll is main-actor isolated. deinit runs on
        // whichever thread releases the last reference; hop to main to clean
        // up. Capture the document weakly so we don't extend its lifetime
        // beyond what AppKit already keeps.
        //
        // Read isolated property *before* `removeObserver(self)` — Swift 6
        // strict concurrency treats passing `self` to an external call as
        // "copying self", after which isolated properties can no longer
        // be accessed from a deinit.
        let doc = writDocument
        NotificationCenter.default.removeObserver(self)
        Task { @MainActor in doc?.bridge.cancelAll() }
    }

    @objc private func splitViewDidResize(_ note: Notification) {
        guard layoutMode == .split else { return }
        let editorItem = splitController.splitViewItems[1]
        let previewItem = splitController.splitViewItems[2]
        let editorWidth = editorItem.viewController.view.bounds.width
        let previewWidth = previewItem.viewController.view.bounds.width
        let persisted = splitFraction.splitDidResize(
            editorWidth: Double(editorWidth),
            previewWidth: Double(previewWidth)
        )
        let attempted = editorWidth + previewWidth > 0
            ? Double(editorWidth / (editorWidth + previewWidth))
            : -1
        dwcLog.notice("splitViewDidResize attempted=\(attempted, format: .fixed(precision: 4)) persisted=\(persisted)")
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        applyLoadedSource()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // Restore the persisted editor/preview divider fraction. Only
        // meaningful when the launch layout is `.split` — the other
        // modes don't show both panes.
        guard layoutMode == .split else { return }
        DispatchQueue.main.async { [weak self] in
            self?.applyPersistedSplitFraction()
        }
    }

    /// Place the editor/preview divider at the persisted fraction, then
    /// hand the gate back to the user.
    ///
    /// Indices after the outline sidebar was prepended: 0 = outline
    /// (sidebar), 1 = editor, 2 = preview. Divider 1 sits between the
    /// editor and the preview.
    private func applyPersistedSplitFraction() {
        splitController.splitView.layoutSubtreeIfNeeded()
        let split = splitController.splitView
        // Geometry must come from the split view's *arranged subviews*, not
        // from `splitViewItems[i].viewController.view`. AppKit wraps each
        // item's view, so the view controller's own frame is relative to
        // that wrapper and its `minX` reads 0 wherever the pane actually
        // sits; and a collapsed item's view keeps its pre-collapse bounds
        // rather than going to zero. Measured on macOS 27 in a 1101pt split
        // with a 300pt outline (Scripts-free AppKit probe, 2026-10-31):
        //
        //   outline hidden: arranged[1].minX = 0    vc.view.minX = 0
        //                   arranged[0].width = 300 (stale, isHidden=true)
        //   outline shown : arranged[1].minX = 300  vc.view.minX = 0
        //
        // The previous formula used the *outline item's* bounds width as the
        // divider's left origin. That is accidentally correct while the
        // outline is visible (300) and wrong whenever it is collapsed, where
        // it contributes a stale 300 instead of 0. The outline starts
        // collapsed, so the restore asked for a divider 300pt too far right,
        // `minimumThickness = 280` clamped it straight back, and
        // `setPosition` became a silent no-op that left the preview at
        // exactly its minimum — the narrow preview, whatever fraction was
        // stored. Verified: with this origin, fractions 0.30/0.50/0.70 land
        // at 0.3002/0.5000/0.7000 with the outline hidden and 0.35/0.50 at
        // 0.3526/0.5000 with it shown (0.3526 is the editor's own 280pt
        // minimum, not an error in the formula).
        let arranged = split.arrangedSubviews
        guard arranged.count >= 3 else {
            dwcLog.notice("applyPersistedSplitFraction skipped: \(arranged.count) arranged subviews")
            return
        }
        let editorFrame = arranged[1].frame
        let editingAreaWidth = editorFrame.width + arranged[2].frame.width
        guard editingAreaWidth > 0 else {
            // The gate stays closed on purpose: a split view with no width
            // yet is precisely the state whose resize notifications are
            // AppKit's. The next entry into split restores and opens it.
            dwcLog.notice("applyPersistedSplitFraction skipped: editingAreaWidth=0, gate stays closed")
            return
        }
        let fraction = splitFraction.stored
        let dividerOffset = editorFrame.minX + editingAreaWidth * CGFloat(fraction)
        split.setPosition(dividerOffset, ofDividerAt: 1)
        // `setPosition` posts the resize notification itself, and
        // `minimumThickness` may clamp what it was asked for. Flush that
        // layout synchronously while the gate is still closed, otherwise
        // the clamped geometry is persisted and the stored fraction
        // ratchets a little further on every switch.
        split.layoutSubtreeIfNeeded()
        let achievedEditor = split.arrangedSubviews[1].frame.width
        let achievedPreview = split.arrangedSubviews[2].frame.width
        dwcLog.notice("applyPersistedSplitFraction fraction=\(fraction, format: .fixed(precision: 4)) editor=\(Double(achievedEditor), format: .fixed(precision: 1)) preview=\(Double(achievedPreview), format: .fixed(precision: 1))")
        // Open the gate one runloop turn later so anything AppKit defers
        // past the synchronous flush is suppressed too. A user cannot drag
        // the divider within the same turn, so no real resize is lost.
        DispatchQueue.main.async { [weak self] in
            self?.splitFraction.restoreDidLand()
        }
    }

    func applyLoadedSource() {
        guard let doc = writDocument else {
            dwcLog.error("applyLoadedSource: writDocument is nil")
            return
        }
        dwcLog.notice("applyLoadedSource bytes=\(doc.sourceText.utf8.count)")
        editor.setSource(doc.sourceText)
        statusBar.update(
            byteCount: doc.sourceText.utf8.count,
            lineCount: doc.sourceText.lineCountWrit,
            wordCount: DocumentSnapshot.wordCount(in: doc.sourceText),
            status: .idle
        )
        outline.update(with: doc.sourceText)
        doc.bridge.scheduleUpdate(source: doc.sourceText)
    }

    func installToolbar(on window: NSWindow) {
        let toolbar = NSToolbar(identifier: toolbarIdentifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.sizeMode = .small
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
    }

    // MARK: - Toolbar delegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [layoutItemIdentifier, .flexibleSpace]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, layoutItemIdentifier]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == layoutItemIdentifier else { return nil }
        let item = NSToolbarItem(itemIdentifier: layoutItemIdentifier)
        let segmented = NSSegmentedControl(labels: ["Source", "Split", "Preview"], trackingMode: .selectOne, target: self, action: #selector(toolbarLayoutChanged(_:)))
        segmented.selectedSegment = layoutMode == .source ? 0 : layoutMode == .split ? 1 : 2
        item.view = segmented
        item.label = "Layout"
        return item
    }

    @objc private func toolbarLayoutChanged(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: setLayout(.source)
        case 1: setLayout(.split)
        case 2: setLayout(.preview)
        default: break
        }
    }

    // MARK: - View menu commands

    @objc func showSourceOnly(_ sender: Any?) { setLayout(.source) }
    @objc func showPreviewOnly(_ sender: Any?) { setLayout(.preview) }
    @objc func showSplit(_ sender: Any?) { setLayout(.split) }

    @objc func refreshPreview(_ sender: Any?) {
        guard let doc = writDocument else { return }
        doc.bridge.forceRefresh(source: doc.sourceText)
    }

    @objc func insertCodeBlockMenu(_ sender: Any?) {
        editor.insertCodeBlock()
    }

    @objc func insertMathBlockMenu(_ sender: Any?) {
        editor.insertMathBlock()
    }

    @objc func insertMermaidBlockMenu(_ sender: Any?) {
        editor.insertMermaidBlock()
    }

    @objc func insertFrontMatterMenu(_ sender: Any?) {
        editor.insertFrontMatter()
    }

    @objc func toggleLineNumbers(_ sender: Any?) {
        editor.toggleLineNumbers()
    }

    @objc func toggleOutline(_ sender: Any?) {
        // Direct mutation rather than going through .animator() — the
        // sidebar-style split item ignores the animation proxy in some
        // macOS releases and the toggle silently no-ops.
        outlineSplitItem.isCollapsed.toggle()
        // Refresh the outline whenever it becomes visible so the user
        // doesn't see stale data after editing while it was collapsed.
        if !outlineSplitItem.isCollapsed, let doc = writDocument {
            outline.update(with: doc.sourceText)
        }
    }

    // @objc is required: validateMenuItem comes from NSMenuItemValidation,
    // and a non-@objc method on a Swift subclass is invisible to AppKit's
    // ObjC-runtime lookup. Without it, the menu titles never refresh.
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleLineNumbers(_:)) {
            item.title = EditorViewController.lineNumbersEnabled ? "Hide Line Numbers" : "Show Line Numbers"
            return true
        }
        if item.action == #selector(toggleOutline(_:)) {
            item.title = outlineSplitItem.isCollapsed ? "Show Outline" : "Hide Outline"
            return true
        }
        return true
    }

    private func setLayout(_ mode: LayoutMode) {
        let previous = layoutMode
        layoutMode = mode
        // Indices after the outline sidebar was prepended: 0 = outline,
        // 1 = editor, 2 = preview. The Source/Split/Preview switcher only
        // touches editor and preview; the outline visibility is independent.
        let editorItem = splitController.splitViewItems[1]
        let previewItem = splitController.splitViewItems[2]

        // Switching layout mode must never change the window's size. A
        // collapsed pane remembers the thickness it had when it was
        // collapsed, which in a single-pane mode is the full content
        // width. Uncollapsing it while a sibling is still visible
        // therefore asks for roughly twice the available width, and
        // NSSplitViewController grants it by widening the *window*:
        //   -[NSSplitViewController _collapse:splitViewItem:animated:…]
        //   -> -[NSWindow layoutIfNeeded]
        //   -> -[NSWindow _changeWindowFrameFromConstraintsIfNecessary]
        // The window never shrinks back, so it ratcheted wider on every
        // switch (reported 2026-08-21: Source -> Preview -> Source grows
        // the window by a whole pane, repeatedly).
        //
        // Two defenses. First, collapse the outgoing pane *before*
        // uncollapsing the incoming one, so Source/Preview never have a
        // transient where both are uncollapsed. Second, entering Split
        // legitimately needs both panes at once, so pin the frame across
        // the mutation and put it back if AppKit moved it.
        //
        // Toggling the outline sidebar goes through `toggleOutline` and is
        // deliberately *not* covered — growing the window to make room for
        // a sidebar is standard macOS behavior.
        let frameBeforeSwitch = window?.frame

        // Everything the collapse mutation below provokes is AppKit's, not
        // the user's, so close the transition gate before touching
        // `isCollapsed`. This replaces an ordering dependency that was
        // invisible in the diff: the old code relied on `layoutMode = mode`
        // being assigned *after* the mutation for the mode guard in
        // `splitViewDidResize` to suppress it, and it is assigned before.
        // The guard therefore protected split -> source and split ->
        // preview but stood wide open on entry into split — the one path
        // that matters. AppKit uncollapses the preview at its 280pt
        // `minimumThickness`, the resize notification fires, and that
        // geometry was persisted as the user's fraction; the
        // `applyPersistedSplitFraction` call below then faithfully
        // re-applied the value it had just destroyed. For the reporter's
        // 1101pt window with the outline collapsed and a `.paneSplitter`
        // divider (~9pt): (1101 - 9 - 280) / (1101 - 9) = 0.7436, and
        // ~0.743 is what was found persisted on that machine. The bug's
        // fixed point is the preview pinned at its minimum, which is
        // exactly the "split proportion is not retained" report.
        splitFraction.beginTransition()

        switch mode {
        case .source:
            previewItem.isCollapsed = true
            editorItem.isCollapsed = false
        case .preview:
            editorItem.isCollapsed = true
            previewItem.isCollapsed = false
        case .split:
            editorItem.isCollapsed = false
            previewItem.isCollapsed = false
        }

        if let window, let before = frameBeforeSwitch, window.frame.size != before.size {
            window.setFrame(before, display: true)
        }
        // Both panes were just uncollapsed at their remembered (full-width)
        // thicknesses; put the divider back at the user's fraction so the
        // restored frame doesn't leave one pane pinned to its minimum.
        if mode == .split {
            applyPersistedSplitFraction()
        }

        updateToolbarSelection(for: mode)
        alignRevealedPane(from: previous, to: mode)
    }

    /// One-shot cross-pane alignment when a layout switch reveals a
    /// previously hidden pane. Continuous scroll sync only runs in
    /// `.split`, so without this the revealed pane would show wherever
    /// it was last left. A single alignment event can't ping-pong, and
    /// aligning at switch time is indistinguishable from the old
    /// "hidden pane follows every scroll" behavior — just without the
    /// per-wheel-tick cost.
    private func alignRevealedPane(from previous: LayoutMode, to mode: LayoutMode) {
        switch (previous, mode) {
        case (.source, .preview), (.source, .split):
            let position = editor.currentScrollPosition()
            preview.scrollToSourceLine(position.topLine, fallbackRatio: position.ratio)
        case (.preview, .source), (.preview, .split):
            preview.currentTopSourceLine { [weak self] line in
                guard let self, let line else { return }
                self.editor.scrollToSourceLine(line)
            }
        default:
            // Same mode, or split → single pane: the surviving pane
            // already holds the user's position.
            break
        }
    }

    private func updateToolbarSelection(for mode: LayoutMode) {
        guard let toolbar = window?.toolbar,
              let item = toolbar.items.first(where: { $0.itemIdentifier == layoutItemIdentifier }),
              let segmented = item.view as? NSSegmentedControl else { return }
        segmented.selectedSegment = mode == .source ? 0 : mode == .split ? 1 : 2
    }
}

extension DocumentWindowController: @MainActor EditorViewControllerDelegate {
    func editor(_ controller: EditorViewController, didChangeText newText: String) {
        let overall = LatencyProbe.enabled ? CFAbsoluteTimeGetCurrent() : 0

        // Cheap, immediate path: forward the source to the document
        // (debounced renderer schedule lives there) and refresh the
        // byte count. Both are O(1)-ish so cheap enough to stay sync
        // on every keystroke. Line count and word count are now
        // deferred because both are O(N) and visibly stall typing
        // on large documents.
        writDocument?.applyEditorText(newText)
        statusBar.update(byteCount: newText.utf8.count, lineCount: nil, wordCount: nil, status: nil)

        // Debounced path: word count + line count + outline rebuild
        // run after a typing pause so they don't add O(N) work to
        // every keystroke. Cancel + reschedule on each edit so only
        // the last burst's compute fires.
        let outlineVisible = !outlineSplitItem.isCollapsed
        deferredCountsTask?.cancel()
        deferredCountsTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            guard let self else { return }
            let t0 = LatencyProbe.enabled ? CFAbsoluteTimeGetCurrent() : 0
            let lineCount = newText.lineCountWrit
            if LatencyProbe.enabled {
                let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                LatencyProbe.log.info("  deferred lineCount \(ms, format: .fixed(precision: 2))ms")
            }
            let t1 = LatencyProbe.enabled ? CFAbsoluteTimeGetCurrent() : 0
            let words = newText.utf8.count < 1_000_000 ? DocumentSnapshot.wordCount(in: newText) : nil
            if LatencyProbe.enabled {
                let ms = (CFAbsoluteTimeGetCurrent() - t1) * 1000
                LatencyProbe.log.info("  deferred wordCount \(ms, format: .fixed(precision: 2))ms")
            }
            self.statusBar.update(byteCount: newText.utf8.count, lineCount: lineCount, wordCount: words, status: nil)
            if outlineVisible {
                let t2 = LatencyProbe.enabled ? CFAbsoluteTimeGetCurrent() : 0
                self.outline.update(with: newText)
                if LatencyProbe.enabled {
                    let ms = (CFAbsoluteTimeGetCurrent() - t2) * 1000
                    LatencyProbe.log.info("  deferred outline.update \(ms, format: .fixed(precision: 2))ms")
                }
            }
        }

        if LatencyProbe.enabled {
            let ms = (CFAbsoluteTimeGetCurrent() - overall) * 1000
            LatencyProbe.log.info("editor(didChangeText:) sync \(ms, format: .fixed(precision: 2))ms")
        }
    }

    func editor(_ controller: EditorViewController, didChangeSelectionTo location: (line: Int, column: Int)) {
        statusBar.setSelection(line: location.line, column: location.column)
    }

    func editor(_ controller: EditorViewController, didScrollToRatio ratio: Double, topSourceLine: Int) {
        // Continuous editor → preview sync only matters when both panes
        // are visible; in source-only mode it would just burn a JS
        // evaluation in the hidden WKWebView per wheel tick. A mode
        // switch realigns the revealed pane once (see setLayout).
        guard layoutMode == .split else { return }
        preview.scrollToSourceLine(topSourceLine, fallbackRatio: ratio)
    }
}

private extension String {
    var lineCountWrit: Int {
        if isEmpty { return 0 }
        var count = 1
        for scalar in unicodeScalars where scalar == "\n" { count += 1 }
        return count
    }
}
