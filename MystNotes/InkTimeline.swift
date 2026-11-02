import Foundation
import CoreGraphics

/// The arithmetic that ties ink to audio. A stroke's `creationDate` and a
/// recording's `startedAt` are both wall-clock, so a stroke's place in the
/// audio is the difference between them. No UI, no PencilKit, no models:
/// callers hand in plain dates and rectangles, which keeps all of it
/// testable and safe to run anywhere.
nonisolated enum InkTimeline {
    /// Seconds into `recording` at which a stroke was begun, or nil if it
    /// was written before the recording started or after it ended.
    static func offset(of strokeDate: Date, in recording: (start: Date, duration: Double)) -> Double? {
        let seconds = strokeDate.timeIntervalSince(recording.start)
        guard seconds >= 0, seconds <= recording.duration else { return nil }
        return seconds
    }

    /// Indexes (into `strokeDates`) of the strokes written after the
    /// playhead, the ones playback dims. Strokes from before the recording
    /// began are never "later" - they were on the page already.
    static func strokeIndices(writtenAfter time: Double, recordingStart: Date, strokeDates: [Date]) -> IndexSet {
        var result = IndexSet()
        for (index, date) in strokeDates.enumerated()
        where date.timeIntervalSince(recordingStart) > time {
            result.insert(index)
        }
        return result
    }

    /// The stroke a tap at `point` means: among the strokes whose bounds
    /// (grown by `tolerance`) contain it, the smallest; failing that, none.
    /// Smallest wins so a tap on a word inside a boxed region picks the
    /// word. Ties go to the later stroke. Returns the index into `strokes`.
    static func nearestStroke(at point: CGPoint,
                              strokes: [(bounds: CGRect, date: Date)],
                              tolerance: CGFloat = 12) -> Int? {
        var best: (index: Int, area: CGFloat)?
        for (index, stroke) in strokes.enumerated() {
            let hit = stroke.bounds.insetBy(dx: -tolerance, dy: -tolerance)
            guard hit.contains(point) else { continue }
            let area = stroke.bounds.width * stroke.bounds.height
            if let current = best {
                if area < current.area || (area == current.area && stroke.date >= strokes[current.index].date) {
                    best = (index, area)
                }
            } else {
                best = (index, area)
            }
        }
        return best?.index
    }

    /// The offset a tap on `point` should seek to: the tapped stroke's
    /// offset in the recording, or nil when no stroke is there or it lies
    /// outside the recording.
    static func seekOffset(at point: CGPoint,
                           strokes: [(bounds: CGRect, date: Date)],
                           recording: (start: Date, duration: Double),
                           tolerance: CGFloat = 12) -> Double? {
        guard let index = nearestStroke(at: point, strokes: strokes, tolerance: tolerance) else { return nil }
        return offset(of: strokes[index].date, in: recording)
    }
}
