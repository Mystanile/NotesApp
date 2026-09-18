import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif
import PencilKit

/// Turns a freehand stroke into a clean geometric one, the way the
/// hold-to-snap shape tool in GoodNotes and Apple Notes does. The pipeline
/// is the standard one (`Docs/TOOL_FIXES.md` Part 1):
///
/// 1. resample the path to equidistant points, so nothing downstream
///    depends on how fast the pencil moved;
/// 2. decide open vs closed from the endpoint gap relative to the path
///    length (tolerant of overshoot and undershoot);
/// 3. find corners by turning angle;
/// 4. classify on the corner count: 0 closed → circle/ellipse, 3 → triangle,
///    4 → rectangle (rotated allowed) or a general quad, 5–6 → polygon;
///    open with no corners and a straight fit → line; open with a V at the
///    end → arrow;
/// 5. bail out (`nil`) when nothing fits. A shape tool that guesses wrong
///    is worse than one that leaves the stroke alone.
///
/// Corners come out sharp because polygon vertices are repeated three
/// times in the `PKStrokePath` control points: the path is a cubic
/// B-spline, and a control point of multiplicity three is where such a
/// spline actually passes through a point with a real corner. Feeding it
/// the bare corners rounded every one of them (bug 2 in the brief).
/// `ShapeRecognizerTests` samples the built path to prove that holds.
///
/// Pure geometry, no UI: `nonisolated` so it can run wherever it's called
/// (invariant 10 - it is called during a stroke).
nonisolated enum ShapeRecognizer {

    /// What was recognized, in the same coordinate space as the input.
    /// `outline` is the polyline the preview draws and the stroke follows:
    /// closed shapes end where they start.
    struct RecognizedShape: Equatable {
        enum Kind: Equatable {
            case line, arrow, circle, ellipse, triangle, square, rectangle, quadrilateral, pentagon, hexagon
        }
        var kind: Kind
        var outline: [CGPoint]
        /// Vertices that must render as sharp corners (polygons), as
        /// indices into `outline`. Empty for curves.
        var cornerIndices: [Int]
    }

    // MARK: - Tuning

    /// Anything shorter is a tap or a tick, not a shape.
    static let minimumPathLength: CGFloat = 24
    private static let sampleCount = 64
    /// Turning angle at a resampled point (over a window of `cornerWindow`
    /// samples either side) that counts as a corner. Hand-drawn corners come
    /// out at 60–110°; curvature on a circle drawn at 64 samples over a
    /// window of 3 is ~17° per step, which is why the window matters.
    private static let cornerAngle: CGFloat = 48 * .pi / 180
    private static let cornerWindow = 3
    /// A closed shape's ends may miss each other by this fraction of the
    /// path length (a square's side is a quarter of its perimeter, so this
    /// tolerates missing by close to half a side).
    private static let closedGapFraction: CGFloat = 0.12
    private static let closedGapMinimum: CGFloat = 14
    /// Open path: farthest point from the chord, relative to chord length.
    private static let lineDeviation: CGFloat = 0.06
    /// Closed, no corners: mean |((x-cx)/rx)² + ((y-cy)/ry)² − 1|.
    private static let ellipseResidual: CGFloat = 0.22
    /// Circle when the two radii are within this fraction of each other.
    private static let circleTolerance: CGFloat = 0.12
    /// Rectangle when every interior angle is within this of 90°.
    private static let rightAngleTolerance: CGFloat = 16 * .pi / 180
    /// Snap a rectangle to the axes when it is within this of them.
    private static let axisSnapTolerance: CGFloat = 7 * .pi / 180
    /// Square when the two side lengths are within this fraction.
    private static let squareTolerance: CGFloat = 0.12

    // MARK: - Entry points

    /// Recognize `rawPoints` (pencil locations, any density) as a shape, or
    /// `nil` when nothing fits well enough to be worth replacing real ink.
    static func recognize(_ rawPoints: [CGPoint]) -> RecognizedShape? {
        let cleaned = dedupe(rawPoints)
        guard cleaned.count >= 3 else { return nil }
        let length = pathLength(cleaned)
        guard length >= minimumPathLength else { return nil }

        let points = resample(cleaned, count: sampleCount)
        if let loop = closedLoop(points, length: length) {
            return recognizeClosed(loop)
        }
        return recognizeOpen(points, length: length)
    }

    /// The closed loop inside `points`, if the path closes on itself:
    /// the pair (head point, tail point) that come nearest each other,
    /// with the head in the first quarter of the path and the tail in the
    /// last. That is what makes overshoot harmless - a square drawn past
    /// its starting corner has its tail running back along the first side,
    /// and the loop is cut where the two meet rather than at the endpoints,
    /// where the doubled-back tail would read as a 180° corner and swallow
    /// the real one next to it. Undershoot closes at the endpoints as long
    /// as the gap is small against the path length.
    private static func closedLoop(_ points: [CGPoint], length: CGFloat) -> [CGPoint]? {
        let n = points.count
        let quarter = n / 4
        let threshold = max(length * closedGapFraction, closedGapMinimum)
        var best: (i: Int, j: Int, d: CGFloat)?
        for i in 0..<quarter {
            for j in stride(from: n - 1, through: n - quarter, by: -1) where j - i >= n / 2 {
                let d = distance(points[i], points[j])
                if d < threshold, best.map({ d < $0.d }) ?? true {
                    best = (i, j, d)
                }
            }
        }
        guard let best else { return nil }
        return resample(Array(points[best.i...best.j]), count: sampleCount)
    }

    /// The recognized shape as ink. Width and colour come from the active
    /// tool and nowhere else - the old fixed 4-point width was bug 3.
    static func stroke(for shape: RecognizedShape, tool: PKInkingTool) -> PKStroke {
        let width = max(tool.width, 0.5)
        var controlPoints: [CGPoint] = []
        controlPoints.reserveCapacity(shape.outline.count * 3)
        let corners = Set(shape.cornerIndices)
        for (index, point) in shape.outline.enumerated() {
            controlPoints.append(point)
            if corners.contains(index) {
                // Multiplicity three: a sharp vertex in a cubic B-spline.
                controlPoints.append(point)
                controlPoints.append(point)
            }
        }
        // The endpoints of an open B-spline are pulled toward the second
        // and second-to-last control points; tripling the ends puts the
        // curve exactly on them.
        if !corners.contains(0) {
            controlPoints.insert(contentsOf: [shape.outline[0], shape.outline[0]], at: 0)
        }
        let lastIndex = shape.outline.count - 1
        if !corners.contains(lastIndex) {
            controlPoints.append(shape.outline[lastIndex])
            controlPoints.append(shape.outline[lastIndex])
        }

        var strokePoints: [PKStrokePoint] = []
        strokePoints.reserveCapacity(controlPoints.count)
        var timeOffset: TimeInterval = 0
        var previous: CGPoint?
        for point in controlPoints {
            if let previous { timeOffset += Double(distance(previous, point)) * 0.002 }
            previous = point
            strokePoints.append(PKStrokePoint(
                location: point,
                timeOffset: timeOffset,
                size: CGSize(width: width, height: width),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            ))
        }
        let path = PKStrokePath(controlPoints: strokePoints, creationDate: Date())
        return PKStroke(ink: tool.ink, path: path)
    }

    // MARK: - Classification

    private static func recognizeOpen(_ points: [CGPoint], length: CGFloat) -> RecognizedShape? {
        let corners = cornerIndices(points, closed: false)
        let start = points[0], end = points[points.count - 1]

        if corners.isEmpty {
            let chord = distance(start, end)
            guard chord > 0 else { return nil }
            let deviation = points.map { distanceFromSegment($0, start, end) }.max() ?? 0
            guard deviation / chord < lineDeviation else { return nil }
            return RecognizedShape(kind: .line, outline: [start, end], cornerIndices: [0, 1])
        }

        return recognizeArrow(points, corners: corners, length: length)
    }

    /// An arrow drawn in one stroke: a straight shaft, then a V (or one
    /// barb) at the far end. All the corners sit in the last part of the
    /// path and the shaft is most of it.
    private static func recognizeArrow(_ points: [CGPoint], corners: [Int], length: CGFloat) -> RecognizedShape? {
        guard (1...3).contains(corners.count) else { return nil }
        let firstCorner = corners[0]
        // The shaft: start to the first corner, straight, at least half.
        let tail = points[0]
        let shaftEnd = points[firstCorner]
        let shaftLength = distance(tail, shaftEnd)
        guard shaftLength > length * 0.5 else { return nil }
        let shaftDeviation = points[0...firstCorner].map { distanceFromSegment($0, tail, shaftEnd) }.max() ?? 0
        guard shaftDeviation / shaftLength < lineDeviation * 1.5 else { return nil }

        // The head is everything after the shaft. Its tip is the point
        // farthest along the shaft's direction; the barbs' length is how
        // far the head's points stray from the tip.
        let head = Array(points[firstCorner...])
        let direction = normalized(CGVector(dx: shaftEnd.x - tail.x, dy: shaftEnd.y - tail.y))
        guard let tip = head.max(by: { projection($0, from: tail, along: direction) < projection($1, from: tail, along: direction) })
        else { return nil }
        let barbLength = max(head.map { distance($0, tip) }.max() ?? 0, shaftLength * 0.12)
        // A head that's as long as the shaft is a bent line, not an arrow.
        guard barbLength < shaftLength * 0.6 else { return nil }

        let barbAngle: CGFloat = 30 * .pi / 180
        let back = CGVector(dx: -direction.dx, dy: -direction.dy)
        let left = rotate(back, by: barbAngle)
        let right = rotate(back, by: -barbAngle)
        let leftBarb = CGPoint(x: tip.x + left.dx * barbLength, y: tip.y + left.dy * barbLength)
        let rightBarb = CGPoint(x: tip.x + right.dx * barbLength, y: tip.y + right.dy * barbLength)
        // Drawn as one stroke: shaft to the tip, out one barb, back to the
        // tip, out the other. Every vertex is a corner.
        let outline = [tail, tip, leftBarb, tip, rightBarb]
        return RecognizedShape(kind: .arrow, outline: outline, cornerIndices: Array(outline.indices))
    }

    private static func recognizeClosed(_ points: [CGPoint]) -> RecognizedShape? {
        let corners = cornerIndices(points, closed: true)
        // The ellipse fit goes first: the tight ends of a long ellipse turn
        // sharply enough over the corner window to read as corners. The
        // residual gate keeps polygons out - a square's is ~0.33, a
        // triangle's ~0.5, against 0.22.
        if corners.count <= 2, let ellipse = recognizeEllipse(points) {
            return ellipse
        }
        switch corners.count {
        case 3:
            return polygon(.triangle, vertices: corners.map { points[$0] })
        case 4:
            return recognizeQuadrilateral(corners.map { points[$0] })
        case 5:
            return polygon(.pentagon, vertices: corners.map { points[$0] })
        case 6:
            return polygon(.hexagon, vertices: corners.map { points[$0] })
        default:
            return nil
        }
    }

    private static func recognizeEllipse(_ points: [CGPoint]) -> RecognizedShape? {
        let bounds = boundingBox(points)
        let rx = bounds.width / 2, ry = bounds.height / 2
        guard rx > 2, ry > 2 else { return nil }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let residual = points.reduce(CGFloat(0)) { sum, p in
            let nx = (p.x - center.x) / rx, ny = (p.y - center.y) / ry
            return sum + abs(nx * nx + ny * ny - 1)
        } / CGFloat(points.count)
        guard residual < ellipseResidual else { return nil }

        let isCircle = abs(rx - ry) / max(rx, ry) < circleTolerance
        let r = (rx + ry) / 2
        let radiusX = isCircle ? r : rx
        let radiusY = isCircle ? r : ry
        // Start the outline where the pencil started, so the snapped shape
        // doesn't visibly rotate away from the freehand one.
        let startAngle = atan2((points[0].y - center.y) / radiusY, (points[0].x - center.x) / radiusX)
        let samples = 72
        // Two extra wrap points past the closing one: an open B-spline's
        // ends are pulled toward their neighbours, and these put that pull
        // onto points the loop already covers.
        let outline = (0...(samples + 2)).map { i -> CGPoint in
            let angle = startAngle + (CGFloat(i) / CGFloat(samples)) * 2 * .pi
            return CGPoint(x: center.x + radiusX * cos(angle), y: center.y + radiusY * sin(angle))
        }
        return RecognizedShape(kind: isCircle ? .circle : .ellipse, outline: outline, cornerIndices: [])
    }

    private static func recognizeQuadrilateral(_ vertices: [CGPoint]) -> RecognizedShape? {
        let angles = interiorAngles(vertices)
        let isRectangle = angles.allSatisfy { abs($0 - .pi / 2) < rightAngleTolerance }
        guard isRectangle else {
            return polygon(.quadrilateral, vertices: vertices)
        }

        // Orientation from the longest side, snapped to the axes when it's
        // close - the old recognizer squared every rectangle to the screen.
        var longest: (length: CGFloat, angle: CGFloat) = (0, 0)
        for i in 0..<4 {
            let a = vertices[i], b = vertices[(i + 1) % 4]
            let len = distance(a, b)
            if len > longest.length { longest = (len, atan2(b.y - a.y, b.x - a.x)) }
        }
        var theta = longest.angle
        // Reduce to (-45°, 45°]: a rectangle's orientation repeats every 90°.
        while theta > .pi / 4 { theta -= .pi / 2 }
        while theta <= -.pi / 4 { theta += .pi / 2 }
        if abs(theta) < axisSnapTolerance { theta = 0 }

        // Bounding box in the rotated frame, rotated back.
        let cosT = cos(-theta), sinT = sin(-theta)
        let rotated = vertices.map { CGPoint(x: $0.x * cosT - $0.y * sinT, y: $0.x * sinT + $0.y * cosT) }
        var box = boundingBox(rotated)
        let isSquare = abs(box.width - box.height) / max(box.width, box.height) < squareTolerance
        if isSquare {
            let side = (box.width + box.height) / 2
            box = CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side)
        }
        let cosB = cos(theta), sinB = sin(theta)
        let cornersRotated = [
            CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)
        ]
        let corners = cornersRotated.map { CGPoint(x: $0.x * cosB - $0.y * sinB, y: $0.x * sinB + $0.y * cosB) }
        // Keep the vertex order the pencil drew, starting nearest its first
        // corner, so the snap doesn't visibly jump.
        let startIndex = corners.indices.min { distance(corners[$0], vertices[0]) < distance(corners[$1], vertices[0]) } ?? 0
        let clockwise = signedArea(vertices) * signedArea(corners) >= 0
        var ordered: [CGPoint] = []
        for k in 0..<4 {
            let idx = clockwise ? (startIndex + k) % 4 : (startIndex - k + 4) % 4
            ordered.append(corners[idx])
        }
        return polygon(isSquare ? .square : .rectangle, vertices: ordered)
    }

    private static func polygon(_ kind: RecognizedShape.Kind, vertices: [CGPoint]) -> RecognizedShape? {
        guard vertices.count >= 3 else { return nil }
        // Degenerate (two corners on top of each other) - leave it alone.
        for i in 0..<vertices.count where distance(vertices[i], vertices[(i + 1) % vertices.count]) < 4 {
            return nil
        }
        let outline = vertices + [vertices[0]]
        return RecognizedShape(kind: kind, outline: outline, cornerIndices: Array(outline.indices))
    }

    // MARK: - Corners

    /// Indices of the resampled points where the path turns sharply, one
    /// per corner (the sharpest point of each run of turning). For a closed
    /// path the start/end junction is a candidate too, since most closed
    /// shapes start at a corner.
    static func cornerIndices(_ points: [CGPoint], closed: Bool) -> [Int] {
        let n = points.count
        let w = cornerWindow
        guard n > 2 * w + 1 else { return [] }

        func point(_ i: Int) -> CGPoint {
            closed ? points[((i % n) + n) % n] : points[min(max(i, 0), n - 1)]
        }
        func turning(at i: Int) -> CGFloat {
            let a = point(i - w), b = point(i), c = point(i + w)
            let v1 = CGVector(dx: b.x - a.x, dy: b.y - a.y)
            let v2 = CGVector(dx: c.x - b.x, dy: c.y - b.y)
            let l1 = hypot(v1.dx, v1.dy), l2 = hypot(v2.dx, v2.dy)
            guard l1 > 0, l2 > 0 else { return 0 }
            let cosine = max(-1, min(1, (v1.dx * v2.dx + v1.dy * v2.dy) / (l1 * l2)))
            return acos(cosine)
        }

        let range = closed ? Array(0..<n) : Array(w..<(n - w))
        let angles = range.map { ($0, turning(at: $0)) }
        var corners: [Int] = []
        var run: [(Int, CGFloat)] = []
        func flush() {
            if let best = run.max(by: { $0.1 < $1.1 }) { corners.append(best.0) }
            run.removeAll()
        }
        for (i, angle) in angles {
            if angle >= cornerAngle {
                run.append((i, angle))
            } else if !run.isEmpty {
                flush()
            }
        }
        flush()
        // On a closed path a run can wrap around the junction: merge a run
        // that ends at n-1 with one that starts at 0.
        if closed, corners.count >= 2, corners.first! <= 2 * w, corners.last! >= n - 1 - 2 * w {
            let first = corners.removeFirst()
            let last = corners.removeLast()
            corners.append(turning(at: first) >= turning(at: last) ? first : last)
        }
        return corners.sorted()
    }

    // MARK: - Geometry

    private static func dedupe(_ points: [CGPoint]) -> [CGPoint] {
        var result: [CGPoint] = []
        for p in points where result.last.map({ distance($0, p) > 0.25 }) ?? true {
            result.append(p)
        }
        return result
    }

    static func pathLength(_ points: [CGPoint]) -> CGFloat {
        guard points.count > 1 else { return 0 }
        return (1..<points.count).reduce(0) { $0 + distance(points[$1 - 1], points[$1]) }
    }

    /// `count` points spaced evenly along the polyline, first and last kept.
    static func resample(_ points: [CGPoint], count: Int) -> [CGPoint] {
        guard points.count > 1, count > 1 else { return points }
        let total = pathLength(points)
        guard total > 0 else { return Array(repeating: points[0], count: count) }
        let step = total / CGFloat(count - 1)
        var result = [points[0]]
        var carried: CGFloat = 0
        var previous = points[0]
        for point in points.dropFirst() {
            var segment = distance(previous, point)
            var from = previous
            while carried + segment >= step, result.count < count - 1 {
                let t = (step - carried) / segment
                let q = CGPoint(x: from.x + (point.x - from.x) * t, y: from.y + (point.y - from.y) * t)
                result.append(q)
                segment -= (step - carried)
                carried = 0
                from = q
            }
            carried += segment
            previous = point
        }
        while result.count < count { result.append(points[points.count - 1]) }
        return result
    }

    private static func boundingBox(_ points: [CGPoint]) -> CGRect {
        var minX = CGFloat.greatestFiniteMagnitude, minY = minX
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = maxX
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private static func distanceFromSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let ab = CGVector(dx: b.x - a.x, dy: b.y - a.y)
        let lengthSquared = ab.dx * ab.dx + ab.dy * ab.dy
        guard lengthSquared > 0 else { return distance(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * ab.dx + (p.y - a.y) * ab.dy) / lengthSquared))
        return distance(p, CGPoint(x: a.x + ab.dx * t, y: a.y + ab.dy * t))
    }

    private static func interiorAngles(_ vertices: [CGPoint]) -> [CGFloat] {
        let n = vertices.count
        return (0..<n).map { i in
            let prev = vertices[(i - 1 + n) % n], cur = vertices[i], next = vertices[(i + 1) % n]
            let v1 = CGVector(dx: prev.x - cur.x, dy: prev.y - cur.y)
            let v2 = CGVector(dx: next.x - cur.x, dy: next.y - cur.y)
            let l1 = hypot(v1.dx, v1.dy), l2 = hypot(v2.dx, v2.dy)
            guard l1 > 0, l2 > 0 else { return 0 }
            return acos(max(-1, min(1, (v1.dx * v2.dx + v1.dy * v2.dy) / (l1 * l2))))
        }
    }

    private static func signedArea(_ polygon: [CGPoint]) -> CGFloat {
        var area: CGFloat = 0
        for i in 0..<polygon.count {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            area += a.x * b.y - b.x * a.y
        }
        return area / 2
    }

    private static func normalized(_ v: CGVector) -> CGVector {
        let l = hypot(v.dx, v.dy)
        return l > 0 ? CGVector(dx: v.dx / l, dy: v.dy / l) : CGVector(dx: 1, dy: 0)
    }

    private static func projection(_ p: CGPoint, from origin: CGPoint, along d: CGVector) -> CGFloat {
        (p.x - origin.x) * d.dx + (p.y - origin.y) * d.dy
    }

    private static func rotate(_ v: CGVector, by angle: CGFloat) -> CGVector {
        CGVector(dx: v.dx * cos(angle) - v.dy * sin(angle), dy: v.dx * sin(angle) + v.dy * cos(angle))
    }
}
