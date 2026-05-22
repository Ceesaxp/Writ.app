import Cocoa
import UniformTypeIdentifiers

/// Tool-panel-style folder browser shown by File ▸ Open Folder…
///
/// `NSPanel` with the utility style mask gives a thinner titlebar
/// and lets the window float over document windows (Photoshop-
/// palette feel). The contents are an `NSOutlineView` showing the
/// folder tree recursively — directories collapse/expand with
/// disclosure triangles, double-click on a file opens it as a
/// `WritDocument`, search filters and auto-expands ancestors of
/// matches.
///
/// The flat `NSTableView` this replaced was fine for shallow
/// folders but turned into soup as soon as a folder had real
/// nested structure.
@MainActor
final class FolderWindowController: NSWindowController, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    private let folder: URL
    /// Full tree as last enumerated. Always present; `filteredRoot`
    /// is either this or a pruned copy when the search box has text.
    private var root: FolderNode
    private var filteredRoot: FolderNode
    private let searchField = NSSearchField()
    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
    private let modColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("modified"))

    /// Off-main enumeration task. Cancelled when the window closes
    /// so large or network-backed folders don't keep walking.
    private var loadTask: Task<Void, Never>?
    /// FSEvents watcher; rebuilds the tree on external changes.
    private var watcher: FolderWatcher?
    /// Coalesces watcher fires so a burst of writes triggers one
    /// reload, not one per file.
    private var reloadDebounce: DispatchWorkItem?

    /// Set of file URLs (string-keyed) the user has expanded.
    /// Saved before every reload and re-applied after the tree
    /// rebuilds so external changes don't collapse the user's
    /// view. URLs survive across rebuilds; `FolderNode` instances
    /// do not.
    private var expandedURLs: Set<String> = []

    /// Snapshot of expansion state taken when search starts, so
    /// we can restore it when search clears.
    private var preSearchExpandedURLs: Set<String>?

    init(folder: URL) {
        self.folder = folder
        // Seed with an empty root; the async load will replace it.
        let empty = FolderNode(url: folder, isDirectory: true, name: folder.lastPathComponent, modificationDate: nil)
        self.root = empty
        self.filteredRoot = empty

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = folder.lastPathComponent
        panel.minSize = NSSize(width: 220, height: 360)
        // Float above document windows when this app is active —
        // matches Photoshop tool palettes / Xcode utility panels.
        panel.isFloatingPanel = true
        // We want the panel to take focus when clicked so keyboard
        // navigation (arrows, return, the search field) works.
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false

        super.init(window: panel)
        panel.delegate = self
        installContent()
        loadFiles()
        startWatching()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    private func installContent() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true

        searchField.placeholderString = "Filter…"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.controlSize = .small
        searchField.font = NSFont.systemFont(ofSize: 11)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = outlineView

        // Outline view setup. `.automatic` row style gives a
        // standard list look; sourceList would add vibrancy + the
        // floating section headers we don't have, which would
        // look wrong for a flat folder tree.
        outlineView.headerView = nil
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        outlineView.indentationPerLevel = 14
        outlineView.indentationMarkerFollowsCell = true
        outlineView.intercellSpacing = NSSize(width: 0, height: 2)
        outlineView.rowSizeStyle = .small
        outlineView.usesAutomaticRowHeights = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(rowDoubleClicked(_:))
        outlineView.autoresizesOutlineColumn = false

        nameColumn.title = "Name"
        nameColumn.minWidth = 120
        nameColumn.resizingMask = [.userResizingMask, .autoresizingMask]
        outlineView.addTableColumn(nameColumn)
        outlineView.outlineTableColumn = nameColumn

        modColumn.title = "Modified"
        modColumn.minWidth = 60
        modColumn.maxWidth = 110
        modColumn.width = 80
        modColumn.resizingMask = [.userResizingMask]
        outlineView.addTableColumn(modColumn)

        contentView.addSubview(searchField)
        contentView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            searchField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6),
            searchField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    // MARK: - Tree loading + FSEvents

    private func startWatching() {
        watcher = FolderWatcher(folder: folder) { [weak self] in
            DispatchQueue.main.async { self?.scheduleReload() }
        }
    }

    private func scheduleReload() {
        reloadDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.loadFiles() }
        reloadDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func loadFiles() {
        loadTask?.cancel()
        let folder = self.folder
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            if Task.isCancelled { return }
            let tree = FolderTreeBuilder.build(at: folder)
            if Task.isCancelled { return }
            await self?.installTree(tree)
        }
    }

    @MainActor
    private func installTree(_ tree: FolderNode) {
        // Capture the user's expansion state before we swap the
        // tree out. We key by URL string because FolderNode
        // identities are about to change — the new tree's nodes
        // are fresh objects, so pointer-based expansion state on
        // the outline view would all be lost without this hop.
        captureExpansionState()
        root = tree
        applyFilter() // reloadData + apply state in one shot
    }

    private func captureExpansionState() {
        var expanded: Set<String> = []
        var stack: [FolderNode] = filteredRoot.children
        while let node = stack.popLast() {
            if outlineView.isItemExpanded(node) {
                expanded.insert(node.url.absoluteString)
            }
            if node.isDirectory { stack.append(contentsOf: node.children) }
        }
        expandedURLs = expanded
    }

    /// Re-expand every directory whose URL is in `expandedURLs`.
    /// `node` is the implicit (off-screen) root; we iterate its
    /// children — they're the top-level outline rows — and recurse.
    /// `expandItem` needs the parent already expanded before its
    /// children can be expanded; the recursive order here satisfies
    /// that.
    private func walkExpand(_ node: FolderNode) {
        guard node.isDirectory else { return }
        for child in node.children where child.isDirectory {
            if expandedURLs.contains(child.url.absoluteString) {
                outlineView.expandItem(child)
            }
            walkExpand(child)
        }
    }

    // MARK: - Search

    /// Apply the current search-field text to the tree. Empty
    /// query → original tree; otherwise a pruned copy with all
    /// ancestors of matches retained. Auto-expands everything in
    /// the filtered tree so hits are visible at depth.
    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            filteredRoot = root
            // Restore the pre-search expansion state if we have
            // one stashed — the user just cleared the search.
            if let saved = preSearchExpandedURLs {
                expandedURLs = saved
                preSearchExpandedURLs = nil
            }
            outlineView.reloadData()
            walkExpand(filteredRoot)
            return
        }
        // Entering search: remember the user's current expansion
        // so we can put it back when they clear the field.
        if preSearchExpandedURLs == nil {
            captureExpansionState()
            preSearchExpandedURLs = expandedURLs
        }
        filteredRoot = FolderTreeBuilder.filter(root, query: query) ?? FolderNode(
            url: folder, isDirectory: true, name: folder.lastPathComponent, modificationDate: nil
        )
        outlineView.reloadData()
        // While filtering, expand every directory in the filtered
        // tree so the user can see every match at a glance.
        expandAll(filteredRoot)
    }

    private func expandAll(_ node: FolderNode) {
        guard node.isDirectory else { return }
        outlineView.expandItem(node)
        for child in node.children { expandAll(child) }
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        let node = (item as? FolderNode) ?? filteredRoot
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let node = (item as? FolderNode) ?? filteredRoot
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? FolderNode else { return false }
        return node.isDirectory && !node.children.isEmpty
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FolderNode, let column = tableColumn else { return nil }

        if column === nameColumn {
            return makeNameCell(for: node)
        }
        if column === modColumn {
            return makeModifiedCell(for: node)
        }
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { 20 }

    private func makeNameCell(for node: FolderNode) -> NSView {
        let cellID = NSUserInterfaceItemIdentifier("nameCell")
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = cellID
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.imageScaling = .scaleProportionallyDown
            cell.addSubview(icon)
            cell.imageView = icon
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.font = NSFont.systemFont(ofSize: 12)
            text.lineBreakMode = .byTruncatingMiddle
            text.maximumNumberOfLines = 1
            cell.addSubview(text)
            cell.textField = text
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 0),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        cell.imageView?.image = NSWorkspace.shared.icon(forFile: node.url.path)
        cell.textField?.stringValue = node.name
        cell.textField?.textColor = node.isDirectory ? .labelColor : .labelColor
        return cell
    }

    private func makeModifiedCell(for node: FolderNode) -> NSView {
        let cellID = NSUserInterfaceItemIdentifier("modCell")
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = cellID
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.alignment = .right
            text.font = NSFont.systemFont(ofSize: 10)
            text.textColor = .secondaryLabelColor
            text.lineBreakMode = .byClipping
            cell.addSubview(text)
            cell.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        cell.textField?.stringValue = Self.relativeDateString(node.modificationDate)
        return cell
    }

    /// Compact "modified" string. Tuned for a narrow column:
    ///   - Today  → "HH:MM"
    ///   - This year → "MMM d"
    ///   - Older  → "MMM d, yyyy"
    private static func relativeDateString(_ date: Date?) -> String {
        guard let date else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            let f = DateFormatter()
            f.dateStyle = .none
            f.timeStyle = .short
            return f.string(from: date)
        }
        let f = DateFormatter()
        if cal.isDate(date, equalTo: Date(), toGranularity: .year) {
            f.dateFormat = "MMM d"
        } else {
            f.dateFormat = "MMM d, yyyy"
        }
        return f.string(from: date)
    }

    // MARK: - Open + window lifecycle

    @objc private func rowDoubleClicked(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FolderNode else { return }
        if node.isDirectory {
            // Toggle expansion on directories — matches Finder.
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
            return
        }
        openFile(node.url)
    }

    private func openFile(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { doc, _, error in
            if let error {
                let alert = NSAlert(error: error)
                alert.runModal()
                return
            }
            if doc != nil {
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        loadTask?.cancel()
        loadTask = nil
        reloadDebounce?.cancel()
        reloadDebounce = nil
        watcher?.stop()
        watcher = nil
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // ⏎ in the search field opens the top hit — the same
        // "quick open" behaviour the flat list used to have.
        guard let movement = obj.userInfo?["NSTextMovement"] as? Int,
              movement == NSTextMovement.return.rawValue else { return }
        if let first = firstFile(in: filteredRoot) {
            openFile(first.url)
        }
    }

    private func firstFile(in node: FolderNode) -> FolderNode? {
        if !node.isDirectory { return node }
        for child in node.children {
            if let hit = firstFile(in: child) { return hit }
        }
        return nil
    }
}
