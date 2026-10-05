import XCTest

/// Regression cover for the macOS 27 PDF-export crash: AppKit runs
/// `WKWebView`'s `NSPrintOperation` on a spawned secondary thread, so the
/// `didRun:` selector — and therefore everything `PrintCompletionHandler`
/// forwards to — fired off the main thread. The teardown path calls
/// main-thread-only WebKit API, and WebKit deliberately kills the process
/// (`crashDueToApplicationCallingMainThreadOnlyWebKitAPIFromBackgroundThread`).
/// The hop belongs at this single boundary.
final class PrintCompletionHandlerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PrintCompletionHandlerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    func testForwardsCompletionOnMainThreadWhenInvokedFromBackgroundThread() throws {
        let target = try makeNonEmptyFile()
        let finished = expectation(description: "completion closure is called")
        var ranOnMainThread: Bool?
        var reportedURL: URL?
        var reportedSuccess: Bool?

        // The handler is not Sendable; handing it to a global queue is exactly
        // what AppKit's print machinery does, which is the case under test.
        nonisolated(unsafe) let handler = makeHandler(target: target) { url, success in
            ranOnMainThread = Thread.isMainThread
            reportedURL = url
            reportedSuccess = success
            finished.fulfill()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            handler.complete(success: true)
        }

        wait(for: [finished], timeout: 5)

        XCTAssertEqual(
            ranOnMainThread, true,
            "PrintCompletionHandler must deliver its completion on the main thread even when AppKit "
                + "invokes it from a print-operation worker thread; the downstream teardown calls "
                + "main-thread-only WKWebView API and WebKit kills the process when it is called off-main."
        )
        XCTAssertEqual(reportedURL, target, "completion should report the target it was constructed with")
        XCTAssertEqual(reportedSuccess, true, "a successful run over a non-empty file should report success")
    }

    func testForwardsCompletionOnMainThreadWhenInvokedFromMainThread() throws {
        XCTAssertTrue(Thread.isMainThread, "precondition: XCTest runs the test body on the main thread")
        let target = try makeNonEmptyFile()
        let finished = expectation(description: "completion closure is called")
        var ranOnMainThread: Bool?

        let handler = makeHandler(target: target) { _, _ in
            ranOnMainThread = Thread.isMainThread
            finished.fulfill()
        }

        handler.complete(success: true)

        wait(for: [finished], timeout: 5)

        XCTAssertEqual(
            ranOnMainThread, true,
            "the completion must still arrive, on the main thread, when complete(success:) is already "
                + "called from the main thread — the hop is unconditional so callback timing stays uniform."
        )
    }

    // MARK: - Helpers

    private func makeHandler(
        target: URL,
        completion: @escaping (URL, Bool) -> Void
    ) -> PrintCompletionHandler {
        let heartbeat = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        heartbeat.setEventHandler {}
        heartbeat.activate()
        addTeardownBlock { heartbeat.cancel() }
        return PrintCompletionHandler(
            target: target,
            runStart: Date(),
            heartbeat: heartbeat,
            completion: completion
        )
    }

    /// The handler forwards AppKit's verdict unchanged — whether the output
    /// is usable is decided once, downstream — but the fixture is still a
    /// real, non-empty file so the test exercises a plausible target.
    private func makeNonEmptyFile() throws -> URL {
        let url = temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString).pdf")
        try Data("%PDF-1.4 stand-in for an exported document".utf8).write(to: url)
        let size = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
            "fixture file should report a size"
        )
        XCTAssertGreaterThan(size, 0, "fixture file must be non-empty to pass the handler's success guard")
        return url
    }
}
