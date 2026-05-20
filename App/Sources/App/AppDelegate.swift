import Cocoa
import os

private let launchLog = Logger(subsystem: "org.ceesaxp.Writ", category: "launch")

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

    // Single-file open hook. Implemented (instead of openFiles:) so we
    // don't have to call sender.reply(toOpenOrPrint:) — that reply,
    // sent synchronously while NSDocumentController.openDocument is
    // still in-flight, was racing with the WKWebView shell load on
    // cold launch and leaving the preview pane blank.
    //
    // Non-bench: route the file through NSDocumentController and
    // return true so AppKit considers it handled. Recent-doc
    // recording happens in WritDocument.read(from:).
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        if inBenchMode { return true } // swallow bench args silently
        let url = URL(fileURLWithPath: filename)
        launchLog.notice("openFile: \(filename, privacy: .public)")
        NSDocumentController.shared.openDocument(
            withContentsOf: url,
            display: true
        ) { doc, _, error in
            if let error {
                launchLog.error("openDocument failed: \(error.localizedDescription, privacy: .public)")
            } else {
                launchLog.notice("openDocument completed: \(doc?.fileURL?.path ?? "no fileURL", privacy: .public)")
            }
        }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchLog.notice("applicationDidFinishLaunching, bench=\(self.inBenchMode)")
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
