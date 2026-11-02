import XCTest
import UIKit
import PencilKit
@testable import Mystnotes

/// "A pen input is required before another touch input is allowed" (found
/// while swiping the page sidebar). The host's observer recognizers ignore
/// every new touch while one is tracked, so a tracked touch whose end never
/// arrived locked touch input out. UITouch can't be constructed in a test, so
/// these cover the pieces that don't need one: the staleness rule, reset, and
/// the embed-time cancel.
final class TouchRecoveryTests: XCTestCase {

    func testStalenessRule() {
        XCTAssertTrue(ShapeHoldRecognizer.isStale(phase: .ended, hasWindow: true))
        XCTAssertTrue(ShapeHoldRecognizer.isStale(phase: .cancelled, hasWindow: true))
        XCTAssertTrue(ShapeHoldRecognizer.isStale(phase: .moved, hasWindow: false))
        XCTAssertFalse(ShapeHoldRecognizer.isStale(phase: .moved, hasWindow: true))
        XCTAssertFalse(ShapeHoldRecognizer.isStale(phase: .began, hasWindow: true))
    }

    func testFreshRecognizersTrackNothing() {
        XCTAssertFalse(ShapeHoldRecognizer().hasTrackedTouch)
        XCTAssertFalse(InkLassoRecognizer().hasTrackedTouch)
        XCTAssertFalse(MultiFingerTapRecognizer(requiredTouches: 2, target: nil, action: nil).hasTrackedTouch)
    }

    func testResetAndClearAreSafeAndIdempotent() {
        let hold = ShapeHoldRecognizer()
        hold.reset()
        hold.clearTrackedState()
        XCTAssertFalse(hold.hasTrackedTouch)

        let lasso = InkLassoRecognizer()
        lasso.reset()
        lasso.clearTrackedState()
        XCTAssertFalse(lasso.hasTrackedTouch)

        let tap = MultiFingerTapRecognizer(requiredTouches: 3, target: nil, action: nil)
        tap.reset()
        tap.clearTrackedState()
        XCTAssertFalse(tap.hasTrackedTouch)
        XCTAssertEqual(tap.state, .possible)
    }

    func testEmbeddingANewCanvasLeavesRecognizersIdleAndEnabled() {
        let host = CanvasHostView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let hold = ShapeHoldRecognizer()
        host.addGestureRecognizer(hold)
        let first = PKCanvasView()
        let second = PKCanvasView()
        host.embed(first)
        host.embed(second)
        XCTAssertTrue(second.superview === host)
        XCTAssertNil(first.superview)
        XCTAssertTrue(first.drawingGestureRecognizer.isEnabled)
        XCTAssertTrue(hold.isEnabled)
        XCTAssertFalse(hold.hasTrackedTouch)
    }
}
