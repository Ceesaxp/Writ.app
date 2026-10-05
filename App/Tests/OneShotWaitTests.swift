import XCTest

/// `OneShotWait` is the latch the PDF-export path uses to wait for the
/// preview's JS bridge and its first render without waiting forever.
///
/// It replaces a single monotonic token shared by every wait, which retired
/// an outstanding wait *without calling its completion* as soon as a second
/// wait was armed: the first export then never wrote its file and never
/// reported a failure, and the chained hook closure it had installed was
/// never restored, leaking the whole document graph (document, window
/// controller, text storage, WKWebView, WebContent process) for the lifetime
/// of the app. Each wait owning its own one-shot identity is what makes
/// "fires exactly once, for exactly this wait" true.
final class OneShotWaitTests: XCTestCase {
    func testFiresCompletionExactlyOnceOnSignal() {
        var outcomes: [Bool] = []
        let fired = expectation(description: "completion runs")
        let latch = OneShotWait(timeout: 5) { ok in
            outcomes.append(ok)
            fired.fulfill()
        }

        latch.signal()
        latch.signal()
        latch.signal()

        wait(for: [fired], timeout: 1)
        XCTAssertEqual(
            outcomes, [true],
            "a signalled wait must report success exactly once no matter how many times it is "
                + "signalled — a second report would hand the export pipeline two completions"
        )
        XCTAssertTrue(latch.hasFired, "hasFired must be observable after the completion ran")
    }

    func testFiresFalseAtTheDeadlineWhenNeverSignalled() {
        var outcomes: [Bool] = []
        let fired = expectation(description: "completion runs at the deadline")
        _ = OneShotWait(timeout: 0.1) { ok in
            outcomes.append(ok)
            fired.fulfill()
        }

        wait(for: [fired], timeout: 2)
        XCTAssertEqual(
            outcomes, [false],
            "an unsignalled wait must report failure at its deadline; silently dropping it is what "
                + "made an export vanish with neither a file nor an error"
        )
    }

    func testIgnoresASignalThatArrivesAfterTheDeadline() {
        var outcomes: [Bool] = []
        let fired = expectation(description: "completion runs at the deadline")
        let latch = OneShotWait(timeout: 0.05) { ok in
            outcomes.append(ok)
            fired.fulfill()
        }

        wait(for: [fired], timeout: 2)
        latch.signal()

        XCTAssertEqual(
            outcomes, [false],
            "the condition arriving after the wait already timed out must not produce a second "
                + "report — the export it belonged to has already been failed"
        )
    }

    func testTwoIndependentWaitsDoNotInterfere() {
        var first: [Bool] = []
        var second: [Bool] = []
        let firstFired = expectation(description: "first wait completes")
        let secondFired = expectation(description: "second wait completes")

        let latchA = OneShotWait(timeout: 5) { ok in
            first.append(ok)
            firstFired.fulfill()
        }
        let latchB = OneShotWait(timeout: 5) { ok in
            second.append(ok)
            secondFired.fulfill()
        }

        latchA.signal()
        wait(for: [firstFired], timeout: 1)
        XCTAssertEqual(first, [true], "signalling the first wait must complete the first wait")
        XCTAssertEqual(
            second, [],
            "arming or completing one wait must not retire another: two overlapping exports each "
                + "need their own answer"
        )
        XCTAssertFalse(latchB.hasFired, "the second wait must still be pending")

        latchB.signal()
        wait(for: [secondFired], timeout: 1)
        XCTAssertEqual(second, [true], "the second wait must still be able to complete on its own signal")
        XCTAssertEqual(first, [true], "completing the second wait must not re-report the first")
    }

    func testDoesNotRetainItsCompletionAfterFiring() {
        final class Probe {}
        var probe: Probe? = Probe()
        weak let weakProbe = probe
        let fired = expectation(description: "completion runs")

        let latch = OneShotWait(timeout: 5) { [probe] _ in
            _ = probe
            fired.fulfill()
        }
        probe = nil

        latch.signal()
        wait(for: [fired], timeout: 1)

        XCTAssertNil(
            weakProbe,
            "a fired wait must release its completion closure; holding it is how the stranded export "
                + "wait kept the whole document graph alive until the app quit"
        )
    }
}

/// `OneShotWaitGroup` is how the preview keeps the waits for one condition
/// (the JS bridge coming up, the first render landing) without hijacking a
/// single-slot callback hook.
final class OneShotWaitGroupTests: XCTestCase {
    func testSignalsEveryWaitArmedForTheCondition() {
        var outcomes: [String] = []
        let both = expectation(description: "both waits complete")
        both.expectedFulfillmentCount = 2
        var group = OneShotWaitGroup()
        group.arm(timeout: 5) { ok in
            outcomes.append("first:\(ok)")
            both.fulfill()
        }
        group.arm(timeout: 5) { ok in
            outcomes.append("second:\(ok)")
            both.fulfill()
        }

        group.takePending().forEach { $0.signal() }

        wait(for: [both], timeout: 1)
        XCTAssertEqual(
            outcomes, ["first:true", "second:true"],
            "two exports waiting on the same condition must both be told it happened"
        )
    }

    func testTakePendingEmptiesTheGroupSoASecondSignalReportsNothingTwice() {
        var outcomes: [Bool] = []
        let fired = expectation(description: "wait completes")
        var group = OneShotWaitGroup()
        group.arm(timeout: 5) { ok in
            outcomes.append(ok)
            fired.fulfill()
        }

        group.takePending().forEach { $0.signal() }
        group.takePending().forEach { $0.signal() }

        wait(for: [fired], timeout: 1)
        XCTAssertEqual(outcomes, [true], "a condition firing twice must not report an export twice")
    }

    func testArmingPrunesWaitsThatAlreadyFinished() {
        var group = OneShotWaitGroup()
        let first = expectation(description: "first wait completes")
        group.arm(timeout: 0.05) { _ in first.fulfill() }
        wait(for: [first], timeout: 2)

        let second = expectation(description: "second wait completes")
        group.arm(timeout: 5) { _ in second.fulfill() }

        let pending = group.takePending()
        XCTAssertEqual(
            pending.count, 1,
            "a wait that already timed out must be pruned when the next one is armed, rather than "
                + "accumulating in the group for the lifetime of the document"
        )
        pending.forEach { $0.signal() }
        wait(for: [second], timeout: 1)
    }
}
