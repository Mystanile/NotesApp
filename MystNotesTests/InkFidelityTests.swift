import XCTest
import PencilKit
@testable import Mystnotes

/// M0 task 17: does ink that went through the neutral format render the
/// same? One test per ink type. Both drawings are rendered by PencilKit
/// itself at 2× and compared pixel for pixel; the tolerance is whatever
/// was observed and recorded here, and any type that isn't exact must be
/// dual-written (see CLAUDE.md invariant 5).
///
/// Observed Sept 12, 2026 on the iPad simulator, 3 strokes of 32 points
/// at 2× (~250k pixels per render):
///
///     pen, pencil, monoline, fountainPen, watercolor   0 differing pixels
///     marker    52 differing pixels, max channel delta 3
///     crayon   182 differing pixels, max channel delta 28
///     mixed     20 differing pixels, max channel delta 3
///
/// The marker and crayon differences are not information the format
/// dropped. `PKStrokePoint` quantizes azimuth, altitude and threshold on
/// construction (threshold 0.2 reads back as 0.19998474), and building a
/// point from read-back values re-quantizes with rounding - one quantum
/// of drift, once. A second trip is pixel-identical to the first
/// (`testSecondTrip_isIdenticalToTheFirst`). Apple's own
/// `dataRepresentation()` is exact only because it stores the internal
/// representation the public API can't reach. Dropping `threshold`
/// instead (the 7- and 8-argument initializers) costs crayon 28,011
/// pixels - that field is not optional.
final class InkFidelityTests: XCTestCase {
    /// Differing pixels allowed, per render label: the observed value with
    /// headroom for renderer variation across OS versions. Raise only with
    /// a recorded reason. A type that blows well past its number is not
    /// round-tripping and must be dual-written.
    private static let tolerance: [String: Int] = [
        PKInk.InkType.marker.rawValue: 150,
        PKInk.InkType.crayon.rawValue: 400,
        "mixed": 100
    ]

    func testPen() throws { try assertFidelity(.pen) }
    func testPencil() throws { try assertFidelity(.pencil) }
    func testMarker() throws { try assertFidelity(.marker) }
    func testMonoline() throws { try assertFidelity(.monoline) }
    func testFountainPen() throws { try assertFidelity(.fountainPen) }
    func testWatercolor() throws { try assertFidelity(.watercolor) }
    func testCrayon() throws { try assertFidelity(.crayon) }

    /// A mixed page with a masked, moved, coloured stroke of each type.
    func testMixedPageWithMasksAndTransforms() throws {
        var strokes: [PKStroke] = []
        for (i, type) in InkFixtures.allInkTypes.enumerated() {
            var s = InkFixtures.stroke(inkType: type, index: i, color: UIColor(hue: CGFloat(i) / 7, saturation: 0.8, brightness: 0.7, alpha: 0.9))
            if i % 2 == 0 { s.transform = CGAffineTransform(translationX: 15, y: 5).rotated(by: 0.05) }
            if i % 3 == 0 { s.mask = UIBezierPath(rect: CGRect(x: 0, y: 0, width: 160, height: 600)) }
            strokes.append(s)
        }
        try assertFidelity(PKDrawing(strokes: strokes), label: "mixed")
    }

    /// The quantization drift happens once: after a trip through the
    /// format, the next trip changes nothing.
    func testSecondTrip_isIdenticalToTheFirst() throws {
        for inkType in [PKInk.InkType.marker, .crayon] {
            let original = InkFixtures.drawing(inkType: inkType, strokes: 3)
            var ids = StrokeIDMap()
            let first = try StrokeCodec.decode(StrokeCodec.encode(original, ids: &ids)).drawing
            let second = try StrokeCodec.decode(StrokeCodec.encode(first, ids: &ids)).drawing
            let rect = original.bounds.insetBy(dx: -20, dy: -20)
            XCTAssertEqual(try pixels(of: first, in: rect), try pixels(of: second, in: rect),
                           "\(inkType.rawValue): the second trip must not drift further")
        }
    }

    private func assertFidelity(_ inkType: PKInk.InkType) throws {
        try assertFidelity(InkFixtures.drawing(inkType: inkType, strokes: 3), label: inkType.rawValue)
    }

    private func assertFidelity(_ original: PKDrawing, label: String) throws {
        var ids = StrokeIDMap()
        let data = StrokeCodec.encode(original, ids: &ids)
        let (roundTripped, _) = try StrokeCodec.decode(data)

        let rect = original.bounds.insetBy(dx: -20, dy: -20)
        let a = try pixels(of: original, in: rect)
        let b = try pixels(of: roundTripped, in: rect)
        XCTAssertEqual(a.count, b.count, "\(label): renders differ in size")

        var differing = 0
        var maxDelta = 0
        for i in stride(from: 0, to: min(a.count, b.count), by: 4) {
            let delta = (0..<4).map { abs(Int(a[i + $0]) - Int(b[i + $0])) }.max() ?? 0
            if delta > 0 { differing += 1; maxDelta = max(maxDelta, delta) }
        }
        let allowed = Self.tolerance[label] ?? 0
        print("FIDELITY \(label): \(differing) differing pixels of \(a.count / 4), max channel delta \(maxDelta), file \(data.count) bytes")
        XCTAssertLessThanOrEqual(differing, allowed,
                                 "\(label): \(differing) pixels differ after the round trip (max channel delta \(maxDelta))")
    }

    /// RGBA8 pixels of the drawing rendered by PencilKit at 2×.
    private func pixels(of drawing: PKDrawing, in rect: CGRect) throws -> [UInt8] {
        let image = drawing.image(from: rect, scale: 2)
        let cg = try XCTUnwrap(image.cgImage)
        let width = cg.width, height = cg.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
