import XCTest
#if canImport(UIKit)
import PencilKit
#endif
@testable import Mystnotes

final class StrokeReplayTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testBuild_ordersByCreationDate_andKeepsOriginalIndexes() {
        let timeline = ReplayTimeline.build(strokes: [
            (date: t0.addingTimeInterval(2), duration: 0.5),   // 0: second
            (date: t0, duration: 0.5),                         // 1: first
            (date: t0.addingTimeInterval(1), duration: 0.5),   // 2: middle
        ])
        XCTAssertEqual(timeline.items.map(\.strokeIndex), [1, 2, 0])
        XCTAssertEqual(timeline.items.map(\.start), timeline.items.map(\.start).sorted())
        XCTAssertEqual(timeline.items.first?.start, 0)
    }

    func testBuild_equalDates_keepInputOrder() {
        let timeline = ReplayTimeline.build(strokes: [(t0, 0.2), (t0, 0.2), (t0, 0.2)])
        XCTAssertEqual(timeline.items.map(\.strokeIndex), [0, 1, 2])
        // Never overlapping.
        XCTAssertEqual(timeline.items[1].start, timeline.items[0].end, accuracy: 1e-9)
    }

    func testBuild_shortGapsAreKept_longGapsCompressed() {
        let timeline = ReplayTimeline.build(strokes: [
            (date: t0, duration: 1),                        // ends at 1
            (date: t0.addingTimeInterval(2), duration: 1),  // gap 1.0 s: kept
            (date: t0.addingTimeInterval(600), duration: 1) // gap ~597 s: becomes 0.5
        ])
        XCTAssertEqual(timeline.items[1].start, 2, accuracy: 1e-9)
        XCTAssertEqual(timeline.items[2].start, 3 + ReplayTimeline.compressedIdle, accuracy: 1e-9)
        XCTAssertEqual(timeline.total, 3 + ReplayTimeline.compressedIdle + 1, accuracy: 1e-9)
    }

    func testBuild_gapMeasuredFromEndOfPreviousStroke() {
        // Starts 10 s after the first starts, but the first took 9 s: a 1 s gap, kept.
        let timeline = ReplayTimeline.build(strokes: [
            (date: t0, duration: 9),
            (date: t0.addingTimeInterval(10), duration: 1),
        ])
        XCTAssertEqual(timeline.items[1].start, 10, accuracy: 1e-9)
    }

    func testBuild_zeroDurationStrokeGetsMinimumDuration() {
        let timeline = ReplayTimeline.build(strokes: [(t0, 0)])
        XCTAssertEqual(timeline.total, ReplayTimeline.minimumStrokeDuration, accuracy: 1e-9)
    }

    func testBuild_empty() {
        let timeline = ReplayTimeline.build(strokes: [])
        XCTAssertTrue(timeline.items.isEmpty)
        XCTAssertEqual(timeline.total, 0)
        XCTAssertEqual(timeline.frame(at: 5), ReplayTimeline.Frame(complete: 0, partialLocalTime: nil))
    }

    func testFrame_atVariousTimes() {
        let timeline = ReplayTimeline.build(strokes: [
            (date: t0, duration: 1),
            (date: t0.addingTimeInterval(2), duration: 1),
        ]) // items: [0,1], [2,3]
        XCTAssertEqual(timeline.frame(at: 0), ReplayTimeline.Frame(complete: 0, partialLocalTime: 0))
        XCTAssertEqual(timeline.frame(at: 0.5), ReplayTimeline.Frame(complete: 0, partialLocalTime: 0.5))
        XCTAssertEqual(timeline.frame(at: 1.5), ReplayTimeline.Frame(complete: 1, partialLocalTime: nil))
        XCTAssertEqual(timeline.frame(at: 2.25), ReplayTimeline.Frame(complete: 1, partialLocalTime: 0.25))
        XCTAssertEqual(timeline.frame(at: 3), ReplayTimeline.Frame(complete: 2, partialLocalTime: nil))
        XCTAssertEqual(timeline.frame(at: 99), ReplayTimeline.Frame(complete: 2, partialLocalTime: nil))
        XCTAssertEqual(timeline.frame(at: -4), ReplayTimeline.Frame(complete: 0, partialLocalTime: 0))
    }

    #if canImport(UIKit)
    private func stroke(offsets: [Double], date: Date? = nil) -> PKStroke {
        let points = offsets.enumerated().map { index, offset in
            PKStrokePoint(location: CGPoint(x: Double(index) * 10, y: 5), timeOffset: offset,
                          size: CGSize(width: 4, height: 4), opacity: 1, force: 1,
                          azimuth: 0, altitude: .pi / 2)
        }
        let path = PKStrokePath(controlPoints: points, creationDate: date ?? t0)
        return PKStroke(ink: PKInk(.pen, color: .black), path: path)
    }

    func testTruncation_keepsPointsUpToTime() {
        let s = stroke(offsets: [0, 0.1, 0.2, 0.3, 0.4])
        XCTAssertEqual(ReplayTruncation.pointCount(in: s.path, upTo: 0.25), 3)
        XCTAssertEqual(ReplayTruncation.truncated(s, upTo: 0.25)?.path.count, 3)
        XCTAssertEqual(ReplayTruncation.truncated(s, upTo: 0.3)?.path.count, 4)
        XCTAssertEqual(ReplayTruncation.truncated(s, upTo: 10)?.path.count, 5)
    }

    func testTruncation_tooFewPointsIsNil() {
        let s = stroke(offsets: [0, 0.1, 0.2])
        XCTAssertNil(ReplayTruncation.truncated(s, upTo: 0.05))   // one point
        XCTAssertNil(ReplayTruncation.truncated(s, upTo: -1))
    }

    func testTruncation_keepsCreationDate() {
        let date = t0.addingTimeInterval(7)
        let s = stroke(offsets: [0, 0.1, 0.2], date: date)
        XCTAssertEqual(ReplayTruncation.truncated(s, upTo: 0.15)?.path.creationDate, date)
    }

    func testDuration_isLastOffsetMinusFirst() {
        XCTAssertEqual(ReplayTruncation.duration(of: stroke(offsets: [0.5, 0.7, 1.25])), 0.75, accuracy: 1e-6)
    }

    func testSource_ordersStrokesByCreationDate() {
        let late = stroke(offsets: [0, 0.2], date: t0.addingTimeInterval(5))
        let early = stroke(offsets: [0, 0.2], date: t0)
        let source = ReplaySource.make(drawing: PKDrawing(strokes: [late, early]),
                                       pageSize: CGSize(width: 100, height: 100), isWhiteboard: false)
        XCTAssertEqual(source.strokes.map { $0.path.creationDate }, [t0, t0.addingTimeInterval(5)])
        XCTAssertEqual(source.contentRect, CGRect(x: 0, y: 0, width: 100, height: 100))
    }
    #endif
}
