import XCTest
import PencilKit
@testable import Mystnotes

/// M0 task 16: `PKDrawing` → neutral → `PKDrawing` loses nothing, and the
/// ids the neutral file assigns stay attached to the same strokes across
/// everything the canvas can do to them.
final class StrokeCodecTests: XCTestCase {

    // MARK: Round trip

    func testRoundTrip_isExact_forEveryInkType() throws {
        for inkType in InkFixtures.allInkTypes {
            let original = InkFixtures.drawing(inkType: inkType, strokes: 3)
            var ids = StrokeIDMap()
            let data = StrokeCodec.encode(original, ids: &ids)
            let (decoded, decodedIDs) = try StrokeCodec.decode(data)

            assertStrokesEqual(decoded, original, "\(inkType.rawValue)")
            XCTAssertEqual(decodedIDs, ids, "\(inkType.rawValue): the id map must come back from the file")
            XCTAssertEqual(decoded.strokes.count, 3)
        }
    }

    func testRoundTrip_preservesTransformMaskSeedAndColor() throws {
        var stroke = InkFixtures.stroke(inkType: .pencil, index: 0, color: UIColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 0.75))
        stroke.transform = CGAffineTransform(translationX: 12.5, y: -3.25).rotated(by: 0.3)
        stroke.mask = UIBezierPath(rect: CGRect(x: 10, y: 10, width: 100, height: 40))
        let original = PKDrawing(strokes: [stroke])

        var ids = StrokeIDMap()
        let (decoded, _) = try StrokeCodec.decode(StrokeCodec.encode(original, ids: &ids))

