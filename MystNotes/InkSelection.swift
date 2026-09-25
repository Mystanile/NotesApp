import Foundation
import CoreGraphics
#if targetEnvironment(macCatalyst) || canImport(UIKit)
import PencilKit
import UIKit

/// The lasso, as arithmetic: which strokes a loop takes, and what moving,
/// resizing and rotating them does to a drawing. Pure functions on
/// `PKDrawing`, so they're testable without a canvas;
/// `InkSelectionController` drives them from the gestures.
///
/// Why this exists: PencilKit's own `PKLassoTool` can select and move, but
/// never says *which* strokes it holds, so there was no way to put a pinch
/// on the selection. This one is ours end to end.
///
/// A move, resize or rotate is folded into each stroke's `transform`, never
/// into its points. Stroke identity is `creationDate + randomSeed` (see
/// `StrokeIDMap`, which ignores the transform on purpose), so a stroke that
/// has been dragged across the page or doubled in size is still the same
/// stroke to every link, timeline event and cloze that points at it
/// (invariant 6), and the neutral record stores the full affine.
nonisolated enum InkSelection {

    // MARK: Selecting

    /// The strokes a lasso loop takes: those with more than half their
    /// length inside it. A stroke merely clipped by the loop stays put,
    /// which is what a hand drawing a loop around a word means.
    static func strokeIndices(of drawing: PKDrawing, insideLasso lasso: [CGPoint]) -> [Int] {
        guard lasso.count >= 3 else { return [] }
        let loop = CGMutablePath()
        loop.addLines(between: lasso)
        loop.closeSubpath()
        return drawing.strokes.indices.filter { index in
            let points = sampledPoints(of: drawing.strokes[index], spacing: 4)
            guard !points.isEmpty else { return false }
            let inside = points.filter { loop.contains($0, using: .evenOdd) }.count
            return inside * 2 > points.count
        }
    }

    /// The union of the strokes' rendered bounds, in page points.
    static func bounds(of drawing: PKDrawing, indices: [Int]) -> CGRect {
        indices.reduce(CGRect.null) { $0.union(drawing.strokes[$1].renderBounds) }
    }

    static func strokes(of drawing: PKDrawing, indices: [Int]) -> [PKStroke] {
        indices.map { drawing.strokes[$0] }
    }

    // MARK: Changing

    /// The same drawing with `transform` applied on top of whatever
    /// transform the selected strokes already carry.
    static func transforming(_ drawing: PKDrawing, indices: [Int], by transform: CGAffineTransform) -> PKDrawing {
        guard !transform.isIdentity else { return drawing }
        var strokes = drawing.strokes
        for index in indices {
            strokes[index].transform = strokes[index].transform.concatenating(transform)
        }
        return PKDrawing(strokes: strokes)
    }

    static func removing(_ drawing: PKDrawing, indices: [Int]) -> PKDrawing {
        let removed = Set(indices)
        return PKDrawing(strokes: drawing.strokes.enumerated().compactMap { removed.contains($0.offset) ? nil : $0.element })
    }

    /// Appends `strokes` and says where they landed.
    static func appending(_ strokes: [PKStroke], to drawing: PKDrawing) -> (drawing: PKDrawing, indices: [Int]) {
        let start = drawing.strokes.count
        return (PKDrawing(strokes: drawing.strokes + strokes), Array(start..<(start + strokes.count)))
    }

    /// Copies with an identity of their own. A duplicate or a paste must
    /// not share a fingerprint with the stroke it came from - or with each
    /// other - so each gets a fresh `creationDate`, a millisecond apart.
    static func reidentified(_ strokes: [PKStroke], at date: Date = Date()) -> [PKStroke] {
        strokes.enumerated().map { offset, stroke in
            let path = PKStrokePath(controlPoints: Array(stroke.path),
                                    creationDate: date.addingTimeInterval(Double(offset) * 0.001))
            return PKStroke(ink: stroke.ink, path: path, transform: stroke.transform,
                            mask: stroke.mask, randomSeed: stroke.randomSeed)
        }
    }

    /// One gesture step: scale and rotate about `center`, then move by
    /// `translation`. Composed so the pinch and twist happen where the
    /// fingers are - around the selection - not around the page origin.
    static func transform(translation: CGPoint = .zero, scale: CGFloat = 1, rotation: CGFloat = 0,
                          about center: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(rotationAngle: rotation))
            .concatenating(CGAffineTransform(translationX: center.x + translation.x, y: center.y + translation.y))
    }

    /// The four corners of `rect`, top-left first, clockwise.
    static func corners(of rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }

    static func center(of corners: [CGPoint]) -> CGPoint {
        guard !corners.isEmpty else { return .zero }
        let sum = corners.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(corners.count), y: sum.y / CGFloat(corners.count))
    }

    /// Whether `point` is inside the (possibly rotated) box.
    static func polygon(_ corners: [CGPoint], contains point: CGPoint) -> Bool {
        guard corners.count >= 3 else { return false }
        let path = CGMutablePath()
        path.addLines(between: corners)
        path.closeSubpath()
        return path.contains(point, using: .evenOdd)
    }

    // MARK: Pasteboard

    /// Ink travels between pages (and notebooks) as PencilKit's own
    /// archive under a type of ours, so a paste of ink is never mistaken
    /// for a paste of a picture and vice versa.
    static let pasteboardType = "com.mozynas.mystnotes.ink"

    static func pasteboardData(for strokes: [PKStroke]) -> Data {
        PKDrawing(strokes: strokes).dataRepresentation()
    }

    static func strokes(fromPasteboardData data: Data) -> [PKStroke]? {
        (try? PKDrawing(data: data))?.strokes
    }

    // MARK: Sampling

    /// Points along the stroke as drawn on the page - its transform
    /// applied - every `spacing` points, so a long stroke and a short one
    /// are judged by the same yardstick.
    static func sampledPoints(of stroke: PKStroke, spacing: CGFloat) -> [CGPoint] {
        var points = stroke.path.interpolatedPoints(by: .distance(spacing)).map { $0.location }
        if points.isEmpty {
            points = stroke.path.map { $0.location }
        }
        guard !stroke.transform.isIdentity else { return points }
        return points.map { $0.applying(stroke.transform) }
    }
}
#endif
