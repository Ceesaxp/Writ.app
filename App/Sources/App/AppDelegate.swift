import Cocoa

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    // In --bench mode, refuse to open the extra argv paths as documents.
    // AppKit otherwise interprets `--bench <fixtures> <results.json>` as
    // "open these three files", spawning modal error sheets that block
    // the bench runner's WKWebView shell load.
    private var inBenchMode: Bool {
        CommandLine.arguments.contains("--bench")
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        if inBenchMode { return true } // swallow silently
        return false // let the default document controller handle it
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if inBenchMode {
            sender.reply(toOpenOrPrint: .success)
            return
        }
        // Route each through NSDocumentController. The
        // documented behavior is that `openDocument(withContentsOf:...)`
        // calls `noteNewRecentDocumentURL` on success, but in practice
        // the recents store stays empty for our sandboxed app — so we
        // add the URL explicitly as well. The call is idempotent
        // against AppKit's own recording.
        for path in filenames {
            let url = URL(fileURLWithPath: path)
            NSDocumentController.shared.openDocument(
                withContentsOf: url,
                display: true
            ) { document, _, error in
                if error == nil && document != nil {
                    NSDocumentController.shared.noteNewRecentDocumentURL(url)
                }
            }
        }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if inBenchMode {
            BenchmarkMode.run()
            return
        }
        // Handle CLI flags for quick QA: --enable-line-numbers / --disable-line-numbers
        // toggle the persisted preference before any document window is shown.
        if CommandLine.arguments.contains("--enable-line-numbers") {
            UserDefaults.standard.set(true, forKey: EditorViewController.lineNumbersDefaultsKey)
        } else if CommandLine.arguments.contains("--disable-line-numbers") {
            UserDefaults.standard.set(false, forKey: EditorViewController.lineNumbersDefaultsKey)
        }
        AppMenu.install()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        NSDocumentController.shared.newDocument(nil)
        return true
    }

    private var folderWindowControllers: [FolderWindowController] = []

    private var preferencesController: PreferencesWindowController?

    @MainActor @objc func showPreferences(_ sender: Any?) {
        if preferencesController == nil {
            preferencesController = PreferencesWindowController()
        }
        preferencesController?.showWindow(nil)
        preferencesController?.window?.makeKeyAndOrderFront(nil)
    }

    @MainActor @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to browse for Markdown files."
        panel.prompt = "Open"
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        let controller = FolderWindowController(folder: url)
        folderWindowControllers.append(controller)
        controller.showWindow(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