        assertStrokesEqual(decoded, original, "pencil with transform/mask/color")
        let back = try XCTUnwrap(decoded.strokes.first)
        XCTAssertEqual(back.transform, stroke.transform)
        XCTAssertEqual(back.randomSeed, stroke.randomSeed)
        XCTAssertNotNil(back.mask)
        XCTAssertEqual(back.mask?.bounds, stroke.mask?.bounds)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        back.ink.color.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual([r, g, b, a], [0.2, 0.4, 0.9, 0.75])
    }

    func testRoundTrip_emptyDrawing() throws {
        var ids = StrokeIDMap()
        let (decoded, decodedIDs) = try StrokeCodec.decode(StrokeCodec.encode(PKDrawing(), ids: &ids))
        XCTAssertEqual(decoded.strokes.count, 0)
        XCTAssertEqual(decodedIDs.count, 0)
    }

    // MARK: Stroke identity across edits

    func testIDs_areStableAcrossAddEraseMoveAndPartialErase() {
        var drawing = InkFixtures.drawing(inkType: .pen, strokes: 3)
        var ids = StrokeIDMap()
        _ = StrokeCodec.encode(drawing, ids: &ids)
        let originalIDs = drawing.strokes.map { ids.existingID(for: $0)! }
        XCTAssertEqual(Set(originalIDs).count, 3, "three strokes, three ids")

        // Add a stroke: the old three keep their ids, the new one is new.
        drawing.strokes.append(InkFixtures.stroke(inkType: .pen, index: 10))
        _ = StrokeCodec.encode(drawing, ids: &ids)
        XCTAssertEqual(drawing.strokes.prefix(3).map { ids.existingID(for: $0)! }, originalIDs)
        let addedID = ids.existingID(for: drawing.strokes[3])!
        XCTAssertFalse(originalIDs.contains(addedID))

        // Vector-erase the middle stroke: the others are unaffected, and the
        // map forgets the erased one.
        drawing.strokes.remove(at: 1)
        _ = StrokeCodec.encode(drawing, ids: &ids)
        XCTAssertEqual(ids.existingID(for: drawing.strokes[0]), originalIDs[0])
        XCTAssertEqual(ids.existingID(for: drawing.strokes[1]), originalIDs[2])
        XCTAssertEqual(ids.existingID(for: drawing.strokes[2]), addedID)
        XCTAssertEqual(ids.count, 3)

        // Lasso-move the first stroke: same stroke, same id.
        drawing.strokes[0].transform = CGAffineTransform(translationX: 40, y: 80)
        _ = StrokeCodec.encode(drawing, ids: &ids)
        XCTAssertEqual(ids.existingID(for: drawing.strokes[0]), originalIDs[0])

        // Partially erase it (a mask): still the same stroke.
        drawing.strokes[0].mask = UIBezierPath(rect: CGRect(x: 0, y: 0, width: 50, height: 50))
        _ = StrokeCodec.encode(drawing, ids: &ids)
        XCTAssertEqual(ids.existingID(for: drawing.strokes[0]), originalIDs[0])
    }

    /// A shape tool can insert several strokes in the same instant with the
    /// same seed. They differ by where they are; they must not share an id.
    func testIDs_distinguishStrokesCreatedInTheSameInstant() {
        let when = Date()
        let strokes = (0..<3).map { i in
            InkFixtures.stroke(inkType: .pen, index: i, creationDate: when, randomSeed: 0)
        }
        var ids = StrokeIDMap()
        _ = StrokeCodec.encode(PKDrawing(strokes: strokes), ids: &ids)
        XCTAssertEqual(Set(strokes.map { ids.existingID(for: $0)! }).count, 3)
    }

    /// The ids survive a save/load cycle, which is the whole point: a link
    /// or a timeline event made before the save still resolves after it.
    func testIDs_surviveSaveAndLoad_thenAnotherSave() throws {
        let drawing = InkFixtures.drawing(inkType: .fountainPen, strokes: 2)
        var ids = StrokeIDMap()
        let data = StrokeCodec.encode(drawing, ids: &ids)
        let before = drawing.strokes.map { ids.existingID(for: $0)! }

        var (loaded, loadedIDs) = try StrokeCodec.decode(data)
        XCTAssertEqual(loaded.strokes.map { loadedIDs.existingID(for: $0)! }, before)

        loaded.strokes.append(InkFixtures.stroke(inkType: .fountainPen, index: 5))
        _ = StrokeCodec.encode(loaded, ids: &loadedIDs)
        XCTAssertEqual(loaded.strokes.prefix(2).map { loadedIDs.existingID(for: $0)! }, before,
                       "ids from the file are kept through the next save")
    }

    // MARK: Compression

    func testBody_isCompressedByDefault_andAnUncompressedFileReadsTheSame() throws {
        let drawing = InkFixtures.drawing(inkType: .fountainPen, strokes: 3)
        var ids = StrokeIDMap()
        let compressed = StrokeCodec.encode(drawing, ids: &ids)
        var ids2 = ids
        let plain = StrokeCodec.encode(drawing, ids: &ids2, compress: false)

        let flags = { (d: Data) in UInt32(d[6]) | UInt32(d[7]) << 8 | UInt32(d[8]) << 16 | UInt32(d[9]) << 24 }
        XCTAssertEqual(flags(compressed) & StrokeCodec.compressedBodyFlag, StrokeCodec.compressedBodyFlag)
        XCTAssertEqual(flags(plain) & StrokeCodec.compressedBodyFlag, 0)
        XCTAssertLessThan(compressed.count, plain.count / 2, "compressed \(compressed.count) vs plain \(plain.count)")

        let a = try StrokeCodec.decode(compressed)
        let b = try StrokeCodec.decode(plain)
        assertStrokesEqual(a.drawing, drawing, "compressed")
        assertStrokesEqual(b.drawing, drawing, "plain")
        XCTAssertEqual(a.ids, b.ids, "same ids either way")
        print("STROKES 3 fountain-pen strokes: \(plain.count) bytes plain, \(compressed.count) compressed")
    }

    // MARK: Format guards

    func testDecode_rejectsTruncationForeignBytesAndFutureVersions() {
        var ids = StrokeIDMap()
        let good = StrokeCodec.encode(InkFixtures.drawing(inkType: .marker, strokes: 2), ids: &ids)

        XCTAssertThrowsError(try StrokeCodec.decode(good.prefix(good.count / 2))) { error in
            XCTAssertEqual(error as? StrokeCodec.CodecError, .truncated)
        }
        XCTAssertThrowsError(try StrokeCodec.decode(Data("this is not ink".utf8))) { error in
            XCTAssertEqual(error as? StrokeCodec.CodecError, .notAStrokesFile)
        }
        var future = good
        future[4] = 0x63; future[5] = 0x00   // version 99
        XCTAssertThrowsError(try StrokeCodec.decode(future)) { error in
            XCTAssertEqual(error as? StrokeCodec.CodecError, .unsupportedVersion(99))
        }
    }
}

// MARK: - Structural comparison

