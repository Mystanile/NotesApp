import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
import PencilKit

/// Bucket/flood fill for the drawing toolbar's Fill tool. PKStrokes are
/// vector paths, not filled regions, so there's no native "fill this
/// enclosed area" primitive in PencilKit - this rasterizes the current ink,
/// flood-fills the empty region containing the tapped point (bounded by
/// existing strokes, spilling to the whole canvas if nothing encloses it),
/// then synthesizes the result as horizontal PKStrokes, so a fill is a
/// real, editable/erasable part of the PKDrawing rather than a separate
/// image layer bolted on beside it.
enum FillTool {
    private static let alphaThreshold: UInt8 = 20

    /// Merged bands are capped at this many rows. A PencilKit stroke also
    /// extends roughly `size` past each endpoint along its own direction,
    /// so unbounded band heights would bleed far outside the filled region
    /// horizontally; capping keeps that overshoot small and correctable.
    private static let maxBandHeight = 8

    /// `point` and `canvasSize` must be in the same coordinate space as
    /// `drawing` itself (i.e. the PKCanvasView's own local coordinates) -
    /// for the app's "paged" pages that's identical to the SwiftUI overlay
    /// that captures the tap, so callers there can pass the tap location
    /// straight through with no conversion.
    ///
    /// Runs the raster + flood-fill work off the main actor; a page-sized
    /// fill touches ~1M pixels and shouldn't block drawing.
    static func fill(_ drawing: PKDrawing, in canvasSize: CGSize, at point: CGPoint, color: UIColor) async -> PKDrawing? {
        guard canvasSize.width > 1, canvasSize.height > 1 else { return nil }
        let width = Int(canvasSize.width.rounded(.up))
        let height = Int(canvasSize.height.rounded(.up))

        let startX = Int(point.x), startY = Int(point.y)
        guard startX >= 0, startX < width, startY >= 0, startY < height else { return nil }

        // Render the existing ink so the fill can be bounded by it. Force
        // the light trait collection: PencilKit inverts ink colors in dark
        // mode, and while that doesn't change alpha today, pinning it keeps
        // this independent of appearance either way.
        var renderedInk: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            renderedInk = drawing.image(from: CGRect(origin: .zero, size: canvasSize), scale: 1)
        }
        guard let cgImage = renderedInk?.cgImage else { return nil }

