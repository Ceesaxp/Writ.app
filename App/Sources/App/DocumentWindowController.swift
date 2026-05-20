import Cocoa
import os
import WritCore

private let dwcLog = Logger(subsystem: "org.ceesaxp.Writ", category: "window")

/// Owns the window, the split-view layout, and the wiring between editor,
/// preview, and the document. One controller per document window.
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    enum LayoutMode: String { case source, preview, split }

    let editor: EditorViewController
    let preview: PreviewViewController
    let statusBar: StatusBarViewController
    let outline: OutlineSidebarController
    private let splitController: NSSplitViewController
    private let containerController: NSViewController
    private var outlineSplitItem: NSSplitViewItem!
    private(set) var layoutMode: LayoutMode = .split

    private let toolbarIdentifier = NSToolbar.Identifier("WritToolbar")
    private let layoutItemIdentifier = NSToolbarItem.Identifier("WritLayoutMode")

    private weak var writDocument: WritDocument?

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
        split.autosaveName = "WritEditorPreviewSplit"

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

        let previewItem = NSSplitViewItem(viewController: preview)
        previewItem.minimumThickness = 280
        previewItem.holdingPriority = .defaultLow

        splitController.addSplitViewItem(outlineItem)
        splitController.addSplitViewItem(editorItem)
        splitController.addSplitViewItem(previewItem)

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

        editor.delegate = self
        document.bridge.attach(preview: preview, statusBar: statusBar)
        let docDir = document.fileURL?.deletingLastPathComponent()
        preview.documentDirectory = docDir
        document.bridge.documentDirectory = docDir
        preview.onPreviewScrolled = { [weak self] line in
            self?.editor.scrollToSourceLine(line)
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
        let doc = writDocument
        Task { @MainActor in doc?.bridge.cancelAll() }
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        applyLoadedSource()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // Force a balanced initial editor/preview split. If the user
        // later drags the divider, NSSplitView's autosave records it;
        // we only intervene when the current ratio looks like a
        // default-imbalanced layout (editor < 35% of the editing area).
        //
        // Indices after the outline sidebar was prepended:
        //   0 = outline (sidebar, often collapsed)
        //   1 = editor
        //   2 = preview
        // Divider 0 sits between outline/editor; divider 1 sits between
        // editor/preview. We want to balance editor↔preview, so probe
        // item 1's width against (editor + preview) width and move
        // divider 1.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.splitController.splitView.layoutSubtreeIfNeeded()
            let split = self.splitController.splitView
            let editorItem = self.splitController.splitViewItems[1]
            let previewItem = self.splitController.splitViewItems[2]
            let editorWidth = editorItem.viewController.view.bounds.width
            let previewWidth = previewItem.viewController.view.bounds.width
            let editingAreaWidth = editorWidth + previewWidth
            guard editingAreaWidth > 0 else { return }
            let ratio = editorWidth / editingAreaWidth
            if ratio < 0.35 || ratio > 0.65 {
                // Divider 1's position is measured from the split view's
                // leading edge, so we anchor at the outline's trailing
                // edge plus half the editing area.
                let outlineWidth = self.splitController.splitViewItems[0].viewController.view.bounds.width
                let dividerOffset = outlineWidth + editingAreaWidth * 0.5
                split.setPosition(dividerOffset, ofDividerAt: 1)
            }
            _ = split // silence unused if the early-return path is taken
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
        segmented.selectedSegment = 1
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
        layoutMode = mode
        // Indices after the outline sidebar was prepended: 0 = outline,
        // 1 = editor, 2 = preview. The Source/Split/Preview switcher only
        // touches editor and preview; the outline visibility is independent.
        let editorItem = splitController.splitViewItems[1]
        let previewItem = splitController.splitViewItems[2]
        switch mode {
        case .source:
            editorItem.isCollapsed = false
            previewItem.isCollapsed = true
        case .preview:
            editorItem.isCollapsed = true
            previewItem.isCollapsed = false
        case .split:
            editorItem.isCollapsed = false
            previewItem.isCollapsed = false
        }
        updateToolbarSelection(for: mode)
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
        writDocument?.applyEditorText(newText)
        let words = newText.utf8.count < 1_000_000 ? DocumentSnapshot.wordCount(in: newText) : nil
        statusBar.update(byteCount: newText.utf8.count, lineCount: newText.lineCountWrit, wordCount: words, status: nil)
        // Only rebuild the outline when it's actually visible — saves a
        // full AST walk per keystroke on long documents.
        if !outlineSplitItem.isCollapsed {
            outline.update(with: newText)
        }
    }

    func editor(_ controller: EditorViewController, didChangeSelectionTo location: (line: Int, column: Int)) {
        statusBar.setSelection(line: location.line, column: location.column)
    }

    func editor(_ controller: EditorViewController, didScrollToRatio ratio: Double, topSourceLine: Int) {
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
