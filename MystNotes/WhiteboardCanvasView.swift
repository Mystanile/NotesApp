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
struct WhiteboardCanvasView: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView
    var onDrawingChanged: () -> Void = {}
    /// Apple Pencil (Pro) double-tap: parent toggles the eraser.
    var onPencilDoubleTap: () -> Void = {}

    static let boardSize: CGFloat = 3000
    private static let contentSize = CGSize(width: boardSize, height: boardSize)

    func makeUIView(context: Context) -> CanvasHostView {
        let host = CanvasHostView()
        host.backgroundColor = .white

        configure(canvasView, context: context)
        // canvasView.tool is owned by the parent's applyToolState().
        host.embed(canvasView)

        context.coordinator.canvas = canvasView
        context.coordinator.installShortcuts(on: host)

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

    func updateUIView(_ host: CanvasHostView, context: Context) {
        context.coordinator.onDrawingChanged = onDrawingChanged
        context.coordinator.shortcuts.onPencilDoubleTap = onPencilDoubleTap
        context.coordinator.canvas = canvasView

        // Each whiteboard brings its own fresh canvas (see PageCanvasView);
        // when one arrives, put it in and start it at the top-left like a
        // newly opened board.
        let canvasChanged = host.canvas !== canvasView
        host.embed(canvasView)
        configure(canvasView, context: context)
        context.coordinator.installShortcuts(on: host)

        if canvasChanged {
            DispatchQueue.main.async {
                self.canvasView.becomeFirstResponder()
                self.canvasView.setZoomScale(1, animated: false)
                self.canvasView.setContentOffset(.zero, animated: false)
            }
        }
    }

    static func dismantleUIView(_ host: CanvasHostView, coordinator: Coordinator) {
        coordinator.shortcuts.removeAll()
    }

    private func configure(_ canvas: PKCanvasView, context: Context) {
        canvas.drawingPolicy = .pencilOnly          // finger pans, never draws
        canvas.backgroundColor = .white
        canvas.isOpaque = true
        canvas.delegate = context.coordinator

        // PencilKit auto-inverts ink in dark mode (assumes a black canvas);
        // the board is always a fixed white background - pin it to light.
        canvas.overrideUserInterfaceStyle = .light

        // Drive the large board through the canvas's own scroll view.
        canvas.isScrollEnabled = true
        if canvas.contentSize != Self.contentSize { canvas.contentSize = Self.contentSize }
        canvas.minimumZoomScale = 0.25
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
        // pinch-zoom.
        canvas.panGestureRecognizer.minimumNumberOfTouches = 1
        canvas.panGestureRecognizer.maximumNumberOfTouches = 2
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onDrawingChanged: onDrawingChanged)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var onDrawingChanged: () -> Void
        weak var canvas: PKCanvasView?
        let shortcuts = CanvasShortcutInstaller()
        private var isApplyingScribbleErase = false

        init(onDrawingChanged: @escaping () -> Void) {
            self.onDrawingChanged = onDrawingChanged
            super.init()
            shortcuts.onUndo = { [weak self] in self?.canvas?.undoManager?.undo() }
            shortcuts.onRedo = { [weak self] in self?.canvas?.undoManager?.redo() }
        }

        func installShortcuts(on host: UIView) {
            shortcuts.install(on: host)
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            if !isApplyingScribbleErase,
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
