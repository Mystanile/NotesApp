import XCTest
import PencilKit
@testable import Mystnotes

/// The flood fill on its own, with no view or tap in the way: a closed
/// square of pen ink on a page-sized canvas, filled from inside and from
/// outside. `Docs/TOOL_FIXES.md` Part 2.
final class FillToolTests: XCTestCase {

    private let page = CGSize(width: 600, height: 800)
    private let square = CGRect(x: 100, y: 100, width: 200, height: 200)

    /// A closed square as four straight pen strokes, sharp at the corners.
    private func squareDrawing() -> PKDrawing {
        let c = [CGPoint(x: square.minX, y: square.minY), CGPoint(x: square.maxX, y: square.minY),
                 CGPoint(x: square.maxX, y: square.maxY), CGPoint(x: square.minX, y: square.maxY)]
        let strokes = (0..<4).map { i -> PKStroke in
            let a = c[i], b = c[(i + 1) % 4]
            let points = (0...20).map { step -> PKStrokePoint in
                let t = CGFloat(step) / 20
                return PKStrokePoint(location: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t),
                                     timeOffset: Double(step) * 0.01, size: CGSize(width: 3, height: 3),
                                     opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: PKInk(.pen, color: .black),
                            path: PKStrokePath(controlPoints: points, creationDate: Date()))
        }
        return PKDrawing(strokes: strokes)
    }

    func testFillInsideASquare_staysInsideIt() async throws {
        let drawing = squareDrawing()
        let result = await FillTool.fill(drawing, in: page, at: CGPoint(x: 200, y: 200), color: .red)
        let filled = try XCTUnwrap(result)
        let added = filled.strokes.dropFirst(drawing.strokes.count)
        XCTAssertFalse(added.isEmpty)

        let fillBounds = added.map(\.renderBounds).reduce(CGRect.null) { $0.union($1) }
        XCTAssertTrue(square.insetBy(dx: -4, dy: -4).contains(fillBounds), "fill \(fillBounds) escaped \(square)")
        XCTAssertGreaterThan(fillBounds.width * fillBounds.height, square.width * square.height * 0.8,
                             "fill \(fillBounds) covers too little of \(square)")
    }

    func testFillOutsideTheSquare_leavesItsInsideEmpty() async throws {
        let drawing = squareDrawing()
        let result = await FillTool.fill(drawing, in: page, at: CGPoint(x: 450, y: 600), color: .red)
        let filled = try XCTUnwrap(result)
        let added = filled.strokes.dropFirst(drawing.strokes.count)
        let inner = square.insetBy(dx: 10, dy: 10)
        XCTAssertFalse(added.contains { $0.renderBounds.intersects(inner) }, "outside fill leaked into the square")
    }

    func testTapOnInk_isRejected() async {
        let result = await FillTool.fill(squareDrawing(), in: page, at: CGPoint(x: square.minX, y: 200), color: .red)
        XCTAssertNil(result)
    }
}
