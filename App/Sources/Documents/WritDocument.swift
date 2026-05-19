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
    /// the change-counted state aligned with edits.
    private(set) var sourceText: String = ""

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

    // MARK: - File IO

    override func read(from url: URL, ofType typeName: String) throws {
        let data = try Data(contentsOf: url)
        try read(from: data, ofType: typeName)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError, userInfo: [
                NSLocalizedFailureReasonErrorKey: "File is not valid UTF-8 or Latin-1."
            ])
        }
        sourceText = text
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.windowControllers.compactMap { $0 as? DocumentWindowController }.forEach { $0.applyLoadedSource() }
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        Data(sourceText.utf8)
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
        guard let window = windowControllers.first?.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.html]
        panel.nameFieldStringValue = (displayName as NSString?)?.deletingPathExtension ?? "export"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let document = self.bridge.currentParsedDocument
            ExportService.exportHTML(parsed: document, theme: self.bridge.theme, to: url)
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
            controller.preview.exportPDF(to: url)
        }
    }
}
