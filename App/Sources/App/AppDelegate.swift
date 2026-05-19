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

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--bench") {
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
