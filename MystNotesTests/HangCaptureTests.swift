import XCTest
@testable import Mystnotes

/// The main-thread watchdog's stack capture: while the main thread is
/// stuck, another thread can obtain its frames. Without this, a launch
/// hang reported "(none)" and nothing could say where it was.
final class HangCaptureTests: XCTestCase {
    func testMainThreadStack_isCapturedWhileItIsBlocked() {
        XCTAssertTrue(Thread.isMainThread)
        MainThreadWatchdog.start()   // idempotent; the host app may have started it

        let captured = expectation(description: "stack captured")
        nonisolated(unsafe) var stack: String?
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            stack = MainThreadWatchdog.captureMainThreadStack()
            captured.fulfill()
        }
        // Block main the way a stuck coordinated read would.
        deliberatelyBlockMainThread(seconds: 1.0)

        wait(for: [captured], timeout: 3)
        let frames = try? XCTUnwrap(stack)
        XCTAssertNotNil(frames, "no stack came back")
        XCTAssertTrue(frames?.contains("deliberatelyBlockMainThread") == true,
                      "the captured stack should show the blocking frame:\n\(frames ?? "")")
    }

    @inline(never)
    private func deliberatelyBlockMainThread(seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }
}
