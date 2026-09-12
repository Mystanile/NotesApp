import XCTest
@testable import Mystnotes

/// M0 task 12: the automatic push fires once, a fixed interval after the
/// *last* change, and backgrounding doesn't wait for it.
@MainActor
final class SyncDebouncerTests: XCTestCase {
    func testChangesCoalesce_intoOneActionAfterTheLastOne() async throws {
        var fired = 0
        let debouncer = SyncDebouncer(interval: 0.2) { fired += 1 }

        debouncer.noteChange()
        try await Task.sleep(nanoseconds: 100_000_000)
        debouncer.noteChange()            // restarts the wait
        try await Task.sleep(nanoseconds: 100_000_000)
        debouncer.noteChange()
        XCTAssertEqual(fired, 0, "nothing fires while edits keep coming")
        XCTAssertTrue(debouncer.isPending)

        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(fired, 1, "exactly one push after the last edit")
        XCTAssertFalse(debouncer.isPending)
    }

    func testFlush_actsImmediately_andOnlyWhenSomethingWasPending() async throws {
        var fired = 0
        let debouncer = SyncDebouncer(interval: 10) { fired += 1 }

        debouncer.flush()
        XCTAssertEqual(fired, 0, "nothing pending, nothing to do")

        debouncer.noteChange()
        debouncer.flush()
        XCTAssertEqual(fired, 1)
        XCTAssertFalse(debouncer.isPending)

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(fired, 1, "the flushed wait must not fire again later")
    }

    func testCancel_dropsThePendingAction() async throws {
        var fired = 0
        let debouncer = SyncDebouncer(interval: 0.1) { fired += 1 }
        debouncer.noteChange()
        debouncer.cancel()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(fired, 0)
    }
}
