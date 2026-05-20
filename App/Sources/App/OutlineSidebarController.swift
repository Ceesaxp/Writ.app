import Cocoa
import WritCore
import WritParser

/// Left-side outline sidebar that lists every heading in the current
/// document and lets the user click to jump.
///
/// The list is flat (a single `NSTableView`); we render the heading level
/// as a leading indent so nesting reads visually without the overhead of
/// `NSOutlineView` row-expansion state. The outline auto-rebuilds whenever
/// the document's parser pipeline produces a new `ParsedDocument`.
@MainActor
final class OutlineSidebarController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private var headings: [OutlineHeading] = []
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!

    var onSelectHeading: ((OutlineHeading) -> Void)?

    override func loadView() {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let table = NSTableView()
        table.headerView = nil
        table.allowsMultipleSelection = false
        table.style = .sourceList
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.rowSizeStyle = .default
        table.dataSource = self
        table.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("heading"))
        column.minWidth = 100
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        scroll.documentView = table

        host.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: host.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])

        self.scrollView = scroll
        self.tableView = table
        self.view = host
    }

    func update(with source: String) {
        headings = OutlineExtractor.extract(from: source)
        tableView.reloadData()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { headings.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cellID = NSUserInterfaceItemIdentifier("OutlineCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = cellID
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingTail
            cell.addSubview(text)
            cell.textField = text
            // Leading constraint is recreated per-row so indent can vary
            // with heading level.
            NSLayoutConstraint.activate([
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        let heading = headings[row]
        cell.textField?.stringValue = heading.title
        // Drop any prior leading constraint so the indent for this row is
        // applied fresh.
        cell.textField?.removeConstraints(cell.textField?.constraints.filter {
            ($0.firstAttribute == .leading || $0.secondAttribute == .leading)
        } ?? [])
        for constraint in cell.constraints where constraint.firstAnchor == cell.textField?.leadingAnchor {
            cell.removeConstraint(constraint)
        }
        let indent: CGFloat = CGFloat(max(0, heading.level - 1)) * 12 + 10
        cell.textField?.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: indent).isActive = true

        let font = NSFont.systemFont(ofSize: heading.level == 1 ? 13 : 12, weight: heading.level == 1 ? .semibold : .regular)
        cell.textField?.font = font
        cell.textField?.textColor = heading.level == 1 ? .labelColor : .secondaryLabelColor
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 22 }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0 && row < headings.count else { return }
        onSelectHeading?(headings[row])
    }
}
