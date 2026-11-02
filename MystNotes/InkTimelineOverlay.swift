import SwiftUI

/// What the overlay needs to know about one stroke, in page coordinates.
/// The host builds these from `PKDrawing.strokes` once per load (or per
/// save), not per frame:
///
///     drawing.strokes.map { InkTimelineStroke(bounds: $0.renderBounds, date: $0.path.creationDate) }
struct InkTimelineStroke: Equatable {
    var bounds: CGRect
    var date: Date
}

/// Playback's view of the ink: a translucent page-coloured veil over every
/// stroke written after the playhead, and a tap that asks the host to seek
/// to the tapped stroke.
///
/// Place it over the canvas, same frame as the page, only while a recording
/// is loaded. With `acceptsTaps` off (the default while the pencil is the
/// active tool) it ignores hits entirely, so it can never swallow ink.
/// It is a pure function of its inputs; it does not read the controller.
struct InkTimelineOverlay: View {
    var strokes: [InkTimelineStroke]
    /// Wall-clock start of the recording being played.
    var recordingStart: Date
    var recordingDuration: Double
    /// The playhead, seconds into the recording.
    var playhead: Double
    /// Maps a point/rect in page coordinates (the space of the strokes'
    /// `renderBounds`) into this view's coordinates - the canvas's zoom and
    /// offset. Identity when the overlay sits in the page's own space.
    var pageToView: CGAffineTransform = .identity
    /// The page's colour, for the veil. Opaque-ish paper white by default.
    var veilColor: Color = Color(uiColor: .systemBackground)
    var veilOpacity: Double = 0.78
    var acceptsTaps: Bool = true
    /// Called with the tapped stroke's offset in the recording.
    var onSeek: (Double) -> Void = { _ in }

    private var hidden: IndexSet {
        InkTimeline.strokeIndices(writtenAfter: playhead, recordingStart: recordingStart,
                                  strokeDates: strokes.map(\.date))
    }

    var body: some View {
        let hiddenIndexes = hidden
        Canvas { context, _ in
            for index in hiddenIndexes {
                let rect = strokes[index].bounds.applying(pageToView).insetBy(dx: -2, dy: -2)
                context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(veilColor.opacity(veilOpacity)))
            }
        }
        .allowsHitTesting(acceptsTaps)
        .contentShape(Rectangle())
        .gesture(
            SpatialTapGesture().onEnded { value in
                // View -> page, so hit-testing happens in stroke space.
                let inverse = pageToView.inverted()
                let point = value.location.applying(inverse)
                let pairs = strokes.map { (bounds: $0.bounds, date: $0.date) }
                if let seconds = InkTimeline.seekOffset(
                    at: point, strokes: pairs,
                    recording: (start: recordingStart, duration: recordingDuration)
                ) {
                    onSeek(seconds)
                }
            },
            including: acceptsTaps ? .all : .none
        )
        .accessibilityHidden(true)
    }
}