        let existingStrokes = drawing.strokes
        return await Task.detached(priority: .userInitiated) { () -> PKDrawing? in
            guard let alpha = alphaMap(of: cgImage, width: width, height: height) else { return nil }
            guard alpha[startY * width + startX] <= alphaThreshold else { return nil } // tapped directly on ink

            let spans = scanlineFloodFill(alpha: alpha, width: width, height: height, startX: startX, startY: startY)
            guard !spans.isEmpty else { return nil }

            let fillStrokes = strokes(for: spans, color: color)
            guard !fillStrokes.isEmpty else { return nil }
            return PKDrawing(strokes: existingStrokes + fillStrokes)
        }.value
    }

    // MARK: - Rasterizing

    private static func alphaMap(of cgImage: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        // The buffer pointer must stay valid for as long as the CGContext
        // uses it - constructing the context with `&pixels` and drawing into
        // it afterwards is undefined behaviour (the pointer is only
        // guaranteed for the duration of that one call), and in practice
        // leaves the pixel buffer untouched. Then every pixel reads as
        // fully transparent, the fill isn't bounded by any ink, and it
        // floods the entire canvas instead of the tapped region. Keep all
        // context use inside the closure.
        let drew: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }

        var alpha = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            alpha[i] = pixels[i * 4 + 3]
        }
        return alpha
    }

    // MARK: - Scanline flood fill

    /// Standard stack-based scanline fill. For each seed it grows the widest
    /// contiguous empty run through that point, records it as one span, then
    /// seeds the rows above/below - pushing only the *start of each
    /// contiguous run* rather than every pixel, which is what keeps the
    /// stack small (per-pixel seeding peaks in the hundreds of thousands on
    /// a page-sized fill).
    private static func scanlineFloodFill(alpha: [UInt8], width: Int, height: Int, startX: Int, startY: Int) -> [(y: Int, minX: Int, maxX: Int)] {
        var visited = [Bool](repeating: false, count: width * height)
        var spans: [(y: Int, minX: Int, maxX: Int)] = []
        var stack: [(Int, Int)] = [(startX, startY)]

        func isOpen(_ x: Int, _ y: Int) -> Bool {
            let i = y * width + x
            return !visited[i] && alpha[i] <= alphaThreshold
        }

        while let (x, y) = stack.popLast() {
            guard isOpen(x, y) else { continue }

            var minX = x
            while minX > 0, isOpen(minX - 1, y) { minX -= 1 }
            var maxX = x
            while maxX < width - 1, isOpen(maxX + 1, y) { maxX += 1 }
            for xi in minX...maxX { visited[y * width + xi] = true }
            spans.append((y: y, minX: minX, maxX: maxX))

            for neighborY in [y - 1, y + 1] where neighborY >= 0 && neighborY < height {
                var xi = minX
                while xi <= maxX {
                    while xi <= maxX, !isOpen(xi, neighborY) { xi += 1 }
                    guard xi <= maxX else { break }
                    stack.append((xi, neighborY))                 // start of this run only
                    while xi <= maxX, isOpen(xi, neighborY) { xi += 1 }
                }
            }
        }
        return spans
    }

    // MARK: - Stroke synthesis

    /// Merges vertically adjacent spans that cover the same x-range into a
    /// single thicker stroke - a rectangular region collapses from hundreds
    /// of hairlines into a handful of bands, while curved edges naturally
    /// stay fine-grained where the span width changes row to row.
    private static func strokes(for spans: [(y: Int, minX: Int, maxX: Int)], color: UIColor) -> [PKStroke] {
        let sorted = spans.sorted { $0.y < $1.y }
        var result: [PKStroke] = []

        var bandStart = 0
        while bandStart < sorted.count {
            let first = sorted[bandStart]
            var bandEnd = bandStart
            while bandEnd + 1 < sorted.count,
                  sorted[bandEnd + 1].y == sorted[bandEnd].y + 1,
                  sorted[bandEnd + 1].minX == first.minX,
                  sorted[bandEnd + 1].maxX == first.maxX,
                  (bandEnd - bandStart + 1) < maxBandHeight {
                bandEnd += 1
            }

            let bandHeight = CGFloat(sorted[bandEnd].y - first.y + 1)
            let centerY = CGFloat(first.y) + bandHeight / 2
            // A stroke renders roughly 2x its point size thick.
            let size = max(bandHeight / 2, 0.75)
            // ...and extends about `size` past each endpoint along its own
            // direction, so pull the ends in to stay inside the region.
            let spanWidth = CGFloat(first.maxX - first.minX + 1)
            let inset = min(size, spanWidth / 2)
            let fromX = CGFloat(first.minX) + inset
            let toX = CGFloat(first.maxX + 1) - inset

            result.append(horizontalStroke(fromX: fromX, toX: max(toX, fromX), y: centerY, size: size, color: color))
            bandStart = bandEnd + 1
        }
        return result
    }

    private static func horizontalStroke(fromX: CGFloat, toX: CGFloat, y: CGFloat, size: CGFloat, color: UIColor) -> PKStroke {
        var points: [PKStrokePoint] = []
        for i in 0..<4 {
            let t = CGFloat(i) / 3
            points.append(PKStrokePoint(
                location: CGPoint(x: fromX + (toX - fromX) * t, y: y),
                timeOffset: Double(i) * 0.01,
                size: CGSize(width: size, height: size),
                opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
            ))
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        return PKStroke(ink: PKInk(.pen, color: color), path: path)
    }
}
#endif
