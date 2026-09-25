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

    // MARK: - What the fill looks like, not just where its strokes are

    private let ellipse = CGRect(x: 150, y: 200, width: 330, height: 250)

    /// A closed ellipse in one pen stroke: every row of its inside has a
    /// different width, so the fill can't merge rows into thick bands.
    private func ellipseDrawing() -> PKDrawing {
        let points = (0...180).map { step -> PKStrokePoint in
            let t = CGFloat(step) / 180 * 2 * .pi
            return PKStrokePoint(location: CGPoint(x: ellipse.midX + ellipse.width / 2 * cos(t),
                                                   y: ellipse.midY + ellipse.height / 2 * sin(t)),
                                 timeOffset: Double(step) * 0.01, size: CGSize(width: 3, height: 3),
                                 opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black),
                                            path: PKStrokePath(controlPoints: points, creationDate: Date()))])
    }

    /// RGBA pixels of `drawing` rendered at 1x over the page, light mode.
    private func pixels(of drawing: PKDrawing) -> [UInt8] {
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: CGRect(origin: .zero, size: page), scale: 1)
        }
        let width = Int(page.width), height = Int(page.height)
        var px = [UInt8](repeating: 0, count: width * height * 4)
        px.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image!.cgImage!, in: CGRect(origin: .zero, size: page))
        }
        return px
    }

    private func isInside(_ x: Int, _ y: Int, _ rect: CGRect) -> Bool {
        let dx = (CGFloat(x) + 0.5 - rect.midX) / (rect.width / 2)
        let dy = (CGFloat(y) + 0.5 - rect.midY) / (rect.height / 2)
        return dx * dx + dy * dy <= 1
    }

    /// Field report, Sept 25, 2026: a tap inside an ellipse drew a few
    /// yellow lines across its middle and nothing else. PencilKit draws
    /// nothing for a stroke under ~2pt, and one-row bands were 0.75pt.
    func testFillInsideAnEllipse_coversItsInside_andNothingOutside() async throws {
        let drawing = ellipseDrawing()
        let result = await FillTool.fill(drawing, in: page, at: CGPoint(x: ellipse.midX, y: ellipse.midY + 40),
                                         color: UIColor(red: 1, green: 0, blue: 0, alpha: 1))
        let px = pixels(of: try XCTUnwrap(result))
        let width = Int(page.width)
        func isFill(_ x: Int, _ y: Int) -> Bool {
            let i = (y * width + x) * 4
            return px[i + 3] > 200 && px[i] > 200 && px[i + 1] < 60 && px[i + 2] < 60
        }

        let inner = ellipse.insetBy(dx: 4, dy: 4), outer = ellipse.insetBy(dx: -4, dy: -4)
        var insideTotal = 0, insideFilled = 0, outsideFilled = 0
        for y in 0..<Int(page.height) {
            for x in 0..<width {
                if isInside(x, y, inner) {
                    insideTotal += 1
                    if isFill(x, y) { insideFilled += 1 }
                } else if !isInside(x, y, outer), isFill(x, y) {
                    outsideFilled += 1
                }
            }
        }
        XCTAssertGreaterThan(Double(insideFilled) / Double(insideTotal), 0.99,
                             "\(insideFilled) of \(insideTotal) inside pixels filled")
        XCTAssertEqual(outsideFilled, 0, "fill escaped the ellipse")
    }

    /// Once filled, the region is ink: a second tap in it fills nothing.
    /// Before, the fill's strokes were invisible to the next fill too, and
    /// every tap stacked another few hundred of them on the page.
    func testSecondTapInAFilledRegion_isRejected() async throws {
        let point = CGPoint(x: ellipse.midX, y: ellipse.midY + 80)
        let first = await FillTool.fill(ellipseDrawing(), in: page, at: point, color: .red)
        let second = await FillTool.fill(try XCTUnwrap(first), in: page, at: point, color: .red)
        XCTAssertNil(second)
    }
}
