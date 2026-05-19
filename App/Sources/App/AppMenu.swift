import Cocoa

/// Programmatically built main menu — avoids storyboard/XIB resources so the
/// app can boot without Interface Builder artifacts.
@MainActor
enum AppMenu {
    static func install() {
        let main = NSMenu()

        // App menu (Writ)
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu(title: "Writ")
        appItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(title: "About Writ", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide Writ", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Writ", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        // File menu
        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        fileMenu.addItem(NSMenuItem(title: "New", action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n"))
        fileMenu.addItem(NSMenuItem(title: "Open…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        fileMenu.addItem(NSMenuItem(title: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "s"))
        let saveAs = NSMenuItem(title: "Save As…", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "S")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(saveAs)
        fileMenu.addItem(NSMenuItem(title: "Revert to Saved", action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: ""))
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "Export HTML…", action: #selector(WritDocument.exportHTML(_:)), keyEquivalent: "E"))
        fileMenu.addItem(NSMenuItem(title: "Export PDF…", action: #selector(WritDocument.exportPDF(_:)), keyEquivalent: "P"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "Print…", action: #selector(NSDocument.printDocument(_:)), keyEquivalent: "p"))

        // Edit menu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(.separator())
        let findMenuItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        let findSubmenu = NSMenu(title: "Find")
        findMenuItem.submenu = findSubmenu
        let find = NSMenuItem(title: "Find…", action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "f")
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        findSubmenu.addItem(find)
        let findNext = NSMenuItem(title: "Find Next", action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "g")
        findNext.tag = NSTextFinder.Action.nextMatch.rawValue
        findSubmenu.addItem(findNext)
        let findPrev = NSMenuItem(title: "Find Previous", action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "G")
        findPrev.keyEquivalentModifierMask = [.command, .shift]
        findPrev.tag = NSTextFinder.Action.previousMatch.rawValue
        findSubmenu.addItem(findPrev)
        let replace = NSMenuItem(title: "Replace…", action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "f")
        replace.keyEquivalentModifierMask = [.command, .option]
        replace.tag = NSTextFinder.Action.showReplaceInterface.rawValue
        findSubmenu.addItem(replace)
        editMenu.addItem(findMenuItem)

        // Insert menu
        let insertItem = NSMenuItem()
        main.addItem(insertItem)
        let insertMenu = NSMenu(title: "Insert")
        insertItem.submenu = insertMenu
        let insertCode = NSMenuItem(title: "Code Block", action: #selector(DocumentWindowController.insertCodeBlockMenu(_:)), keyEquivalent: "k")
        insertCode.keyEquivalentModifierMask = [.command, .option]
        insertMenu.addItem(insertCode)
        let insertMath = NSMenuItem(title: "Math Block", action: #selector(DocumentWindowController.insertMathBlockMenu(_:)), keyEquivalent: "m")
        insertMath.keyEquivalentModifierMask = [.command, .option]
        insertMenu.addItem(insertMath)
        let insertMermaid = NSMenuItem(title: "Mermaid Diagram", action: #selector(DocumentWindowController.insertMermaidBlockMenu(_:)), keyEquivalent: "d")
        insertMermaid.keyEquivalentModifierMask = [.command, .option]
        insertMenu.addItem(insertMermaid)

        // View menu
        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        let source = NSMenuItem(title: "Source Only", action: #selector(DocumentWindowController.showSourceOnly(_:)), keyEquivalent: "1")
        source.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(source)
        let preview = NSMenuItem(title: "Preview Only", action: #selector(DocumentWindowController.showPreviewOnly(_:)), keyEquivalent: "2")
        preview.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(preview)
        let split = NSMenuItem(title: "Source & Preview", action: #selector(DocumentWindowController.showSplit(_:)), keyEquivalent: "3")
        split.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(split)
        viewMenu.addItem(.separator())
        let refresh = NSMenuItem(title: "Refresh Preview", action: #selector(DocumentWindowController.refreshPreview(_:)), keyEquivalent: "r")
        viewMenu.addItem(refresh)

        // Window menu
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }
}
