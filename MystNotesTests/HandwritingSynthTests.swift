import XCTest
import PencilKit
@testable import Mystnotes

final class HandwritingSynthTests: XCTestCase {
    private let ink = PKInk(.pen, color: .black)
    private let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func layout(_ text: String, profile: HandwritingProfile? = nil, maxWidth: CGFloat = 400,
                        xHeight: CGFloat = 20, width: CGFloat = 2.5, seed: UInt64 = 42) -> [PKStroke] {
        HandwritingSynth.layout(text: text, profile: profile, origin: CGPoint(x: 10, y: 10),
                                maxWidth: maxWidth, xHeight: xHeight, ink: ink, width: width,
                                baseDate: base, seed: seed)
    }

    private func locations(_ strokes: [PKStroke]) -> [[CGPoint]] {
        strokes.map { $0.path.map(\.location) }
    }

    private func points(_ strokes: [PKStroke]) -> [PKStrokePoint] {
        strokes.flatMap { Array($0.path) }
    }

    /// A profile that knows only "a": one vertical stroke.
    private func smallProfile(size: CGFloat = 0.01) -> HandwritingProfile {
        let stroke = (0...5).map { GlyphPoint(x: 0.3, y: -CGFloat($0) * 0.2, size: size, force: 0.6, t: Double($0) * 0.01) }
        var profile = HandwritingProfile()
        profile.glyphs["a"] = [GlyphSample(strokes: [stroke], advance: 0.8)]
        return profile
    }

    func testSameSeedGivesIdenticalOutput() {
        let a = layout("Hello, world! The quick brown fox.", seed: 7)
        let b = layout("Hello, world! The quick brown fox.", seed: 7)
        XCTAssertFalse(a.isEmpty)
        XCTAssertEqual(locations(a), locations(b))
        XCTAssertEqual(a.map(\.path.creationDate), b.map(\.path.creationDate))
        XCTAssertNotEqual(locations(a), locations(layout("Hello, world! The quick brown fox.", seed: 8)))
    }

    func testWrappingKeepsStrokesWithinMaxWidth() {
        let xHeight: CGFloat = 20, maxWidth: CGFloat = 300
        let strokes = layout(String(repeating: "the quick brown fox jumps ", count: 6),
                             maxWidth: maxWidth, xHeight: xHeight)
        let pts = points(strokes)
        XCTAssertGreaterThan(pts.map(\.location.y).max() ?? 0, 10 + HandwritingSynth.lineHeightFactor * xHeight,
                             "long text should wrap onto more than one line")
        // Tolerance: rotation, scale and the fallback's slant.
        XCTAssertLessThanOrEqual(pts.map(\.location.x).max() ?? 0, 10 + maxWidth + xHeight)
        XCTAssertGreaterThanOrEqual(pts.map(\.location.x).min() ?? 0, 10 - xHeight)
    }

    func testEveryStrokeHasADistinctCreationDate() {
        let strokes = layout("Distinct dates for every stroke, please: 123!")
        let dates = strokes.map(\.path.creationDate)
        XCTAssertGreaterThan(dates.count, 20)
        XCTAssertEqual(Set(dates).count, dates.count)
        for (earlier, later) in zip(dates, dates.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later.timeIntervalSince(earlier), 0.0009)
        }
    }

    func testRenderedWidthNeverBelowMinimum() {
        // A thin pen and a profile that records near-zero sizes.
        for strokes in [layout("abc", profile: smallProfile(), width: 0.5), layout("Wide", width: 0.1)] {
            XCTAssertFalse(strokes.isEmpty)
            for p in points(strokes) {
                XCTAssertGreaterThanOrEqual(p.size.width, HandwritingSynth.minimumWidth - 0.001)
                XCTAssertGreaterThanOrEqual(p.size.height, HandwritingSynth.minimumWidth - 0.001)
            }
        }
    }

    func testMissingGlyphFallsBackToBuiltInHand() {
        let onlyA = layout("a", profile: smallProfile())
        let withMissing = layout("abc", profile: smallProfile())
        XCTAssertGreaterThan(withMissing.count, onlyA.count, "b and c come from the fallback hand")
        XCTAssertFalse(layout("Hello, World! 123 ?", profile: nil).isEmpty)
    }

    func testFallbackHandCoversTheWholeCharset() {
        for c in HandwritingCharset.all {
            guard let sample = FallbackHand.sample(for: c) else { return XCTFail("no fallback for \(c)") }
            XCTAssertFalse(sample.strokes.isEmpty, "\(c)")
            XCTAssertGreaterThan(sample.advance, 0.2, "\(c)")
        }
    }

    func testProfileRoundTripsThroughJSON() throws {
        var profile = smallProfile(size: 1)
        profile.glyphs["A"] = [FallbackHand.sample(for: "A")!]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HandwritingSynthTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("profile.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try HandwritingProfileStore.save(profile, to: url)
        let loaded = try XCTUnwrap(HandwritingProfileStore.load(from: url))
        XCTAssertEqual(loaded.glyphs, profile.glyphs)
        XCTAssertEqual(loaded.version, profile.version)
        XCTAssertEqual(loaded.createdAt.timeIntervalSince1970, profile.createdAt.timeIntervalSince1970, accuracy: 1)

        // Reset moves the file to trash/ rather than deleting it.
        XCTAssertTrue(HandwritingProfileStore.reset(at: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let trash = url.deletingLastPathComponent().appendingPathComponent("trash")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path).count, 1)
    }

    func testNormalizerTurnsAStrokeIntoBaselineRelativeUnits() throws {
        // A vertical stroke from the baseline up to the x-height line.
        let g = CaptureGeometry.self
        let pts = [CGPoint(x: 100, y: g.baselineY), CGPoint(x: 100, y: g.xHeightY)].map {
            PKStrokePoint(location: $0, timeOffset: 0, size: CGSize(width: 3, height: 3),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let stroke = PKStroke(ink: ink, path: PKStrokePath(controlPoints: [pts[0], pts[0], pts[0], pts[1], pts[1], pts[1]],
                                                            creationDate: base))
        let sample = try XCTUnwrap(GlyphNormalizer.sample(from: PKDrawing(strokes: [stroke])))
        let ys = sample.strokes.flatMap { $0.map(\.y) }
        XCTAssertEqual(ys.max() ?? 9, 0, accuracy: 0.1)
        XCTAssertEqual(ys.min() ?? 9, -1, accuracy: 0.1)
        XCTAssertEqual(sample.strokes[0][0].x, g.sideBearing, accuracy: 0.01)
        XCTAssertNil(GlyphNormalizer.sample(from: PKDrawing()))
    }
}
