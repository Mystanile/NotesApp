import SwiftUI
import SwiftData
#if targetEnvironment(macCatalyst) || canImport(UIKit)
import PencilKit
import UIKit
#endif

/// Page audio (recording, playback, the ink-timeline veil) and Replay Page.
/// The state lives in `NotebookDetailView` (`audio`, `showAudioBar`,
/// `timelineStrokes`, `replaySource`); this is only the glue.
extension NotebookDetailView {
    #if targetEnvironment(macCatalyst) || canImport(UIKit)

    /// The bar, floating above the bottom edge. Shown on request or while
    /// recording (a recording must always be stoppable), never while presenting.
    @ViewBuilder
    var audioBarOverlay: some View {
        if (showAudioBar || audio.isRecording), !isPresenting, let page = currentPage {
            AudioPlayerBar(audio: audio, page: page)
                .frame(maxWidth: 560)
                .padding(.horizontal, Space.l)
                .padding(.bottom, Space.s)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// The audio bar stacked over the Zoom Window panel, so neither covers the other.
    var bottomOverlays: some View {
        VStack(spacing: Space.s) {
            audioBarOverlay
            zoomWindowPanel
        }
    }

    /// The veil over strokes written after the playhead, in page space so
    /// `pageToView` is the identity. Present only while a recording of this
    /// page is loaded (playing or paused).
    ///
    /// Taps: the overlay sits above the canvas and cannot tell a finger from
    /// the Pencil, so while it accepts taps it would swallow ink. It accepts
    /// them only while playback is paused AND the lasso is the active tool
    /// (a tool that does not write); while playing, or with any other tool, it
    /// ignores every touch and the page can be written on.
    @ViewBuilder
    func timelineLayer(for page: Page, pageSize: CGSize) -> some View {
        if let recording = audio.playingRecording, recording.page?.id == page.id,
           let start = recording.startedAt, !timelineStrokes.isEmpty, !isPresenting {
            let acceptsTaps = !audio.isPlaying && toolState.activeKind == .lasso
            PageViewportLayer(viewport: viewport, pageSize: pageSize) { _ in
                // Read here, so only this layer redraws as the playhead moves.
                InkTimelineOverlay(strokes: timelineStrokes, recordingStart: start,
                                   recordingDuration: recording.duration,
                                   playhead: audio.currentTime, pageToView: .identity,
                                   veilColor: .white, acceptsTaps: acceptsTaps,
                                   onSeek: { audio.seek(to: $0) })
            }
        }
    }

    /// Rebuilt when playback starts, the page's canvas changes, or a stroke
    /// has settled (`canvasIsDirty` going false) - never per frame.
    func refreshTimelineStrokes() {
        guard audio.playingRecording != nil else {
            if !timelineStrokes.isEmpty { timelineStrokes = [] }
            return
        }
        timelineStrokes = canvasView.drawing.strokes.map {
            InkTimelineStroke(bounds: $0.renderBounds, date: $0.path.creationDate)
        }
    }

    /// A page turn stops playback of another page's recording. A recording
    /// in progress carries on (the controller keeps its own page).
    func audioPageChanged(to newID: UUID?) {
        guard !audio.isRecording, let loaded = audio.playingRecording,
              loaded.page?.id != newID else { return }
        audio.stopPlayback()
    }

    func openReplay(for page: Page) {
        let size = page.type == "whiteboard"
            ? CGSize(width: WhiteboardCanvasView.boardSize, height: WhiteboardCanvasView.boardSize)
            : PageGeometry.contentSize(for: page)
        replaySource = ReplaySource.make(drawing: canvasView.drawing, pageSize: size,
                                         isWhiteboard: page.type == "whiteboard")
    }

    #endif
}
