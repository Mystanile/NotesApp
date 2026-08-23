import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif
import PencilKit

/// Converts a freehand set of points into a clean geometric PKStroke: a
/// straight line, a rectangle, or an ellipse — based on simple heuristics
/// on the raw path. Not a general-purpose shape classifier (no triangles,
/// arrows, etc. yet), but covers the most common "clean up my messy line/
/// box/circle" cases GoodNotes' shape tool is used for.
enum ShapeRecognizer {

    static func recognizeStroke(from rawPoints: [CGPoint], ink: PKInk = PKInk(.pen, color: .black)) -> PKStroke? {
        guard rawPoints.count > 2 else { return nil }

        let bounds = boundingBox(of: rawPoints)
        guard bounds.width > 4 || bounds.height > 4 else { return nil } // too small to be intentional

        let start = rawPoints.first!
        let end = rawPoints.last!
        let closingDistance = distance(start, end)
        let diagonal = sqrt(bounds.width * bounds.width + bounds.height * bounds.height)
        let isClosedShape = closingDistance < max(diagonal * 0.18, 20)

        let idealPoints: [CGPoint]

        if isClosedShape {
            if isRoughlyCircular(rawPoints, bounds: bounds) {
                idealPoints = ellipsePoints(in: bounds, samples: 72)
            } else {
                idealPoints = rectanglePoints(in: bounds)
            }
        } else {
            idealPoints = [start, end] // straighten to a clean line
        }

        return buildStroke(from: idealPoints, ink: ink)
    }

    // MARK: - Heuristics

    private static func boundingBox(of points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2))
    }

    /// Roughly circular if every point's distance from the centroid stays
    /// close to the average radius (low variance) — a hand-drawn oval keeps
    /// a fairly consistent radius, while a rectangle's corners sit much
    /// farther from center than its edge midpoints do.
    private static func isRoughlyCircular(_ points: [CGPoint], bounds: CGRect) -> Bool {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radii = points.map { distance($0, center) }
        guard !radii.isEmpty else { return false }
        let avgRadius = radii.reduce(0, +) / CGFloat(radii.count)
        guard avgRadius > 0 else { return false }
        let variance = radii.reduce(0) { $0 + pow($1 - avgRadius, 2) } / CGFloat(radii.count)
        let stdDev = sqrt(variance)
        return (stdDev / avgRadius) < 0.28 // fairly consistent radius = roughly round
    }

    // MARK: - Ideal shape point generators

    private static func rectanglePoints(in rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.minY)
        ]
    }

    private static func ellipsePoints(in rect: CGRect, samples: Int) -> [CGPoint] {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let rx = rect.width / 2
        let ry = rect.height / 2
        return (0...samples).map { i in
            let angle = (CGFloat(i) / CGFloat(samples)) * 2 * .pi
            return CGPoint(x: center.x + rx * cos(angle), y: center.y + ry * sin(angle))
        }
    }

    // MARK: - PKStroke construction

    private static func buildStroke(from points: [CGPoint], ink: PKInk) -> PKStroke? {
        guard points.count > 1 else { return nil }

        let creationDate = Date()
        var strokePoints: [PKStrokePoint] = []
        var timeOffset: TimeInterval = 0

        for (index, point) in points.enumerated() {
            if index > 0 {
                let prev = points[index - 1]
                timeOffset += Double(distance(prev, point)) * 0.002 // arbitrary pacing
            }
            strokePoints.append(
                PKStrokePoint(
                    location: point,
                    timeOffset: timeOffset,
                    size: CGSize(width: 4, height: 4),
                    opacity: 1,
                    force: 1,
                    azimuth: 0,
                    altitude: .pi / 2
                )
            )
        }

        let path = PKStrokePath(controlPoints: strokePoints, creationDate: creationDate)
        return PKStroke(ink: ink, path: path)
    }
}
