import SwiftUI
import PencilKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A bounded "large canvas" for whiteboard-type pages: a big (but finite,
/// 3000x3000pt) board you pan and zoom around. This is NOT a true infinite
/// canvas (see the project plan's canvas-model decision) - big enough to
/// feel that way for brainstorming without needing viewport virtualization.
///
/// `PKCanvasView` is itself a `UIScrollView`, so the board is driven through
/// the canvas's *own* scrolling and zooming - not a second scroll view
/// wrapped around it (that older design had two scroll containers fighting
/// over every gesture, which made strokes drift out from under the pen and a
/// freshly opened whiteboard show the previous page's scroll position).
///
/// Input model matches GoodNotes/Freeform: the Apple Pencil draws, a single
/// finger pans, two fingers pinch-zoom, and multi-finger taps run
/// undo/redo. A finger never leaves ink.

#if targetEnvironment(macCatalyst) || canImport(UIKit)
/// Publishes the board's pan/zoom to the observable viewport.
final class WhiteboardHostView: CanvasHostView, CanvasViewportHost {
    var viewport: CanvasViewport? {
        didSet {
            guard viewport !== oldValue else { return }
            if oldValue?.host === self { oldValue?.host = nil }
            viewport?.host = self
        }
    }

    func requestViewportSync() { setNeedsLayout() }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Zoomed all the way out the board fills the view, rather than
        // shrinking into the top-left corner with empty space beside it.
        if let canvas, bounds.width > 0, bounds.height > 0 {
            let fill = max(bounds.width, bounds.height) / WhiteboardCanvasView.boardSize
            if canvas.minimumZoomScale != fill { canvas.minimumZoomScale = fill }
        }
        publishViewport(deferred: true)
    }

    func publishViewport(deferred: Bool = false) {
        guard canvas != nil, let viewport else { return }
        let apply = { [weak self] in
            // Read when it lands, not when it was queued (see the paged host).
            guard let self, self.viewport === viewport, let canvas = self.canvas else { return }
            let scale = canvas.zoomScale
            let offset = canvas.contentOffset
            if viewport.zoomScale != scale { viewport.zoomScale = scale }
            if viewport.contentOffset != offset { viewport.contentOffset = offset }
            if !viewport.hasSynced { viewport.hasSynced = true }
        }
        if deferred { DispatchQueue.main.async(execute: apply) } else { apply() }
    }
}

