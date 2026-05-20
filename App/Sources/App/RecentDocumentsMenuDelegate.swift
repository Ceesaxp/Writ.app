import Cocoa

/// Repopulates the File > Open Recent submenu from
/// `NSDocumentController.shared.recentDocumentURLs` every time the menu
/// is about to open. AppKit's "auto-detect the Open Recent submenu by
/// looking for a Clear Menu item" mechanism is unreliable for
/// programmatically-built menus, so we drive the population ourselves.
///
/// The delegate keeps a single retained instance attached to the
/// submenu via `setDelegate(_:)`. AppMenu owns the instance for the
/// lifetime of the app.
@MainActor
final class RecentDocumentsMenuDelegate: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        // Rebuild the menu in place. We could be more surgical, but
        // the recents list is short (<=10 by default) and the work
        // here is dominated by menu-item layout, not allocation.
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs
        if urls.isEmpty {
            let none = NSMenuItem(title: "No Recent Documents", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for url in urls {
                let item = NSMenuItem(
                    title: url.lastPathComponent,
                    action: #selector(openRecent(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.toolTip = url.path
                item.representedObject = url
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(
            title: "Clear Menu",
            action: #selector(NSDocumentController.clearRecentDocuments(_:)),
            keyEquivalent: ""
        )
        clear.target = NSDocumentController.shared
        menu.addItem(clear)
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSDocumentController.shared.openDocument(
            withContentsOf: url,
            display: true
        ) { _, _, error in
            if let error {
                let alert = NSAlert(error: error)
                alert.runModal()
                // If the file is gone, drop it from recents so the
                // menu doesn't keep offering a broken entry.
                NSDocumentController.shared.recentDocumentURLs
                    .filter { $0 == url }
                    .forEach { _ in /* no-op; AppKit cleans on next open */ }
            }
        }
    }
}
