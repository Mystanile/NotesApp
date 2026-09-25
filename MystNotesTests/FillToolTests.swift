import XCTest
import PencilKit
import SwiftUI
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
        let added = filled.strokes.prefix(filled.strokes.count - drawing.strokes.count)  // the fill goes under the ink
        XCTAssertFalse(added.isEmpty)

        let fillBounds = added.map(\.renderBounds).reduce(CGRect.null) { $0.union($1) }
        XCTAssertTrue(square.insetBy(dx: -4, dy: -4).contains(fillBounds), "fill \(fillBounds) escaped \(square)")
        XCTAssertGreaterThan(fillBounds.width * fillBounds.height, square.width * square.height * 0.8,
                             "fill \(fillBounds) covers too little of \(square)")
    }

    func testFillOutsideTheSquare_leavesItsInsideEmpty() async throws {
        let drawing = squareDrawing()
        let result = await FillTool.fill(drawing, in: page, at: CGPoint(x: 450, y: 600), color: UIColor(red: 1, green: 0, blue: 0, alpha: 1))
        let filled = try XCTUnwrap(result)
        // Pixels, not bounds: the fill is one zig-zag around the square,
        // so its bounds always contain it.
        let (px, width, _) = pixels(of: filled, scale: 2)
        let inner = square.insetBy(dx: 4, dy: 4)
        var leaked = 0
        for y in Int(inner.minY * 2)..<Int(inner.maxY * 2) {
            for x in Int(inner.minX * 2)..<Int(inner.maxX * 2) where px[(y * width + x) * 4 + 3] > 0 { leaked += 1 }
        }
        XCTAssertEqual(leaked, 0, "outside fill leaked into the square")
        XCTAssertTrue(isSolid(px, width, CGPoint(x: 450, y: 600)), "outside not filled")
    }

    private func isSolid(_ px: [UInt8], _ width: Int, _ point: CGPoint, scale: CGFloat = 2) -> Bool {
        let i = (Int(point.y * scale) * width + Int(point.x * scale)) * 4
        return px[i + 3] >= 250 && px[i] >= 250 && px[i + 1] <= 5
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

    /// RGBA pixels of `drawing` rendered over the page at `scale`, light
    /// mode, with the pixel grid's width.
    private func pixels(of drawing: PKDrawing, scale: CGFloat) -> (px: [UInt8], width: Int, height: Int) {
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: CGRect(origin: .zero, size: page), scale: scale)
        }
        let cg = image!.cgImage!
        let width = cg.width, height = cg.height
        var px = [UInt8](repeating: 0, count: width * height * 4)
        px.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (px, width, height)
    }

    private func isInside(_ point: CGPoint, _ rect: CGRect) -> Bool {
        let dx = (point.x - rect.midX) / (rect.width / 2)
        let dy = (point.y - rect.midY) / (rect.height / 2)
        return dx * dx + dy * dy <= 1
    }

    /// Field reports, Sept 25, 2026. First: a tap inside an ellipse drew a
    /// few yellow lines across its middle and nothing else - PencilKit
    /// draws nothing for a stroke under ~2pt, and one-row bands were
    /// 0.75pt. Then, once it filled: faint lines where the bands' soft
    /// edges met. So every inside pixel must be the fill colour at full
    /// strength, at the iPad's screen scale and zoomed in.
    func testFillInsideAnEllipse_isSolid_andNothingOutside() async throws {
        let drawing = ellipseDrawing()
        let result = await FillTool.fill(drawing, in: page, at: CGPoint(x: ellipse.midX, y: ellipse.midY + 40),
                                         color: UIColor(red: 1, green: 0, blue: 0, alpha: 1))
        let filled = try XCTUnwrap(result)

        for scale: CGFloat in [2, 3] {
            let (px, width, height) = pixels(of: filled, scale: scale)
            let inner = ellipse.insetBy(dx: 4, dy: 4), outer = ellipse.insetBy(dx: -4, dy: -4)
            var insideTotal = 0, insideSolid = 0, outsideFilled = 0
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    let point = CGPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)
                    if isInside(point, inner) {
                        insideTotal += 1
                        if px[i + 3] >= 250, px[i] >= 250, px[i + 1] <= 5, px[i + 2] <= 5 { insideSolid += 1 }
                    } else if !isInside(point, outer), px[i + 3] > 0 {
                        outsideFilled += 1
                    }
                }
            }
            XCTAssertEqual(insideSolid, insideTotal, "at \(scale)x: \(insideTotal - insideSolid) inside pixels not solid fill")
            XCTAssertEqual(outsideFilled, 0, "at \(scale)x: fill escaped the ellipse")
        }
    }

    /// Field report, Sept 25, 2026: a fill couldn't be erased as one
    /// piece. It is one stroke, so the precise eraser takes it in one go.
    func testFillOfAnEllipse_isOneStroke() async throws {
        let drawing = ellipseDrawing()
        let result = await FillTool.fill(drawing, in: page, at: CGPoint(x: ellipse.midX, y: ellipse.midY), color: .red)
        XCTAssertEqual(try XCTUnwrap(result).strokes.count, drawing.strokes.count + 1)
    }

    /// A U: a box with a wall hanging from its top two thirds of the way
    /// down. The fill must reach both arms without its zig-zag crossing
    /// the wall, in a stroke per arm or so, not one per row.
    func testFillOfAU_coversBothArms_inAFewStrokes() async throws {
        func line(_ a: CGPoint, _ b: CGPoint) -> PKStroke {
            let points = (0...20).map { step -> PKStrokePoint in
                let t = CGFloat(step) / 20
                return PKStrokePoint(location: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t),
                                     timeOffset: Double(step) * 0.01, size: CGSize(width: 3, height: 3),
                                     opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))
        }
        let drawing = PKDrawing(strokes: squareDrawing().strokes + [line(CGPoint(x: 200, y: 100), CGPoint(x: 200, y: 233))])
        let result = await FillTool.fill(drawing, in: page, at: CGPoint(x: 150, y: 150), color: UIColor(red: 1, green: 0, blue: 0, alpha: 1))
        let filled = try XCTUnwrap(result)
        XCTAssertLessThanOrEqual(filled.strokes.count - drawing.strokes.count, 3)

        let (px, width, _) = pixels(of: filled, scale: 2)
        func isSolid(_ p: CGPoint) -> Bool {
            let i = (Int(p.y * 2) * width + Int(p.x * 2)) * 4
            return px[i + 3] >= 250 && px[i] >= 250 && px[i + 1] <= 5
        }
        XCTAssertTrue(isSolid(CGPoint(x: 150, y: 150)), "left arm")
        XCTAssertTrue(isSolid(CGPoint(x: 250, y: 150)), "right arm")
        XCTAssertTrue(isSolid(CGPoint(x: 200, y: 270)), "bottom")
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

    /// Field report, Sept 25, 2026: the fill didn't take the pen's colour.
    /// Changing the pen's colour sets the fill's; the fill's own colour row
    /// can still pick another until the pen's changes again.
    func testFillColour_followsThePen_untilOverridden() {
        var state = DrawingToolState()
        state.penColor = .blue
        XCTAssertEqual(state.fillColor, .blue)
        state.fillColor = .green
        XCTAssertEqual(state.penColor, .blue)
        state.penColor = .red
        XCTAssertEqual(state.fillColor, .red)
    }
}