struct WhiteboardCanvasView: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView
    var onDrawingChanged: () -> Void = {}
    /// Apple Pencil (Pro) double-tap: parent toggles the eraser.
    var onPencilDoubleTap: () -> Void = {}
    /// Apple Pencil Pro squeeze: parent opens the colour options.
    var onPencilSqueeze: () -> Void = {}
    /// Solid / dashed / dotted for shapes made by holding a stroke still.
    var shapeLineStyle: ShapeLineStyle = .solid
    /// Shows what a held stroke will snap to, as on a paged page.
    var onShapePreview: (ShapeRecognizer.RecognizedShape?) -> Void = { _ in }
    /// The board's pan/zoom, published for the lasso's SwiftUI overlay.
    /// Same contract as the paged canvas: drawing coordinates are
    /// (contentOffset + view point) / zoomScale, so the overlay is drawn
    /// in board coordinates through a `PageViewportLayer` (boardSize
    /// square) rather than hosted inside the scroll view - one overlay
    /// path for both page kinds, and the pan/zoom stays PencilKit's.
    var viewport: CanvasViewport? = nil
    /// The lasso's selection, shared with the paged canvas.
    var inkSelection: InkSelectionController? = nil

    static let boardSize: CGFloat = 3000
    private static let contentSize = CGSize(width: boardSize, height: boardSize)

    func makeUIView(context: Context) -> WhiteboardHostView {
        let host = WhiteboardHostView()
        host.backgroundColor = .white
        host.viewport = viewport

        configure(canvasView, context: context)
        // canvasView.tool is owned by the parent's applyToolState().
        host.embed(canvasView)

        context.coordinator.canvas = canvasView
        context.coordinator.installShortcuts(on: host)
        context.coordinator.installShapeHold(on: host)
        context.coordinator.shapeSnap.lineStyle = shapeLineStyle
        context.coordinator.shapeSnap.onPreview = onShapePreview
        context.coordinator.host = host
        attachInkSelection(to: host)

        DispatchQueue.main.async {
            // becomeFirstResponder can silently fail before the view is in a
            // window - defer one tick.
            self.canvasView.becomeFirstResponder()
            // Start at the board's top-left working area.
            self.canvasView.setZoomScale(1, animated: false)
            self.canvasView.setContentOffset(.zero, animated: false)
        }

        return host
    }

    func updateUIView(_ host: WhiteboardHostView, context: Context) {
        context.coordinator.host = host
        host.viewport = viewport
        context.coordinator.onDrawingChanged = onDrawingChanged
        context.coordinator.shortcuts.onPencilDoubleTap = onPencilDoubleTap
        context.coordinator.shortcuts.onPencilSqueeze = onPencilSqueeze
        context.coordinator.canvas = canvasView

        // Each whiteboard brings its own fresh canvas (see PageCanvasView);
        // when one arrives, put it in and start it at the top-left like a
        // newly opened board.
        let canvasChanged = host.canvas !== canvasView
        host.embed(canvasView)
        configure(canvasView, context: context)
        context.coordinator.installShortcuts(on: host)
        context.coordinator.installShapeHold(on: host)
        context.coordinator.shapeSnap.lineStyle = shapeLineStyle
        context.coordinator.shapeSnap.onPreview = onShapePreview
        attachInkSelection(to: host)

        if canvasChanged {
            DispatchQueue.main.async {
                self.canvasView.becomeFirstResponder()
                self.canvasView.setZoomScale(1, animated: false)
                self.canvasView.setContentOffset(.zero, animated: false)
            }
        }
    }

    static func dismantleUIView(_ host: WhiteboardHostView, coordinator: Coordinator) {
        coordinator.shortcuts.removeAll()
        coordinator.removeShapeHold()
        host.viewport = nil
        host.inkSelection = nil
    }

    /// Runs on every update, so it only writes what differs.
    private func attachInkSelection(to host: WhiteboardHostView) {
        guard let inkSelection else { return }
        inkSelection.install(on: host)
        inkSelection.canvas = canvasView
        if host.inkSelection !== inkSelection { host.inkSelection = inkSelection }
    }

    private func configure(_ canvas: PKCanvasView, context: Context) {
        canvas.drawingPolicy = .mystNotes           // finger pans on an iPad; the mouse draws on a Mac
        canvas.backgroundColor = .white
        canvas.isOpaque = true
        canvas.delegate = context.coordinator

        // PencilKit auto-inverts ink in dark mode (assumes a black canvas);
        // the board is always a fixed white background - pin it to light.
        canvas.overrideUserInterfaceStyle = .light

        // Drive the large board through the canvas's own scroll view.
        // Guarded: the lasso gates the pan itself while ink is selected.
        if !canvas.isScrollEnabled { canvas.isScrollEnabled = true }
        // Zoom multiplies the content size, so the board's size is only set
        // at zoom 1 (a fresh canvas). This runs on every SwiftUI update; at
        // 2x it used to put back 3000 over the 6000 the zoom had made, and
        // half the board could no longer be reached.
        if canvas.zoomScale == 1, canvas.contentSize != Self.contentSize { canvas.contentSize = Self.contentSize }
        canvas.maximumZoomScale = 4.0
        canvas.bouncesZoom = true
        canvas.alwaysBounceVertical = false
        canvas.alwaysBounceHorizontal = false
        canvas.showsVerticalScrollIndicator = true
        canvas.showsHorizontalScrollIndicator = true
        // The nav bar / safe area must not nudge content while you're
        // mid-stroke - that was part of "the writing keeps moving".
        canvas.contentInsetAdjustmentBehavior = .never
        // One finger pans (a finger never draws on the board); two fingers
        // pinch-zoom. On a Mac the pointer draws, so it never pans - the
        // trackpad and scroll wheel move the board instead.
        canvas.panGestureRecognizer.minimumNumberOfTouches = CanvasInput.isMac ? 2 : 1
        canvas.panGestureRecognizer.maximumNumberOfTouches = 2
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onDrawingChanged: onDrawingChanged)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIGestureRecognizerDelegate {
        var onDrawingChanged: () -> Void
        weak var canvas: PKCanvasView?
        weak var host: WhiteboardHostView?
        let shortcuts = CanvasShortcutInstaller()
        // Hold-to-snap works here too; there's just no page-space overlay
        // to preview in, so the haptic is the only cue before the lift.
        let shapeHold = ShapeHoldRecognizer()
        let shapeSnap = ShapeSnapController()
        private var isApplyingScribbleErase = false
        private var isApplyingShapeSnap = false

        init(onDrawingChanged: @escaping () -> Void) {
            self.onDrawingChanged = onDrawingChanged
            super.init()
            shortcuts.onUndo = { [weak self] in self?.canvas?.undoManager?.undo() }
            shortcuts.onRedo = { [weak self] in self?.canvas?.undoManager?.redo() }
            shapeSnap.attach(to: shapeHold)
        }

        func installShortcuts(on host: UIView) {
            shortcuts.install(on: host)
        }

        func installShapeHold(on host: UIView) {
            shapeHold.canvas = canvas
            guard shapeHold.view !== host else { return }
            shapeHold.view?.removeGestureRecognizer(shapeHold)
            shapeHold.delegate = self
            host.addGestureRecognizer(shapeHold)
        }

        func removeShapeHold() {
            shapeHold.view?.removeGestureRecognizer(shapeHold)
            shapeSnap.clear()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) { host?.publishViewport() }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { host?.publishViewport() }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            if !isApplyingShapeSnap, shapeSnap.pending != nil {
                isApplyingShapeSnap = true
                defer { isApplyingShapeSnap = false }
                if shapeSnap.applyIfPending(to: canvasView) {
                    onDrawingChanged()
                    return
                }
            }
            if !isApplyingScribbleErase, !isApplyingShapeSnap,
               canvasView.tool is PKInkingTool,
               let latest = canvasView.drawing.strokes.last,
               ScribbleErase.isScribble(latest),
               let cleaned = ScribbleErase.applying(latest, to: canvasView.drawing) {
                isApplyingScribbleErase = true
                canvasView.setDrawingUndoably(cleaned)
                DispatchQueue.main.async { [weak self] in self?.isApplyingScribbleErase = false }
            }
            onDrawingChanged()
        }
    }
}
#else
// Native macOS AppKit - PencilKit not available natively
struct WhiteboardCanvasView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.frame = NSRect(x: 0, y: 0, width: 3000, height: 3000)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
