import XCTest
import PencilKit
@testable import Mystnotes

/// The hold-to-snap recognizer, against synthetic "hand-drawn" input: ideal
/// shapes walked at pencil-sample spacing with deterministic jitter, plus
/// the overshoot / undershoot every real hand produces. Each case is one
/// of the acceptance items in `Docs/TOOL_FIXES.md` Part 1.
final class ShapeRecognizerTests: XCTestCase {

    // MARK: - Synthetic strokes

    /// Deterministic jitter, so a failure reproduces.
    private struct Jitter {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next(_ amplitude: CGFloat) -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = CGFloat(Double(state >> 11) / Double(1 << 53))
            return (unit * 2 - 1) * amplitude
        }
    }

    /// Walks a polyline at ~2 pt spacing with `jitter` pt of noise. `closeBack`
    /// is how far past the end to keep going along the first segment
    /// (overshoot, positive) or how far short of the end to stop (negative).
    private func handDrawn(_ vertices: [CGPoint], closed: Bool, jitter: CGFloat = 1.5,
                           overshoot: CGFloat = 0, seed: UInt64 = 7) -> [CGPoint] {
        var path = vertices
        if closed { path.append(vertices[0]) }
        if closed, overshoot > 0 {
            let a = vertices[0], b = vertices[1]
            let len = hypot(b.x - a.x, b.y - a.y)
            path.append(CGPoint(x: a.x + (b.x - a.x) * overshoot / len, y: a.y + (b.y - a.y) * overshoot / len))
        }
        var dense: [CGPoint] = []
        for i in 1..<path.count {
            let a = path[i - 1], b = path[i]
            let len = hypot(b.x - a.x, b.y - a.y)
            let steps = max(Int(len / 2), 1)
            for s in 0..<steps {
                let t = CGFloat(s) / CGFloat(steps)
                dense.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        dense.append(path[path.count - 1])
        if closed, overshoot < 0 {
            // Stop short: drop the tail.
            let total = ShapeRecognizer.pathLength(dense)
            var kept: [CGPoint] = [dense[0]]
            var run: CGFloat = 0
            for i in 1..<dense.count {
                run += hypot(dense[i].x - dense[i - 1].x, dense[i].y - dense[i - 1].y)
                if run > total + overshoot { break }
                kept.append(dense[i])
            }
            dense = kept
        }
        var rng = Jitter(seed: seed)
        return dense.map { CGPoint(x: $0.x + rng.next(jitter), y: $0.y + rng.next(jitter)) }
    }

    private func ellipsePoints(center: CGPoint, rx: CGFloat, ry: CGFloat, jitter: CGFloat = 1.5,
                               startAngle: CGFloat = -.pi / 2, sweep: CGFloat = 2 * .pi, seed: UInt64 = 11) -> [CGPoint] {
        var rng = Jitter(seed: seed)
        let steps = 180
        return (0...steps).map { i in
            let angle = startAngle + sweep * CGFloat(i) / CGFloat(steps)
            return CGPoint(x: center.x + rx * cos(angle) + rng.next(jitter),
                           y: center.y + ry * sin(angle) + rng.next(jitter))
        }
    }

    private func assertVertices(_ shape: ShapeRecognizer.RecognizedShape?, near expected: [CGPoint],
                                tolerance: CGFloat = 8, file: StaticString = #filePath, line: UInt = #line) {
        guard let shape else { return XCTFail("nothing recognized", file: file, line: line) }
        let vertices = shape.cornerIndices.dropLast().map { shape.outline[$0] }
        XCTAssertEqual(vertices.count, expected.count, "vertex count", file: file, line: line)
        for e in expected {
            let nearest = vertices.map { hypot($0.x - e.x, $0.y - e.y) }.min() ?? .infinity
            XCTAssertLessThan(nearest, tolerance, "no vertex near \(e)", file: file, line: line)
        }
    }

    // MARK: - Closed shapes

    func testSquare_isASquare_notACircle() {
        let corners = [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100), CGPoint(x: 300, y: 300), CGPoint(x: 100, y: 300)]
        let shape = ShapeRecognizer.recognize(handDrawn(corners, closed: true))
        XCTAssertEqual(shape?.kind, .square)
        assertVertices(shape, near: corners)
    }

    func testRectangle_axisAligned() {
        let corners = [CGPoint(x: 50, y: 50), CGPoint(x: 350, y: 50), CGPoint(x: 350, y: 180), CGPoint(x: 50, y: 180)]
        let shape = ShapeRecognizer.recognize(handDrawn(corners, closed: true))
        XCTAssertEqual(shape?.kind, .rectangle)
        assertVertices(shape, near: corners)
    }

    func testRectangle_rotated_keepsItsRotation() {
        let angle: CGFloat = 30 * .pi / 180
        let center = CGPoint(x: 300, y: 300)
        let half = CGSize(width: 150, height: 60)
        let corners = [(-1, -1), (1, -1), (1, 1), (-1, 1)].map { (sx, sy) -> CGPoint in
            let x = CGFloat(sx) * half.width, y = CGFloat(sy) * half.height
            return CGPoint(x: center.x + x * cos(angle) - y * sin(angle), y: center.y + x * sin(angle) + y * cos(angle))
        }
        let shape = ShapeRecognizer.recognize(handDrawn(corners, closed: true))
        XCTAssertEqual(shape?.kind, .rectangle)
        assertVertices(shape, near: corners)
        // Not squared to the screen: no two vertices share an x or y.
        let vertices = shape!.cornerIndices.dropLast().map { shape!.outline[$0] }
        for i in 0..<vertices.count {
            let a = vertices[i], b = vertices[(i + 1) % vertices.count]
            XCTAssertGreaterThan(min(abs(a.x - b.x), abs(a.y - b.y)), 20, "edge \(i) was snapped to an axis")
        }
    }

    func testRectangle_nearlyAxisAligned_snapsToAxes() {
        let angle: CGFloat = 3 * .pi / 180
        let center = CGPoint(x: 300, y: 300)
        let corners = [(-1, -1), (1, -1), (1, 1), (-1, 1)].map { (sx, sy) -> CGPoint in
            let x = CGFloat(sx) * 150, y = CGFloat(sy) * 60
            return CGPoint(x: center.x + x * cos(angle) - y * sin(angle), y: center.y + x * sin(angle) + y * cos(angle))
        }
        let shape = ShapeRecognizer.recognize(handDrawn(corners, closed: true))
        XCTAssertEqual(shape?.kind, .rectangle)
        let vertices = shape!.cornerIndices.dropLast().map { shape!.outline[$0] }
        let xs = Set(vertices.map { ($0.x * 10).rounded() }), ys = Set(vertices.map { ($0.y * 10).rounded() })
        XCTAssertEqual(xs.count, 2, "axis-aligned: two distinct x values")
        XCTAssertEqual(ys.count, 2, "axis-aligned: two distinct y values")
    }

    func testSquare_withOvershoot_isStillASquare() {
        let corners = [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100), CGPoint(x: 300, y: 300), CGPoint(x: 100, y: 300)]
        let shape = ShapeRecognizer.recognize(handDrawn(corners, closed: true, overshoot: 60))
        XCTAssertEqual(shape?.kind, .square)
        assertVertices(shape, near: corners)
    }

    func testSquare_stoppingShort_isStillASquare() {
        let corners = [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100), CGPoint(x: 300, y: 300), CGPoint(x: 100, y: 300)]
        let shape = ShapeRecognizer.recognize(handDrawn(corners, closed: true, overshoot: -50))
        XCTAssertEqual(shape?.kind, .square)
        assertVertices(shape, near: corners)
    }

    func testCircle_isACircle_notASquare() {
        let shape = ShapeRecognizer.recognize(ellipsePoints(center: CGPoint(x: 200, y: 200), rx: 100, ry: 100))
        XCTAssertEqual(shape?.kind, .circle)
        XCTAssertTrue(shape!.cornerIndices.isEmpty, "a circle has no corners")
        for p in shape!.outline {
            XCTAssertEqual(hypot(p.x - 200, p.y - 200), 100, accuracy: 4)
        }
    }

    func testEllipse() {
        let shape = ShapeRecognizer.recognize(ellipsePoints(center: CGPoint(x: 200, y: 200), rx: 150, ry: 60))
        XCTAssertEqual(shape?.kind, .ellipse)
    }

    func testTriangle() {
        let corners = [CGPoint(x: 200, y: 80), CGPoint(x: 340, y: 320), CGPoint(x: 60, y: 320)]
        let shape = ShapeRecognizer.recognize(handDrawn(corners, closed: true))
        XCTAssertEqual(shape?.kind, .triangle)
        assertVertices(shape, near: corners)
    }

    func testPentagon() {
        let corners = (0..<5).map { i -> CGPoint in
            let a = -CGFloat.pi / 2 + CGFloat(i) * 2 * .pi / 5
            return CGPoint(x: 250 + 120 * cos(a), y: 250 + 120 * sin(a))
        }
        let shape = ShapeRecognizer.recognize(handDrawn(corners, closed: true))
        XCTAssertEqual(shape?.kind, .pentagon)
        assertVertices(shape, near: corners)
    }

    // MARK: - Open shapes

    func testLine_slightlyWavy() {
        var rng = Jitter(seed: 3)
        let points = (0...100).map { i -> CGPoint in
            let t = CGFloat(i) / 100
            return CGPoint(x: 50 + 300 * t + rng.next(1), y: 80 + 120 * t + sin(t * 6) * 3 + rng.next(1))
        }
        let shape = ShapeRecognizer.recognize(points)
        XCTAssertEqual(shape?.kind, .line)
        XCTAssertEqual(shape?.outline.count, 2)
    }

    func testArrow() {
        // Shaft left to right, then a barb up-left, back to the tip, a barb down-left.
        let tail = CGPoint(x: 50, y: 200), tip = CGPoint(x: 350, y: 200)
        let path = [tail, tip, CGPoint(x: 300, y: 170), tip, CGPoint(x: 300, y: 230)]
        let shape = ShapeRecognizer.recognize(handDrawn(path, closed: false))
        XCTAssertEqual(shape?.kind, .arrow)
        let head = shape!.outline[1]
        XCTAssertEqual(head.x, tip.x, accuracy: 8)
        XCTAssertEqual(head.y, tip.y, accuracy: 8)
        XCTAssertEqual(shape!.outline[0].x, tail.x, accuracy: 6)
    }

    func testArrow_withOneBarb() {
        let tail = CGPoint(x: 50, y: 200), tip = CGPoint(x: 350, y: 200)
        let shape = ShapeRecognizer.recognize(handDrawn([tail, tip, CGPoint(x: 300, y: 165)], closed: false))
        XCTAssertEqual(shape?.kind, .arrow)
    }

    // MARK: - Bail-outs

    func testBentLine_isLeftAlone() {
        let shape = ShapeRecognizer.recognize(handDrawn([CGPoint(x: 50, y: 50), CGPoint(x: 200, y: 200), CGPoint(x: 350, y: 60)], closed: false))
        XCTAssertNil(shape, "an L / V isn't a line and isn't an arrow")
    }

    func testCursiveS_isLeftAlone() {
        // Two semicircles of opposite turn, stacked: an S. Open, smooth,
        // and nowhere near straight.
        let top = ellipsePoints(center: CGPoint(x: 100, y: 100), rx: 40, ry: 40, startAngle: -.pi / 2, sweep: .pi)
        let bottom = ellipsePoints(center: CGPoint(x: 100, y: 180), rx: 40, ry: 40, startAngle: -.pi / 2, sweep: -.pi, seed: 5)
        XCTAssertNil(ShapeRecognizer.recognize(top + bottom))
    }

    func testTinyStroke_isLeftAlone() {
        XCTAssertNil(ShapeRecognizer.recognize([CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 3), CGPoint(x: 9, y: 6)]))
    }

    // MARK: - The stroke

    /// The brief's bug 2: `PKStrokePath` takes B-spline control points, so
    /// bare corners come out rounded. Vertices of multiplicity three are
    /// what makes them sharp - proven here by sampling the built path, not
    /// assumed.
    func testRectangleStroke_hasSharpCorners_andFollowsTheEdges() {
        let corners = [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100), CGPoint(x: 300, y: 250), CGPoint(x: 100, y: 250)]
        let shape = ShapeRecognizer.RecognizedShape(kind: .rectangle, outline: corners + [corners[0]], cornerIndices: [0, 1, 2, 3, 4])
        let tool = PKInkingTool(.pen, color: .black, width: 6)
        let stroke = ShapeRecognizer.stroke(for: shape, tool: tool)

        let samples = stroke.path.interpolatedPoints(by: .distance(1)).map(\.location)
        XCTAssertGreaterThan(samples.count, 500)
        let rect = CGRect(x: 100, y: 100, width: 200, height: 150)
        for p in samples {
            let dx = min(abs(p.x - rect.minX), abs(p.x - rect.maxX))
            let dy = min(abs(p.y - rect.minY), abs(p.y - rect.maxY))
            let onEdge = (dx < 1 && rect.minY - 1...rect.maxY + 1 ~= p.y) || (dy < 1 && rect.minX - 1...rect.maxX + 1 ~= p.x)
            XCTAssertTrue(onEdge, "sample \(p) is off the rectangle's outline")
        }
        for corner in corners {
            let nearest = samples.map { hypot($0.x - corner.x, $0.y - corner.y) }.min() ?? .infinity
            XCTAssertLessThan(nearest, 1.5, "corner \(corner) was rounded off")
        }
        XCTAssertEqual(stroke.path.first?.size.width, 6, "width comes from the tool")
        XCTAssertEqual(stroke.ink.inkType, .pen)
    }

    func testCircleStroke_staysOnTheCircle() {
        let shape = ShapeRecognizer.recognize(ellipsePoints(center: CGPoint(x: 200, y: 200), rx: 100, ry: 100, jitter: 0))!
        let stroke = ShapeRecognizer.stroke(for: shape, tool: PKInkingTool(.marker, color: .red, width: 10))
        let samples = stroke.path.interpolatedPoints(by: .distance(2)).map(\.location)
        for p in samples {
            XCTAssertEqual(hypot(p.x - 200, p.y - 200), 100, accuracy: 2)
        }
        XCTAssertEqual(stroke.path.first?.size.width, 10)
    }
}
