import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
import PencilKit

/// Bucket/flood fill for the drawing toolbar's Fill tool, like Microsoft
/// Paint's fill bucket. PKStrokes are vector paths, not filled regions, so
/// there's no native "fill this enclosed area" primitive in PencilKit -
/// this rasterizes the current ink, flood-fills the empty region containing
/// the tapped point (bounded by existing strokes, spilling to the whole
/// canvas if nothing encloses it - exactly like Paint), then synthesizes
/// the result as a dense stack of short horizontal PKStrokes, so a fill is
/// a real, editable/erasable part of the PKDrawing rather than a separate
/// image layer bolted on beside it.
enum FillTool {
    private static let alphaThreshold: UInt8 = 20
    private static let maxFillRows = 4000

    /// `point` and `canvasSize` must be in the same coordinate space as
    /// `drawing` itself (i.e. the PKCanvasView's own local coordinates) -
    /// for the app's "paged" pages that's identical to the SwiftUI overlay
    /// that captures the tap, so callers there can pass the tap location
    /// straight through with no conversion.
    static func fill(_ drawing: PKDrawing, in canvasSize: CGSize, at point: CGPoint, color: UIColor) -> PKDrawing? {
        guard canvasSize.width > 1, canvasSize.height > 1 else { return nil }
        let width = Int(canvasSize.width.rounded(.up))
        let height = Int(canvasSize.height.rounded(.up))

        let inkImage = drawing.image(from: CGRect(origin: .zero, size: canvasSize), scale: 1)
        guard let cgImage = inkImage.cgImage, let alpha = alphaMap(of: cgImage, width: width, height: height) else {
            return nil
        }

        let startX = Int(point.x), startY = Int(point.y)
        guard startX >= 0, startX < width, startY >= 0, startY < height else { return nil }
        guard alpha[startY * width + startX] <= alphaThreshold else { return nil } // tapped directly on ink

        let spans = scanlineFloodFill(alpha: alpha, width: width, height: height, startX: startX, startY: startY)
        guard !spans.isEmpty else { return nil }

        let strokeWidth: CGFloat = 1.4
        let fillStrokes = spans.map {
            horizontalStroke(fromX: CGFloat($0.minX), toX: CGFloat($0.maxX + 1), y: CGFloat($0.y) + 0.5, color: color, width: strokeWidth)
        }

        return PKDrawing(strokes: drawing.strokes + fillStrokes)
    }

    // MARK: - Rasterizing

    private static func alphaMap(of cgImage: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var alpha = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            alpha[i] = pixels[i * 4 + 3]
        }
        return alpha
    }

    // MARK: - Scanline flood fill

    /// Classic stack-based scanline fill: for each seed, grows the widest
    /// contiguous empty run through it on that row, records it as one span,
    /// then seeds the rows above/below. Bounded by `maxFillRows` so an
    /// effectively-unbounded fill (tapping open space with nothing around
    /// it) can't run away on a very large canvas.
    private static func scanlineFloodFill(alpha: [UInt8], width: Int, height: Int, startX: Int, startY: Int) -> [(y: Int, minX: Int, maxX: Int)] {
        func isEmpty(_ x: Int, _ y: Int) -> Bool { alpha[y * width + x] <= alphaThreshold }

        var visited = [Bool](repeating: false, count: width * height)
        var spans: [(y: Int, minX: Int, maxX: Int)] = []
        var stack: [(Int, Int)] = [(startX, startY)]

        while let (x, y) = stack.popLast() {
            let idx = y * width + x
            if visited[idx] || !isEmpty(x, y) { continue }

            var minX = x
            while minX > 0, !visited[y * width + (minX - 1)], isEmpty(minX - 1, y) { minX -= 1 }
            var maxX = x
            while maxX < width - 1, !visited[y * width + (maxX + 1)], isEmpty(maxX + 1, y) { maxX += 1 }
            for xi in minX...maxX { visited[y * width + xi] = true }
            spans.append((y: y, minX: minX, maxX: maxX))
            if spans.count > maxFillRows { break }

            if y > 0 {
                for xi in minX...maxX where !visited[(y - 1) * width + xi] && isEmpty(xi, y - 1) {
                    stack.append((xi, y - 1))
                }
            }
            if y < height - 1 {
                for xi in minX...maxX where !visited[(y + 1) * width + xi] && isEmpty(xi, y + 1) {
                    stack.append((xi, y + 1))
                }
            }
        }
        return spans
    }

    // MARK: - Stroke synthesis

    private static func horizontalStroke(fromX: CGFloat, toX: CGFloat, y: CGFloat, color: UIColor, width: CGFloat) -> PKStroke {
        let points = [
            PKStrokePoint(location: CGPoint(x: fromX, y: y), timeOffset: 0, size: CGSize(width: width, height: width), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2),
            PKStrokePoint(location: CGPoint(x: toX, y: y), timeOffset: 0.02, size: CGSize(width: width, height: width), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        ]
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        return PKStroke(ink: PKInk(.pen, color: color), path: path)
    }
}
#endif
