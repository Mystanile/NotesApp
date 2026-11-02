import XCTest
import PencilKit
@testable import Mystnotes

/// The Zoom Window's arithmetic: pad to page mapping, the size floor, and
/// where the target goes after a stroke. All pure; the pad itself needs a
/// finger or a Pencil and is checked on the iPad.
final class ZoomWindowTests: XCTestCase {

    private let page = CGSize(width: 780, height: 1040)
    private let pad = CGSize(width: 700, height: 150)

    // MARK: - Geometry

    func testTargetSize_isPadOverMagnification() {
        let size = ZoomWindowMath.targetSize(padSize: pad, magnification: 2.5)
        XCTAssertEqual(size.width, 280, accuracy: 0.001)
        XCTAssertEqual(size.height, 60, accuracy: 0.001)
        XCTAssertEqual(ZoomWindowMath.targetSize(padSize: .zero, magnification: 2.5), .zero)
    }

    func testMagnification_isClamped() {
        XCTAssertEqual(ZoomWindowMath.clampMagnification(0.5), 1.5)
        XCTAssertEqual(ZoomWindowMath.clampMagnification(9), 4)
        XCTAssertEqual(ZoomWindowMath.clampMagnification(.nan), ZoomWindowMath.defaultMagnification)
    }

    func testPadPoint_mapsToPage() {
        let p = ZoomWindowMath.pagePoint(fromPad: CGPoint(x: 250, y: 100), magnification: 2.5,
                                         targetOrigin: CGPoint(x: 40, y: 200))
        XCTAssertEqual(p.x, 140, accuracy: 0.001)
        XCTAssertEqual(p.y, 240, accuracy: 0.001)
    }

    func testPadCorners_mapToTargetCorners() {
        let origin = CGPoint(x: 100, y: 300)
        let rect = CGRect(origin: origin, size: ZoomWindowMath.targetSize(padSize: pad, magnification: 2.5))
        let far = ZoomWindowMath.pagePoint(fromPad: CGPoint(x: pad.width, y: pad.height),
                                           magnification: 2.5, targetOrigin: origin)
        XCTAssertEqual(far.x, rect.maxX, accuracy: 0.001)
        XCTAssertEqual(far.y, rect.maxY, accuracy: 0.001)
    }

    func testClamp_keepsTargetOnPage() {
        let size = CGSize(width: 280, height: 60)
        XCTAssertEqual(ZoomWindowMath.clamp(CGPoint(x: -50, y: -9), targetSize: size, pageSize: page), .zero)
        let far = ZoomWindowMath.clamp(CGPoint(x: 5000, y: 5000), targetSize: size, pageSize: page)
        XCTAssertEqual(far.x, 500)
        XCTAssertEqual(far.y, 980)
    }

    // MARK: - Size floor

    func testStrokeSize_isShrunkByMagnification() {
        let s = ZoomWindowMath.pageStrokeSize(fromPad: CGSize(width: 10, height: 10), magnification: 2.5)
        XCTAssertEqual(s.width, 4, accuracy: 0.001)
        XCTAssertEqual(s.height, 4, accuracy: 0.001)
    }

    func testStrokeSize_neverUnderTheVisibleFloor() {
        let s = ZoomWindowMath.pageStrokeSize(fromPad: CGSize(width: 2, height: 3), magnification: 4)
        XCTAssertEqual(s.width, ZoomWindowMath.minimumPageStrokeSize)
        XCTAssertEqual(s.height, ZoomWindowMath.minimumPageStrokeSize)
    }

    func testStrokeSize_followsTransformScale() {
        let s = ZoomWindowMath.pageStrokeSize(fromPad: CGSize(width: 10, height: 10), magnification: 2, inkScale: 2)
        XCTAssertEqual(s.width, 10, accuracy: 0.001)
    }

    // MARK: - Auto-advance

    func testShouldAdvance_onlyInTheRightFifteenPercent() {
        let target = CGRect(x: 100, y: 100, width: 200, height: 60)
        XCTAssertFalse(ZoomWindowMath.shouldAdvance(strokeEnd: CGPoint(x: 269, y: 120), target: target))
        XCTAssertTrue(ZoomWindowMath.shouldAdvance(strokeEnd: CGPoint(x: 270, y: 120), target: target))
        XCTAssertTrue(ZoomWindowMath.shouldAdvance(strokeEnd: CGPoint(x: 299, y: 120), target: target))
    }

    func testAdvance_slidesRightBySeventyPercent() {
        let target = CGRect(x: 24, y: 100, width: 200, height: 60)
        let next = ZoomWindowMath.advancedOrigin(of: target, pageSize: page)
        XCTAssertEqual(next.x, 164, accuracy: 0.001)
        XCTAssertEqual(next.y, 100, accuracy: 0.001)
    }

    func testAdvance_lastSlideStopsAtTheRightMargin() {
        // Right-most origin is 780 - 24 - 200 = 556.
        let target = CGRect(x: 500, y: 100, width: 200, height: 60)
        let next = ZoomWindowMath.advancedOrigin(of: target, pageSize: page)
        XCTAssertEqual(next.x, 556, accuracy: 0.001)
        XCTAssertEqual(next.y, 100, accuracy: 0.001)
    }

