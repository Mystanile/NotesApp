import XCTest
import PencilKit
@testable import Mystnotes

/// "Draw with finger": the drawing policy and the page-swipe flag follow
/// the setting on an iPad, and a Mac is unaffected.
@MainActor
final class FingerDrawingTests: XCTestCase {
    func testPolicy_iPad_off_isPencilOnly() {
        XCTAssertEqual(PKCanvasViewDrawingPolicy.policy(fingerDrawing: false, isMac: false), .pencilOnly)
    }

    func testPolicy_iPad_on_isAnyInput() {
        XCTAssertEqual(PKCanvasViewDrawingPolicy.policy(fingerDrawing: true, isMac: false), .anyInput)
    }

    func testPolicy_mac_isAnyInputEitherWay() {
        XCTAssertEqual(PKCanvasViewDrawingPolicy.policy(fingerDrawing: false, isMac: true), .anyInput)
        XCTAssertEqual(PKCanvasViewDrawingPolicy.policy(fingerDrawing: true, isMac: true), .anyInput)
    }

    func testPageSwipe_followsFingerDrawing() {
        XCTAssertTrue(PageSwipeInstaller.isEnabled(hasHandler: true, isMac: false, fingerDrawing: false))
        XCTAssertFalse(PageSwipeInstaller.isEnabled(hasHandler: true, isMac: false, fingerDrawing: true))
        XCTAssertFalse(PageSwipeInstaller.isEnabled(hasHandler: true, isMac: true, fingerDrawing: false))
        XCTAssertFalse(PageSwipeInstaller.isEnabled(hasHandler: false, isMac: false, fingerDrawing: false))
    }

    func testPanTouches_followFingerDrawing() {
        XCTAssertEqual(PagedCanvasHostView.panTouches(zoomedIn: true, isMac: false, fingerDrawing: false), 1)
        XCTAssertEqual(PagedCanvasHostView.panTouches(zoomedIn: true, isMac: false, fingerDrawing: true), 2,
                       "a finger that draws can't also pan")
        XCTAssertEqual(PagedCanvasHostView.panTouches(zoomedIn: false, isMac: false, fingerDrawing: false), 2)
        XCTAssertEqual(PagedCanvasHostView.panTouches(zoomedIn: true, isMac: true, fingerDrawing: false), 2)
    }

    /// The setting reaches the canvas as an input, not a global read.
    func testHostFingerDrawing_isAnInputThatUpdatesPanRequirement() {
        let host = PagedCanvasHostView()
        let canvas = PKCanvasView()
        host.embed(canvas)
        XCTAssertFalse(host.fingerDrawing)
        host.fingerDrawing = true
        XCTAssertEqual(canvas.panGestureRecognizer.minimumNumberOfTouches, 2)
        let wb = WhiteboardCanvasView(canvasView: .constant(canvas))
        XCTAssertFalse(wb.fingerDrawing, "defaulted off")
        XCTAssertFalse(PencilCanvasView(canvasView: .constant(canvas), pageSize: .zero, pageIdentity: nil,
                                        viewport: CanvasViewport()).fingerDrawing)
    }
}
