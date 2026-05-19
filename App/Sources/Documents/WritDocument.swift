import Cocoa
import UniformTypeIdentifiers
import WritCore
import WritParser
import WritRender

/// Document-based macOS document for plain-text Markdown.
///
/// Owns the canonical source string. Hands the editor and preview controllers
/// fresh snapshots through ``DocumentSnapshot``. All preview/render work is
/// brokered by ``PreviewBridge``, which connects the scheduler's output to the
/// preview view controller on the main thread.
final class WritDocument: NSDocument {
    /// Canonical source text. UI mutates through `applyEditorText(_:)` to keep
    /// the change-counted state aligned with edits. Marked `nonisolated(unsafe)`
    /// because NSDocument's `readFromData:ofType:error:` is declared
    /// `NS_SWIFT_NONISOLATED` and writes to this on the loader thread; AppKit
    /// serializes load/save with main-thread use, so concurrent mutation is
    /// impossible by construction.
    nonisolated(unsafe) private(set) var sourceText: String = ""

    private(set) lazy var bridge: PreviewBridge = {
        let parser = WritParserFactory.make()
        return PreviewBridge(parser: parser)
    }()

    override init() {
        super.init()
        hasUndoManager = true
    }

    override class var autosavesInPlace: Bool { true }

    override class var autosavesDrafts: Bool { true }

    override func makeWindowControllers() {
        let controller = DocumentWindowController(document: self)
        addWindowController(controller)
    }

    // MARK: - External file change detection (M3)

    /// `NSDocument` already implements `NSFilePresenter` and registers with
    /// `NSFileCoordinator` when it has a file URL. The OS notifies us via
    /// `presentedItemDidChange()` whenever another process writes to the
    /// file. Default behavior is to do nothing visible; we override to
    /// surface the change to the user and offer to revert.
    override func presentedItemDidChange() {
        // Hops onto main because file-presenter callbacks come in on the
        // file coordinator's queue.
        DispatchQueue.main.async { [weak self] in
            self?.handleExternalChange()
        }
    }

    private var externalChangePromptActive = false

    private func handleExternalChange() {
        guard let url = fileURL, !externalChangePromptActive else { return }
        // Skip if we have unsaved local edits — we don't want to silently
        // clobber the user's work. The MVP behavior is conservative: prompt
        // and let the user choose.
        let isDirty = isDocumentEdited
        externalChangePromptActive = true
        let alert = NSAlert()
        alert.messageText = "“\(url.lastPathComponent)” was changed by another application."
        if isDirty {
            alert.informativeText = "You have unsaved changes. Reload from disk and lose your edits, or keep your version?"
            alert.addButton(withTitle: "Reload from Disk")
            alert.addButton(withTitle: "Keep My Changes")
        } else {
            alert.informativeText = "Would you like to reload the file?"
            alert.addButton(withTitle: "Reload")
            alert.addButton(withTitle: "Ignore")
        }
        alert.alertStyle = .informational

        if let window = windowControllers.first?.window {
            alert.beginSheetModal(for: window) { [weak self] response in
                defer { self?.externalChangePromptActive = false }
                guard response == .alertFirstButtonReturn else { return }
                self?.reloadFromDisk()
            }
        } else {
            let response = alert.runModal()
            externalChangePromptActive = false
            if response == .alertFirstButtonReturn { reloadFromDisk() }
        }
    }

    private func reloadFromDisk() {
        guard let url = fileURL else { return }
        do {
            try revert(toContentsOf: url, ofType: fileType ?? "public.plain-text")
            windowControllers
                .compactMap { $0 as? DocumentWindowController }
                .forEach { $0.applyLoadedSource() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not reload “\(url.lastPathComponent)”."
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: - File IO

    override func read(from url: URL, ofType typeName: String) throws {
        let data = try Data(contentsOf: url)
        try read(from: data, ofType: typeName)
    }

    nonisolated(unsafe) private var loadedEncoding: String.Encoding = .utf8
    nonisolated(unsafe) private var hadBOM = false

    override func read(from data: Data, ofType typeName: String) throws {
        let decoded = TextDecoder.decode(data)
        sourceText = decoded.text
        loadedEncoding = decoded.encoding
        hadBOM = decoded.hadBOM
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.windowControllers
                .compactMap { $0 as? DocumentWindowController }
                .forEach { $0.applyLoadedSource() }
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        // Always write UTF-8. Preserve a BOM if the input file had one — some
        // Windows-side editors expect it. Files that originally arrived as
        // CP1252 / Latin-1 are upgraded to UTF-8 on save so the canonical
        // format is consistent going forward.
        TextDecoder.encode(sourceText, encoding: .utf8, addBOM: hadBOM)
    }

    override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? {
        switch typeName.lowercased() {
        case "public.plain-text", "public.text": return "txt"
        default: return "md"
        }
    }

    // MARK: - Edit application

    /// Called by the editor when the user has changed text. We do not produce a
    /// diff here — the editor passes the full string. The preview pipeline is
    /// snapshot-driven, so this is cheap.
    func applyEditorText(_ newText: String) {
        if newText == sourceText { return }
        let oldText = sourceText
        sourceText = newText
        updateChangeCount(.changeDone)
        if let undo = undoManager {
            undo.registerUndo(withTarget: self) { [oldText] doc in
                doc.applyEditorText(oldText)
                doc.windowControllers
                    .compactMap { $0 as? DocumentWindowController }
                    .forEach { $0.editor.reloadSource() }
            }
        }
        bridge.scheduleUpdate(source: newText)
    }

    // MARK: - Export commands (wired to menu)

    @IBAction func exportHTML(_ sender: Any?) {
        guard let window = windowControllers.first?.window,
              let controller = windowControllers.first as? DocumentWindowController else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.html]
        panel.nameFieldStringValue = (displayName as NSString?)?.deletingPathExtension ?? "export"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            ExportService.exportHTML(
                preview: controller.preview,
                parsed: self.bridge.currentParsedDocument,
                theme: self.bridge.theme,
                to: url
            )
        }
    }

    @IBAction func exportPDF(_ sender: Any?) {
        guard let window = windowControllers.first?.window,
              let controller = windowControllers.first as? DocumentWindowController else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.pdf]
        panel.nameFieldStringValue = (displayName as NSString?)?.deletingPathExtension ?? "export"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            controller.statusBar.setExportStatus("Exporting PDF…")
            controller.preview.onExportFinished = { [weak controller] finishedURL, ok in
                guard let controller else { return }
                if ok {
                    controller.statusBar.setExportStatus("Exported \(finishedURL.lastPathComponent)")
                } else {
                    controller.statusBar.setExportStatus("PDF export failed")
                }
                // Clear the status message after a few seconds.
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak controller] in
                    controller?.statusBar.setExportStatus(nil)
                }
            }
            controller.preview.exportPDF(to: url)
        }
    }
}
