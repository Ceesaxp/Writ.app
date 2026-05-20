import Cocoa
import UniformTypeIdentifiers

/// Simple "folder window" — File > Open Folder...
///
/// A standalone window showing every Markdown / plain-text file in a chosen
/// directory (recursive, lightweight). Double-clicking a row opens that file
/// as a regular `WritDocument` window. A search field at the top filters the
/// list incrementally — that doubles as the M3 "quick open" surface.
///
/// Deliberately scoped to MVP simplicity:
///   - one folder per window
///   - flat list (with the relative path shown so nested files are
///     distinguishable)
///   - no proprietary project metadata, no backlinks, no sync
///   - the folder window itself is not document-based; closing it doesn't
///     close any open document windows
@MainActor
final class FolderWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let folder: URL
    private var allFiles: [URL] = []
    private var filteredFiles: [URL] = []
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    /// Off-main enumeration task. Cancelled when the window closes so
    /// large or network-backed folders don't keep walking the tree.
    private var loadTask: Task<Void, Never>?

    init(folder: URL) {
        self.folder = folder
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = folder.lastPathComponent
        window.minSize = NSSize(width: 280, height: 320)
        super.init(window: window)
        window.delegate = self
        installContent()
        loadFiles()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    private func installContent() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true

        searchField.placeholderString = "Filter files…"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = tableView

        tableView.headerView = nil
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked(_:))
        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .plain
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.rowSizeStyle = .default
        tableView.usesAlternatingRowBackgroundColors = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.title = "File"
        column.minWidth = 200
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        contentView.addSubview(searchField)
        contentView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    private func loadFiles() {
        loadTask?.cancel()
        let folder = self.folder
        // Enumeration runs off-main so large or network-backed folders
        // don't freeze the window. Results are streamed back in batches
        // for snappy first paint; cancellation is honoured between
        // batches and between individual entries.
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let exts: Set<String> = ["md", "markdown", "mdown", "txt"]
            var batch: [URL] = []
            var accumulated: [URL] = []
            guard let enumerator = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey, .nameKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                await self?.handleLoadResult([])
                return
            }
            // Manual iteration: NSEnumerator's for-in adapter is
            // unavailable from async contexts under Swift 6 strict
            // concurrency. `nextObject()` is the supported path.
            while true {
                if Task.isCancelled { return }
                guard let next = enumerator.nextObject() else { break }
                guard let url = next as? URL else { continue }
                guard let isRegular = try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
                      isRegular else { continue }
                if exts.contains(url.pathExtension.lowercased()) {
                    batch.append(url)
                    accumulated.append(url)
                    if batch.count >= 200 {
                        let toFlush = batch
                        batch.removeAll(keepingCapacity: true)
                        await self?.appendDiscoveredFiles(toFlush)
                    }
                }
            }
            if Task.isCancelled { return }
            if !batch.isEmpty {
                await self?.appendDiscoveredFiles(batch)
            }
            await self?.handleLoadResult(accumulated.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending })
        }
    }

    /// Streamed batch from the off-main enumerator. Keeps the list
    /// unsorted between batches so the user sees results immediately;
    /// `handleLoadResult` does a final sort at the end.
    private func appendDiscoveredFiles(_ batch: [URL]) {
        allFiles.append(contentsOf: batch)
        applyFilter()
    }

    /// Final settle: replace with the sorted view so the list isn't
    /// stuck in enumeration order.
    private func handleLoadResult(_ sorted: [URL]) {
        allFiles = sorted
        applyFilter()
    }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            filteredFiles = allFiles
        } else {
            let lower = query.lowercased()
            filteredFiles = allFiles.filter { url in
                relativeName(url).lowercased().contains(lower)
            }
        }
        tableView.reloadData()
    }

    private func relativeName(_ url: URL) -> String {
        let folderPath = folder.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        if filePath.hasPrefix(folderPath + "/") {
            return String(filePath.dropFirst(folderPath.count + 1))
        }
        return url.lastPathComponent
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { filteredFiles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cellID = NSUserInterfaceItemIdentifier("FolderFileCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = cellID
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingMiddle
            text.font = NSFont.systemFont(ofSize: 13)
            cell.addSubview(text)
            cell.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        let url = filteredFiles[row]
        cell.textField?.stringValue = relativeName(url)
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 22 }

    @objc private func rowDoubleClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0 && row < filteredFiles.count else { return }
        openFile(filteredFiles[row])
    }

    private func openFile(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        loadTask?.cancel()
        loadTask = nil
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Pressing Return in the search field opens the top hit — that's the
        // quick-open behaviour.
        guard let textMovement = obj.userInfo?["NSTextMovement"] as? Int,
              textMovement == NSTextMovement.return.rawValue,
              !filteredFiles.isEmpty else { return }
        openFile(filteredFiles[0])
    }
}
