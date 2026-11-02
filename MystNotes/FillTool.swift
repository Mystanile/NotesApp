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

    /// Rows per pass of the fill's stroke, and its point size. Measured
    /// (Sept 25, 2026): PencilKit draws *nothing* for a stroke under ~2pt,
    /// a 4pt stroke is solid for ~4px, and it runs ~size/2 past each end.
    /// So passes are 2 rows apart at 4pt - only solid centres overlap,
    /// never two soft edges, which read as faint lines. The fill used to
    /// size each band from its own height, and a one-row band came out at
    /// 0.75pt: an ellipse filled as a few lines across its middle.
    private static let bandRows = 2

    /// How far the fill runs on under its outline, in pixels of the 1pt
    /// alpha map - into ink only, so never through a line. The map is
    /// coarse: a line's faint anti-aliased edge tips one more pixel over
    /// `alphaThreshold`, the region stops a whole point short of the
    /// line, and a thin line (a snapped shape at force 0.858, Sept 25,
    /// 2026) doesn't cover that point - a white line down the sides. The
    /// fill is under the ink, so what it covers of the line never shows.
    private static let growPixels = 2
    private static let strokeSize: CGFloat = 4

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

            let flooded = scanlineFloodFill(alpha: alpha, width: width, height: height, startX: startX, startY: startY)
            let spans = growUnderInk(flooded, alpha: alpha, width: width, height: height)
            guard !spans.isEmpty else { return nil }

            let fillStrokes = strokes(for: spans, color: color)
            guard !fillStrokes.isEmpty else { return nil }
            // Under the ink, like paint under a line: the band edges that
            // run a pixel or two past the region sit beneath its outline.
            return PKDrawing(strokes: fillStrokes + existingStrokes)
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

    /// The flooded region grown `growPixels` steps into neighbouring ink
    /// pixels (4-connected), like an image editor's "Expand" but confined
    /// to ink: an open pixel the flood didn't reach is outside the region,
    /// so it is never taken, and a line thinner than the grow still holds.
    private static func growUnderInk(_ spans: [(y: Int, minX: Int, maxX: Int)], alpha: [UInt8],
                                     width: Int, height: Int) -> [(y: Int, minX: Int, maxX: Int)] {
        guard let top = spans.map(\.y).min(), let bottom = spans.map(\.y).max(),
              let left = spans.map(\.minX).min(), let right = spans.map(\.maxX).max() else { return spans }
        var mask = [Bool](repeating: false, count: width * height)
        for span in spans { for x in span.minX...span.maxX { mask[span.y * width + x] = true } }

        let ys = max(top - growPixels, 0)...min(bottom + growPixels, height - 1)
        let xs = max(left - growPixels, 0)...min(right + growPixels, width - 1)
        for _ in 0..<growPixels {
            var grown: [Int] = []
            for y in ys {
                for x in xs {
                    let i = y * width + x
                    guard !mask[i], alpha[i] > alphaThreshold else { continue }
                    if (x > 0 && mask[i - 1]) || (x < width - 1 && mask[i + 1])
                        || (y > 0 && mask[i - width]) || (y < height - 1 && mask[i + width]) {
                        grown.append(i)
                    }
                }
            }
            for i in grown { mask[i] = true }
        }

        var result: [(y: Int, minX: Int, maxX: Int)] = []
        for y in ys {
            var x = xs.lowerBound
            while x <= xs.upperBound {
                guard mask[y * width + x] else { x += 1; continue }
                let start = x
                while x <= xs.upperBound, mask[y * width + x] { x += 1 }
                result.append((y: y, minX: start, maxX: x - 1))
            }
        }
        return result
    }

    // MARK: - Stroke synthesis

    /// One zig-zag stroke per branch of the region, so the precise eraser
    /// takes a fill in one touch. Each band (`bandRows` rows, its spans
    /// merged where they overlap) is one pass along the band's centre,
    /// alternating direction; a pass links to the next band's first unused
    /// run that overlaps it in x. A run with nothing below it, or a run
    /// already taken by another branch, starts a new stroke - so a U is a
    /// few strokes and a convex shape exactly one. The ends are pulled in
    /// by the stroke's own overshoot so it stays inside the run.
    private static func strokes(for spans: [(y: Int, minX: Int, maxX: Int)], color: UIColor) -> [PKStroke] {
        let byRow = Dictionary(grouping: spans, by: \.y)
        guard let top = byRow.keys.min(), let bottom = byRow.keys.max() else { return [] }

        typealias Run = (minX: Int, maxX: Int)
        let bands: [(centerY: CGFloat, runs: [Run])] = stride(from: top, through: bottom, by: bandRows).map { bandTop in
            let rows = bandTop..<min(bandTop + bandRows, bottom + 1)
            return (CGFloat(rows.lowerBound + rows.upperBound) / 2, mergedRuns(rows.flatMap { byRow[$0] ?? [] }))
        }
        var used = bands.map { [Bool](repeating: false, count: $0.runs.count) }

        var result: [PKStroke] = []
        // A millisecond apart, so no two fill strokes share an identity.
        let base = Date()
        for (startBand, band) in bands.enumerated() {
            for startRun in band.runs.indices where !used[startBand][startRun] {
                var passes: [(y: CGFloat, run: Run)] = []
                var bandIndex = startBand, runIndex: Int? = startRun
                while let index = runIndex {
                    used[bandIndex][index] = true
                    let run = bands[bandIndex].runs[index]
                    passes.append((bands[bandIndex].centerY, run))
                    bandIndex += 1
                    guard bandIndex < bands.count else { break }
                    runIndex = bands[bandIndex].runs.indices.first { next in
                        let candidate = bands[bandIndex].runs[next]
                        return !used[bandIndex][next] && candidate.minX <= run.maxX && candidate.maxX >= run.minX
                    }
                }
                result.append(zigzagStroke(passes, color: color, date: base.addingTimeInterval(Double(result.count) * 0.001)))
            }
        }
        return result
    }

    /// Overlapping or touching x-ranges folded into one.
    private static func mergedRuns(_ spans: [(y: Int, minX: Int, maxX: Int)]) -> [(minX: Int, maxX: Int)] {
        var runs: [(minX: Int, maxX: Int)] = []
        for span in spans.sorted(by: { $0.minX < $1.minX }) {
            if let last = runs.last, span.minX <= last.maxX + 1 {
                runs[runs.count - 1].maxX = max(last.maxX, span.maxX)
            } else {
                runs.append((span.minX, span.maxX))
            }
        }
        return runs
    }

    /// Every pass end is a sharp corner: a cubic B-spline only passes
    /// through a control point repeated three times (as in
    /// `ShapeRecognizer`), and between two such points it is a straight
    /// line - so each pass is straight and each turn is exact.
    private static func zigzagStroke(_ passes: [(y: CGFloat, run: (minX: Int, maxX: Int))], color: UIColor, date: Date) -> PKStroke {
        var points: [PKStrokePoint] = []
        func add(_ location: CGPoint) {
            for _ in 0..<3 {
                points.append(PKStrokePoint(
                    location: location, timeOffset: Double(points.count) * 0.001,
                    size: CGSize(width: strokeSize, height: strokeSize),
                    opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
                ))
            }
        }
        for (index, pass) in passes.enumerated() {
            let inset = min(strokeSize / 2, CGFloat(pass.run.maxX - pass.run.minX + 1) / 2)
            let left = CGFloat(pass.run.minX) + inset
            let right = max(CGFloat(pass.run.maxX + 1) - inset, left)
            let ends = index.isMultiple(of: 2) ? [left, right] : [right, left]
            for x in ends { add(CGPoint(x: x, y: pass.y)) }
        }
        let path = PKStrokePath(controlPoints: points, creationDate: date)
        return PKStroke(ink: PKInk(.monoline, color: color), path: path)
    }
}
#endif
