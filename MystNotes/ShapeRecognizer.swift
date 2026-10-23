import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif
import PencilKit

/// How a snapped shape is drawn. PencilKit has no dashed ink, so a dashed
/// or dotted shape is built as many short strokes along the same outline -
/// see `ShapeRecognizer.strokes(for:spec:)`. It only applies to snapped
/// shapes; freehand ink is always solid, because the dashes would have to
/// be recomputed on every sample as the stroke grew.
nonisolated enum ShapeLineStyle: String, CaseIterable, Codable, Sendable {
    case solid, dashed, dotted

    var label: String {
        switch self {
        case .solid: return "Solid"
        case .dashed: return "Dashed"
        case .dotted: return "Dotted"
        }
    }
}

/// Turns a freehand stroke into a clean geometric one, the way the
/// hold-to-snap shape tool in GoodNotes and Apple Notes does. The pipeline
/// is the standard one (`Docs/TOOL_FIXES.md` Part 1):
///
/// 1. resample the path to equidistant points, so nothing downstream
///    depends on how fast the pencil moved;
/// 2. decide open vs closed from the endpoint gap relative to the path
///    length (tolerant of overshoot and undershoot);
/// 3. find corners by turning angle;
/// 4. classify: an open path is a **line first** - fitted over its whole
///    length, whatever corners were found - then an arrow, and only an
///    arrow when there is a real head that doubles back; closed with no
///    corners → circle/ellipse, 3 → triangle, 4 → rectangle (rotated
///    allowed) or a general quad, 5-6 → polygon;
/// 5. bail out (`nil`) when nothing fits. A shape tool that guesses wrong
///    is worse than one that leaves the stroke alone.
///
/// Lines, arrow shafts and rectangles snap to the axes (and to 45°) when
/// they are drawn within a few degrees of them, so a line meant to be
/// horizontal comes out horizontal.
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
        /// Whether `outline` closes back on its first point. Closed curves
        /// need their spline wrapped past the join rather than pinned to
        /// the endpoints.
        var isClosed: Bool = false
    }

    /// Everything the ink of a snapped shape is made of. Built by
    /// `spec(matching:tool:style:)` from the stroke the user actually drew,
    /// so the snapped shape is the same weight as the freehand one it
    /// replaces rather than a constant.
    struct InkSpec {
        var ink: PKInk
        /// Brush size in drawing points.
        var size: CGFloat
        /// Pressure the reconstructed points carry. Copied from the source
        /// stroke: pinning it to 1 is what made every snapped shape come
        /// out at the tool's heaviest possible weight.
        var force: CGFloat
        var style: ShapeLineStyle = .solid
        /// Also copied from the source stroke: pencil and crayon shade by
        /// tilt and opacity, so a shape rebuilt upright at full opacity
        /// came out flatter than the stroke beside it.
        var opacity: CGFloat = 1
        var azimuth: CGFloat = 0
        var altitude: CGFloat = .pi / 2
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
    private static let axisSnapTolerance: CGFloat = 10 * .pi / 180
    /// Square when the two side lengths are within this fraction.
    private static let squareTolerance: CGFloat = 0.12
    /// A line (or an arrow's shaft) within this of horizontal or vertical
    /// is straightened onto it. Generous on purpose: "I meant that to be
    /// horizontal" is the single most common thing asked of a shape tool.
    private static let lineAxisTolerance: CGFloat = 10 * .pi / 180
    /// ...and this much for the 45° diagonals, which are asked for less
    /// often and are easier to hit by accident.
    private static let lineDiagonalTolerance: CGFloat = 6 * .pi / 180

    // MARK: - Entry points

    /// Recognize `rawPoints` (pencil locations, any density) as a shape, or
    /// `nil` when nothing fits well enough to be worth replacing real ink.
    ///
    /// `zoom` is the canvas's zoom scale. The points are in drawing space,
    /// but the size floors are meant on screen, where the hand is: without
    /// it a circle that fills the screen at 4x never snapped, and a 6 pt
    /// scribble at 0.25x did.
    static func recognize(_ rawPoints: [CGPoint], zoom: CGFloat = 1) -> RecognizedShape? {
        let zoom = min(max(zoom, 0.1), 10)
        let cleaned = dedupe(rawPoints)
        guard cleaned.count >= 3 else { return nil }
        let length = pathLength(cleaned)
        guard length >= minimumPathLength / zoom else { return nil }

        let points = resample(cleaned, count: sampleCount)
        if let loop = closedLoop(points, length: length, gapMinimum: closedGapMinimum / zoom) {
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
    private static func closedLoop(_ points: [CGPoint], length: CGFloat, gapMinimum: CGFloat) -> [CGPoint]? {
        let n = points.count
        let quarter = n / 4
        let threshold = max(length * closedGapFraction, gapMinimum)
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

    // MARK: - Ink

    /// The ink a snapped shape should be drawn in, taken from the freehand
    /// stroke it is replacing.
    ///
    /// Size and force come from the stroke's own points (the median, so one
    /// heavy sample at the start doesn't set the weight for the whole
    /// shape). That is the fix for "snapped shapes are always thick and the
    /// width slider doesn't change them": the previous version built every
    /// shape at `tool.width` with `force: 1`, which is the tool's heaviest
    /// possible mark, while the stroke beside it was drawn at whatever
    /// pressure the hand used. Matching the source stroke makes the two the
    /// same weight by construction, whatever the tool and whatever the
    /// slider says.
    ///
    /// `tool` is the fallback for a shape with no source stroke (the live
    /// preview, and the tests).
    static func spec(matching source: PKStroke?, tool: PKInkingTool?, style: ShapeLineStyle = .solid) -> InkSpec {
        let fallbackWidth = max(tool?.width ?? 4, 0.5)
        let fallbackInk = tool?.ink ?? PKInk(.pen, color: .black)
        guard let source, !source.path.isEmpty else {
            return InkSpec(ink: fallbackInk, size: fallbackWidth, force: 1, style: style)
        }
        func median(_ value: (PKStrokePoint) -> CGFloat) -> CGFloat {
            let sorted = source.path.map(value).sorted()
            return sorted[sorted.count / 2]
        }
        return InkSpec(
            ink: source.ink,
            size: max(median { $0.size.width }, 0.5),
            force: median(\.force),
            style: style,
            opacity: median(\.opacity),
            azimuth: median(\.azimuth),
            altitude: median(\.altitude)
        )
    }

    /// The recognized shape as ink: one stroke when it's solid, one per
    /// dash when it isn't.
    static func strokes(for shape: RecognizedShape, spec: InkSpec) -> [PKStroke] {
        let corners = Set(shape.cornerIndices)
        let flags = shape.outline.indices.map { corners.contains($0) }

        switch spec.style {
        case .solid:
            let padded = padded(shape.outline, isCorner: flags, closed: shape.isClosed)
            return [buildStroke(padded.points, isCorner: padded.flags, spec: spec)]
        case .dashed, .dotted:
            let dash = dashLengths(for: spec)
            return dashes(along: shape.outline, isCorner: flags, dash: dash.on, gap: dash.off)
                .map { segment in
                    let padded = padded(segment.points, isCorner: segment.flags, closed: false)
                    return buildStroke(padded.points, isCorner: padded.flags, spec: spec)
                }
        }
    }

    /// Single-stroke convenience: a solid shape in the tool's own ink, for
    /// callers with no source stroke in hand.
    static func stroke(for shape: RecognizedShape, tool: PKInkingTool) -> PKStroke {
        let spec = InkSpec(ink: tool.ink, size: max(tool.width, 0.5), force: 1, style: .solid)
        return strokes(for: shape, spec: spec)[0]
    }

    /// Dash and gap in drawing points, scaled off the brush so a fat pen
    /// gets proportionally longer dashes instead of a smear.
    private static func dashLengths(for spec: InkSpec) -> (on: CGFloat, off: CGFloat) {
        switch spec.style {
        case .solid: return (.greatestFiniteMagnitude, 0)
        case .dashed: return (max(spec.size * 4, 6), max(spec.size * 3, 4.5))
        // A "dot" is a stroke barely longer than it is wide; the brush's
        // own round cap is what makes it round.
        case .dotted: return (max(spec.size * 0.35, 0.5), max(spec.size * 2, 3))
        }
    }

    /// Cuts `outline` into dash-length runs separated by gaps, carrying the
    /// corner flags along so a dash that spans a vertex still has a sharp
    /// one.
    private static func dashes(along outline: [CGPoint], isCorner: [Bool], dash: CGFloat, gap: CGFloat)
        -> [(points: [CGPoint], flags: [Bool])] {
        guard outline.count > 1, dash > 0, gap > 0 else { return [] }
        var result: [(points: [CGPoint], flags: [Bool])] = []
        var current: (points: [CGPoint], flags: [Bool]) = ([outline[0]], [isCorner[0]])
        var drawn: CGFloat = 0          // length accumulated in the current run
        var inking = true

        func closeRun() {
            if inking, current.points.count > 1 { result.append(current) }
            current = ([], [])
        }

        for i in 1..<outline.count {
            var from = outline[i - 1]
            let to = outline[i]
            var remaining = distance(from, to)
            while remaining > 0 {
                let target = (inking ? dash : gap) - drawn
                if remaining < target {
                    drawn += remaining
                    if inking {
                        current.points.append(to)
                        current.flags.append(isCorner[i])
                    }
                    remaining = 0
                } else {
                    // The run ends part-way along this segment.
                    let t = target / remaining
                    let cut = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
                    if inking {
                        current.points.append(cut)
                        current.flags.append(false)
                        closeRun()
                    } else {
                        current = ([cut], [false])
                    }
                    inking.toggle()
                    drawn = 0
                    remaining -= target
                    from = cut
                }
            }
        }
        closeRun()
        return result
    }

    /// Pads a polyline's control points so the B-spline actually reaches
    /// its ends: an open path pins its endpoints by tripling them, a closed
    /// curve wraps two points past the join instead (pinning a closed curve
    /// would put a visible kink where it meets itself).
    private static func padded(_ points: [CGPoint], isCorner: [Bool], closed: Bool)
        -> (points: [CGPoint], flags: [Bool]) {
        guard points.count > 1 else { return (points, isCorner) }
        var result = points
        var flags = isCorner
        if closed, !isCorner.contains(true) {
            for offset in 1...min(2, points.count - 1) {
                result.append(points[offset])
                flags.append(false)
            }
            return (result, flags)
        }
        if !flags[0] {
            result.insert(contentsOf: [points[0], points[0]], at: 0)
            flags.insert(contentsOf: [false, false], at: 0)
        }
        if !(flags.last ?? false) {
            result.append(contentsOf: [points[points.count - 1], points[points.count - 1]])
            flags.append(contentsOf: [false, false])
        }
        return (result, flags)
    }

    private static func buildStroke(_ points: [CGPoint], isCorner: [Bool], spec: InkSpec) -> PKStroke {
        var controlPoints: [CGPoint] = []
        controlPoints.reserveCapacity(points.count * 3)
        for (index, point) in points.enumerated() {
            controlPoints.append(point)
            if isCorner[index] {
                // Multiplicity three: a sharp vertex in a cubic B-spline.
                controlPoints.append(point)
                controlPoints.append(point)
            }
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
                size: CGSize(width: spec.size, height: spec.size),
                opacity: spec.opacity,
                force: spec.force,
                azimuth: spec.azimuth,
                altitude: spec.altitude
            ))
        }
        let path = PKStrokePath(controlPoints: strokePoints, creationDate: Date())
        return PKStroke(ink: spec.ink, path: path)
    }

    // MARK: - Classification

    /// An open path is a line if it fits one, whatever corners the turning
    /// angle found - a slightly shaky hand puts a "corner" in the middle of
    /// a perfectly good line, and sending that to the arrow recognizer is
    /// how a line became an arrow.
    private static func recognizeOpen(_ points: [CGPoint], length: CGFloat) -> RecognizedShape? {
        if let line = recognizeLine(points) { return line }
        let corners = cornerIndices(points, closed: false)
        guard !corners.isEmpty else { return nil }
        return recognizeArrow(points, corners: corners, length: length)
    }

    private static func recognizeLine(_ points: [CGPoint]) -> RecognizedShape? {
        let start = points[0], end = points[points.count - 1]
        let chord = distance(start, end)
        guard chord > 0 else { return nil }
        let deviation = points.map { distanceFromSegment($0, start, end) }.max() ?? 0
        guard deviation / chord < lineDeviation else { return nil }
        let snapped = axisSnapped(from: start, to: end)
        return RecognizedShape(kind: .line, outline: [snapped.0, snapped.1], cornerIndices: [0, 1])
    }

    /// Straightens a segment onto the nearest axis (or 45° diagonal) when
    /// it is already within a few degrees of it, keeping its midpoint and
    /// its length - so a near-horizontal line comes out horizontal without
    /// either end jumping.
    static func axisSnapped(from a: CGPoint, to b: CGPoint) -> (CGPoint, CGPoint) {
        let length = distance(a, b)
        guard length > 0 else { return (a, b) }
        let angle = atan2(b.y - a.y, b.x - a.x)

        var snapped: CGFloat?
        for step in 0..<8 {
            let candidate = CGFloat(step) * .pi / 4 - .pi
            // Both directions of the same axis are equally good; compare
            // against every multiple of 45° over the full turn.
            let delta = abs(angleDifference(angle, candidate))
            let isAxis = step % 2 == 0
            if delta < (isAxis ? lineAxisTolerance : lineDiagonalTolerance) {
                snapped = candidate
                break
            }
        }
        guard let theta = snapped else { return (a, b) }
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let half = length / 2
        return (
            CGPoint(x: mid.x - cos(theta) * half, y: mid.y - sin(theta) * half),
            CGPoint(x: mid.x + cos(theta) * half, y: mid.y + sin(theta) * half)
        )
    }

    /// An arrow drawn in one stroke: a straight shaft, then a head at the
    /// far end that **doubles back** along it. That last part is what makes
    /// this strict - a wobble near the end of a line produces a corner and
    /// a "head" that carries straight on, and the old version manufactured
    /// barbs for it out of a floor value. A head has to come back toward
    /// the tail, and be a real fraction of the shaft, or this is not an
    /// arrow.
    private static func recognizeArrow(_ points: [CGPoint], corners: [Int], length: CGFloat) -> RecognizedShape? {
        guard (1...3).contains(corners.count) else { return nil }
        let firstCorner = corners[0]
        // The shaft: start to the first corner, straight, at least half.
        let tail = points[0]
        let shaftEnd = points[firstCorner]
        let shaftLength = distance(tail, shaftEnd)
        guard shaftLength > length * 0.45 else { return nil }
        let shaftDeviation = points[0...firstCorner].map { distanceFromSegment($0, tail, shaftEnd) }.max() ?? 0
        guard shaftDeviation / shaftLength < lineDeviation * 1.5 else { return nil }

        // The head is everything after the shaft. Its tip is the point
        // farthest along the shaft's direction.
        let head = Array(points[firstCorner...])
        guard head.count > 2 else { return nil }
        let direction = normalized(CGVector(dx: shaftEnd.x - tail.x, dy: shaftEnd.y - tail.y))
        guard let tip = head.max(by: {
            projection($0, from: tail, along: direction) < projection($1, from: tail, along: direction)
        }) else { return nil }

        // Measured, never floored: how far the head strays from the tip,
        // and how far back along the shaft it comes.
        let barbLength = head.map { distance($0, tip) }.max() ?? 0
        let tipProjection = projection(tip, from: tail, along: direction)
        let backtrack = tipProjection - (head.map { projection($0, from: tail, along: direction) }.min() ?? tipProjection)
        guard barbLength > shaftLength * 0.1,        // a real head, not a wobble
              barbLength < shaftLength * 0.6,        // ...and not a second line
              backtrack > shaftLength * 0.06         // it comes back on itself
        else { return nil }

        // The shaft gets the same axis snap a line does, and the head is
        // rebuilt around the snapped tip so the arrow stays straight.
        let snapped = axisSnapped(from: tail, to: tip)
        let snappedTail = snapped.0, snappedTip = snapped.1
        let snappedDirection = normalized(CGVector(dx: snappedTip.x - snappedTail.x, dy: snappedTip.y - snappedTail.y))

        let barbAngle: CGFloat = 30 * .pi / 180
        let back = CGVector(dx: -snappedDirection.dx, dy: -snappedDirection.dy)
        let left = rotate(back, by: barbAngle)
        let right = rotate(back, by: -barbAngle)
        let leftBarb = CGPoint(x: snappedTip.x + left.dx * barbLength, y: snappedTip.y + left.dy * barbLength)
        let rightBarb = CGPoint(x: snappedTip.x + right.dx * barbLength, y: snappedTip.y + right.dy * barbLength)
        // Drawn as one stroke: shaft to the tip, out one barb, back to the
        // tip, out the other. Every vertex is a corner.
        let outline = [snappedTail, snappedTip, leftBarb, snappedTip, rightBarb]
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
        // The axes come from how the points spread (their principal axes),
        // not from an upright box: a tilted ellipse used to fail the
        // residual gate or come out as a polygon. Within the axis tolerance
        // of upright it snaps upright, as lines do.
        let n = CGFloat(points.count)
        let mean = CGPoint(x: points.reduce(0) { $0 + $1.x } / n, y: points.reduce(0) { $0 + $1.y } / n)
        var sxx: CGFloat = 0, syy: CGFloat = 0, sxy: CGFloat = 0
        for p in points {
            let dx = p.x - mean.x, dy = p.y - mean.y
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
        }
        var tilt = 0.5 * atan2(2 * sxy, sxx - syy)
        let nearestAxis = (tilt / (.pi / 2)).rounded() * (.pi / 2)
        if abs(tilt - nearestAxis) < axisSnapTolerance { tilt = nearestAxis }
        let c = cos(tilt), s = sin(tilt)
        // Into the ellipse's own frame, and back out.
        let local = points.map { p in
            CGPoint(x: (p.x - mean.x) * c + (p.y - mean.y) * s, y: -(p.x - mean.x) * s + (p.y - mean.y) * c)
        }
        let world = { (q: CGPoint) in CGPoint(x: mean.x + q.x * c - q.y * s, y: mean.y + q.x * s + q.y * c) }

        let bounds = boundingBox(local)
        let rx = bounds.width / 2, ry = bounds.height / 2
        guard rx > 2, ry > 2 else { return nil }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let residual = local.reduce(CGFloat(0)) { sum, p in
            let nx = (p.x - center.x) / rx, ny = (p.y - center.y) / ry
            return sum + abs(nx * nx + ny * ny - 1)
        } / CGFloat(local.count)
        guard residual < ellipseResidual else { return nil }

        let isCircle = abs(rx - ry) / max(rx, ry) < circleTolerance
        let r = (rx + ry) / 2
        let radiusX = isCircle ? r : rx
        let radiusY = isCircle ? r : ry
        // Start the outline where the pencil started, so the snapped shape
        // doesn't visibly rotate away from the freehand one.
        let startAngle = atan2((local[0].y - center.y) / radiusY, (local[0].x - center.x) / radiusX)
        let samples = 72
        let outline = (0...samples).map { i -> CGPoint in
            let angle = startAngle + (CGFloat(i) / CGFloat(samples)) * 2 * .pi
            return world(CGPoint(x: center.x + radiusX * cos(angle), y: center.y + radiusY * sin(angle)))
        }
        return RecognizedShape(kind: isCircle ? .circle : .ellipse, outline: outline,
                               cornerIndices: [], isClosed: true)
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
        return RecognizedShape(kind: kind, outline: outline,
                               cornerIndices: Array(outline.indices), isClosed: true)
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

    /// Signed difference between two angles, wrapped into (-π, π].
    private static func angleDifference(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        var delta = a - b
        while delta > .pi { delta -= 2 * .pi }
        while delta <= -.pi { delta += 2 * .pi }
        return delta
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
