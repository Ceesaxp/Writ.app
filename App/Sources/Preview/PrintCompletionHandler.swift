import AppKit
import Foundation
import os

/// File-private mirror of `PreviewViewController`'s logger. Kept identical in
/// subsystem/category so PDF-export lines stay in one stream, while this file
/// depends on nothing else in the app target.
private let previewLog = Logger(subsystem: "org.ceesaxp.Writ", category: "preview")

/// NSObject target used by `NSPrintOperation.runModal(for:delegate:didRun:contextInfo:)`.
/// AppKit calls back via a fixed @objc selector when the print job finishes;
/// we forward that into a Swift closure so the calling view controller can
/// finish in idiomatic Swift.
final class PrintCompletionHandler: NSObject {
    private let target: URL
    private let runStart: Date
    private let heartbeat: DispatchSourceTimer
    private let completion: (URL, Bool) -> Void

    init(target: URL, runStart: Date, heartbeat: DispatchSourceTimer, completion: @escaping (URL, Bool) -> Void) {
        self.target = target
        self.runStart = runStart
        self.heartbeat = heartbeat
        self.completion = completion
        super.init()
    }

    @objc func printOperationDidRun(_ printOperation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        complete(success: success)
    }

    /// Selector-free core of the callback, so the completion plumbing is
    /// testable without driving a real `NSPrintOperation`.
    func complete(success: Bool) {
        let exists = FileManager.default.fileExists(atPath: target.path)
        let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? 0
        previewLog.notice("[pdf] printOperationDidRun: success=\(success), exists=\(exists), size=\(size)")
        completion(target, success && exists && size > 0)
    }
}