/// `PKDrawing`'s `==` compares an internal drawing identity, not content
/// (`PKDrawing() == PKDrawing()` is false), so equality has to be checked
/// stroke by stroke. Exact for everything except the three fields
/// PencilKit quantizes on construction - azimuth, altitude, threshold -
/// which are allowed one quantum of drift (see InkFidelityTests).
func assertStrokesEqual(_ a: PKDrawing, _ b: PKDrawing, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.strokes.count, b.strokes.count, "\(label): stroke count", file: file, line: line)
    for (i, (x, y)) in zip(a.strokes, b.strokes).enumerated() {
        let where_ = "\(label) stroke \(i)"
        XCTAssertEqual(x.ink.inkType, y.ink.inkType, "\(where_): ink type", file: file, line: line)
        XCTAssertEqual(x.randomSeed, y.randomSeed, "\(where_): randomSeed", file: file, line: line)
        XCTAssertEqual(x.transform, y.transform, "\(where_): transform", file: file, line: line)
        XCTAssertEqual(x.path.creationDate, y.path.creationDate, "\(where_): creationDate", file: file, line: line)
        XCTAssertEqual(x.mask == nil, y.mask == nil, "\(where_): mask presence", file: file, line: line)
        if let mx = x.mask, let my = y.mask { XCTAssertEqual(mx.bounds, my.bounds, "\(where_): mask bounds", file: file, line: line) }
        var xr: CGFloat = 0, xg: CGFloat = 0, xb: CGFloat = 0, xa: CGFloat = 0
        var yr: CGFloat = 0, yg: CGFloat = 0, yb: CGFloat = 0, ya: CGFloat = 0
        x.ink.color.getRed(&xr, green: &xg, blue: &xb, alpha: &xa)
        y.ink.color.getRed(&yr, green: &yg, blue: &yb, alpha: &ya)
        XCTAssertEqual([xr, xg, xb, xa], [yr, yg, yb, ya], "\(where_): color", file: file, line: line)
        XCTAssertEqual(x.path.count, y.path.count, "\(where_): point count", file: file, line: line)
        for (j, (p, q)) in zip(x.path, y.path).enumerated() {
            let at = "\(where_) point \(j)"
            XCTAssertEqual(p.location, q.location, "\(at): location", file: file, line: line)
            XCTAssertEqual(p.timeOffset, q.timeOffset, "\(at): timeOffset", file: file, line: line)
            XCTAssertEqual(p.size, q.size, "\(at): size", file: file, line: line)
            XCTAssertEqual(p.opacity, q.opacity, "\(at): opacity", file: file, line: line)
            XCTAssertEqual(p.force, q.force, "\(at): force", file: file, line: line)
            XCTAssertEqual(p.secondaryScale, q.secondaryScale, "\(at): secondaryScale", file: file, line: line)
            XCTAssertEqual(p.azimuth, q.azimuth, accuracy: 1e-3, "\(at): azimuth", file: file, line: line)
            XCTAssertEqual(p.altitude, q.altitude, accuracy: 1e-3, "\(at): altitude", file: file, line: line)
            XCTAssertEqual(p.threshold, q.threshold, accuracy: 1e-3, "\(at): threshold", file: file, line: line)
        }
    }
}

// MARK: - Fixtures shared with the fidelity harness

enum InkFixtures {
    static let allInkTypes: [PKInk.InkType] = [.pen, .pencil, .marker, .monoline, .fountainPen, .watercolor, .crayon]

    /// Real strokes with varying pressure and tilt, so texture and width
    /// modulation are exercised, not just a flat line.
    static func stroke(inkType: PKInk.InkType, index: Int, color: UIColor = .black,
                       creationDate: Date? = nil, randomSeed: UInt32? = nil) -> PKStroke {
        let points = (0..<32).map { i -> PKStrokePoint in
            let t = CGFloat(i) / 31
            return PKStrokePoint(
                location: CGPoint(x: 30 + t * 220 + CGFloat(index) * 5, y: 40 + CGFloat(index) * 70 + sin(t * .pi * 2) * 18),
                timeOffset: TimeInterval(i) * 0.009,
                size: CGSize(width: 2 + t * 6, height: 2 + t * 6),
                opacity: 0.6 + t * 0.4,
                force: 0.3 + t * 0.6,
                azimuth: t * .pi,
                altitude: .pi / 3 + t * 0.4,
                secondaryScale: 1 + t * 0.5,
                threshold: 0.2
            )
        }
        let path = PKStrokePath(controlPoints: points,
                                creationDate: creationDate ?? Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(index)))
        return PKStroke(ink: PKInk(inkType, color: color), path: path, randomSeed: randomSeed ?? UInt32(1000 + index))
    }

    static func drawing(inkType: PKInk.InkType, strokes: Int) -> PKDrawing {
        PKDrawing(strokes: (0..<strokes).map { stroke(inkType: inkType, index: $0) })
    }
}