    func testAdvance_wrapsToTheLeftMarginOneLineDown() {
        let target = CGRect(x: 556, y: 100, width: 200, height: 60)
        let next = ZoomWindowMath.advancedOrigin(of: target, pageSize: page)
        XCTAssertEqual(next.x, ZoomWindowMath.pageMargin, accuracy: 0.001)
        XCTAssertEqual(next.y, 160, accuracy: 0.001)
    }

    func testAdvance_clampsAtThePageBottom() {
        let target = CGRect(x: 556, y: 980, width: 200, height: 60)
        let next = ZoomWindowMath.advancedOrigin(of: target, pageSize: page)
        XCTAssertEqual(next.x, ZoomWindowMath.pageMargin, accuracy: 0.001)
        XCTAssertEqual(next.y, 980, accuracy: 0.001)
    }

    func testAdvance_targetWiderThanThePage_goesToANewLine() {
        let target = CGRect(x: 0, y: 0, width: 760, height: 60)
        let next = ZoomWindowMath.advancedOrigin(of: target, pageSize: page)
        XCTAssertEqual(next.y, 60, accuracy: 0.001)
        XCTAssertTrue(next.x >= 0 && next.x + 760 <= 780)
    }

    func testNewLine_goesToTheLeftMarginOneTargetHeightDown() {
        let next = ZoomWindowMath.newLineOrigin(of: CGRect(x: 300, y: 200, width: 200, height: 60), pageSize: page)
        XCTAssertEqual(next, CGPoint(x: 24, y: 260))
    }

    func testStepBack_slidesLeftThenUpALine() {
        let slide = ZoomWindowMath.steppedBackOrigin(of: CGRect(x: 300, y: 200, width: 200, height: 60), pageSize: page)
        XCTAssertEqual(slide.x, 160, accuracy: 0.001)
        XCTAssertEqual(slide.y, 200, accuracy: 0.001)

        let clampedToMargin = ZoomWindowMath.steppedBackOrigin(of: CGRect(x: 100, y: 200, width: 200, height: 60), pageSize: page)
        XCTAssertEqual(clampedToMargin.x, ZoomWindowMath.pageMargin, accuracy: 0.001)

        let up = ZoomWindowMath.steppedBackOrigin(of: CGRect(x: 24, y: 200, width: 200, height: 60), pageSize: page)
        XCTAssertEqual(up.x, 556, accuracy: 0.001)
        XCTAssertEqual(up.y, 140, accuracy: 0.001)

        let top = CGRect(x: 24, y: 0, width: 200, height: 60)
        XCTAssertEqual(ZoomWindowMath.steppedBackOrigin(of: top, pageSize: page), top.origin)
    }

    // MARK: - Forwarding

    private func padStroke(seed: UInt32 = 7, date: Date = Date(timeIntervalSinceReferenceDate: 1000)) -> PKStroke {
        let points = (0..<4).map { i in
            PKStrokePoint(location: CGPoint(x: 100 + CGFloat(i) * 50, y: 50), timeOffset: Double(i) * 0.01,
                          size: CGSize(width: 8, height: 8), opacity: 1, force: 0.5, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black),
                        path: PKStrokePath(controlPoints: points, creationDate: date), randomSeed: seed)
    }

    func testForward_mapsLocationsAndSizes_andKeepsTheInk() throws {
        let result = try XCTUnwrap(ZoomWindowMath.forward([padStroke()], into: PKDrawing(), magnification: 2.5,
                                                         targetOrigin: CGPoint(x: 40, y: 200)))
        let stroke = try XCTUnwrap(result.drawing.strokes.first)
        let first = try XCTUnwrap(stroke.path.first)
        XCTAssertEqual(first.location.x, 80, accuracy: 0.001)
        XCTAssertEqual(first.location.y, 220, accuracy: 0.001)
        XCTAssertEqual(first.size.width, 3.2, accuracy: 0.001)
        XCTAssertEqual(result.end.x, 40 + 250 / 2.5, accuracy: 0.001)
        XCTAssertEqual(stroke.ink.inkType, .pen)
        XCTAssertEqual(stroke.randomSeed, 7)
        XCTAssertTrue(stroke.transform.isIdentity)
    }

    func testForward_appendsAfterExistingInk() throws {
        let existing = PKDrawing(strokes: [padStroke(seed: 1, date: Date(timeIntervalSinceReferenceDate: 5))])
        let result = try XCTUnwrap(ZoomWindowMath.forward([padStroke()], into: existing, magnification: 2,
                                                         targetOrigin: .zero))
        XCTAssertEqual(result.drawing.strokes.count, 2)
        XCTAssertEqual(result.drawing.strokes[0].randomSeed, 1)
    }

    func testForward_keepsStrokeIdentityUnique() throws {
        let first = try XCTUnwrap(ZoomWindowMath.forward([padStroke()], into: PKDrawing(), magnification: 2,
                                                        targetOrigin: .zero))
        // The same creation date and seed again: the key must differ.
        let second = try XCTUnwrap(ZoomWindowMath.forward([padStroke()], into: first.drawing, magnification: 2,
                                                         targetOrigin: .zero))
        let keys = Set(second.drawing.strokes.map(ZoomWindowMath.strokeKey))
        XCTAssertEqual(keys.count, 2)
    }

    func testForward_nothingToForward_isNil() {
        XCTAssertNil(ZoomWindowMath.forward([], into: PKDrawing(), magnification: 2, targetOrigin: .zero))
    }
}
