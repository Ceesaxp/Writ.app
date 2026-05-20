import Cocoa
import WritCore

/// Owns the window, the split-view layout, and the wiring between editor,
/// preview, and the document. One controller per document window.
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    enum LayoutMode: String { case source, preview, split }

    let editor: EditorViewController
    let preview: PreviewViewController
    let statusBar: StatusBarViewController
    private let splitController: NSSplitViewController
    private let containerController: NSViewController
    private(set) var layoutMode: LayoutMode = .split

    private let toolbarIdentifier = NSToolbar.Identifier("WritToolbar")
    private let layoutItemIdentifier = NSToolbarItem.Identifier("WritLayoutMode")

    private weak var writDocument: WritDocument?

    init(document: WritDocument) {
        self.writDocument = document
        self.editor = EditorViewController()
        self.preview = PreviewViewController()
        self.statusBar = StatusBarViewController()
        self.splitController = NSSplitViewController()

        let split = splitController.splitView
        // .paneSplitter is the chunky-with-handle style; gives users a
        // clear visible target to grab instead of the 1-pt .thin divider.
        split.dividerStyle = .paneSplitter
        split.isVertical = true
        split.autosaveName = "WritEditorPreviewSplit"

        let editorItem = NSSplitViewItem(viewController: editor)
        editorItem.minimumThickness = 280
        // Equal holding priorities → the split resizes both sides
        // proportionally as the window grows / shrinks. The earlier
        // imbalanced setup caused the editor to compress before the
        // preview when window state was restored from autosave.
        editorItem.holdingPriority = .defaultLow

        let previewItem = NSSplitViewItem(viewController: preview)
        previewItem.minimumThickness = 280
        previewItem.holdingPriority = .defaultLow

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
        // Force a balanced initial split. If the user later drags the
        // divider, NSSplitView's autosave records it; we only intervene
        // when the current ratio looks like a default-imbalanced layout
        // (editor < 35% of the editing area).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.splitController.splitView.layoutSubtreeIfNeeded()
            let split = self.splitController.splitView
            let total = split.bounds.width - split.dividerThickness
            guard total > 0 else { return }
            let editorWidth = self.splitController.splitViewItems[0].viewController.view.bounds.width
            let ratio = editorWidth / total
            if ratio < 0.35 || ratio > 0.65 {
                split.setPosition(total * 0.5, ofDividerAt: 0)
            }
        }
    }

    func applyLoadedSource() {
        guard let doc = writDocument else { return }
        editor.setSource(doc.sourceText)
        statusBar.update(
            byteCount: doc.sourceText.utf8.count,
            lineCount: doc.sourceText.lineCountWrit,
            wordCount: DocumentSnapshot.wordCount(in: doc.sourceText),
            status: .idle
        )
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

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleLineNumbers(_:)) {
            item.state = EditorViewController.lineNumbersEnabled ? .on : .off
            return true
        }
        return true
    }

    private func setLayout(_ mode: LayoutMode) {
        layoutMode = mode
        let editorItem = splitController.splitViewItems[0]
        let previewItem = splitController.splitViewItems[1]
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
        // Word count is linear in document size; skip for very large docs where
        // it would chase typing. Use a coarse 1 MB threshold matching the
        // large-document mode.
        let words = newText.utf8.count < 1_000_000 ? DocumentSnapshot.wordCount(in: newText) : nil
        statusBar.update(byteCount: newText.utf8.count, lineCount: newText.lineCountWrit, wordCount: words, status: nil)
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
