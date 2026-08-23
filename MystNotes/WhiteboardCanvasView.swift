import SwiftUI
import PencilKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A bounded "large canvas" for whiteboard-type pages: a big (but finite,
/// 3000x3000pt) PKCanvasView inside a zoomable UIScrollView. This is NOT
/// true infinite canvas (see the project plan's canvas-model decision) —
/// big enough to feel that way for brainstorming without needing viewport
/// virtualization.

#if targetEnvironment(macCatalyst) || canImport(UIKit)
// iPad or Mac Catalyst - UIKit available
struct WhiteboardCanvasView: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView
    var toolPicker: PKToolPicker
    var onDrawingChanged: () -> Void = {}

    static let boardSize: CGFloat = 3000

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.minimumZoomScale = 0.25
        scrollView.maximumZoomScale = 2.0
        scrollView.delegate = context.coordinator
        scrollView.bouncesZoom = true

        canvasView.drawingPolicy = .anyInput
        canvasView.backgroundColor = .white
        canvasView.tool = PKInkingTool(.pen, color: .black, width: 4)
        canvasView.delegate = context.coordinator
        canvasView.frame = CGRect(x: 0, y: 0, width: Self.boardSize, height: Self.boardSize)

        scrollView.contentSize = canvasView.frame.size
        scrollView.addSubview(canvasView)

        toolPicker.setVisible(true, forFirstResponder: canvasView)
        toolPicker.addObserver(canvasView)
        canvasView.becomeFirstResponder()

        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        // canvasView.drawing is swapped directly by the parent view when
        // switching pages; the scroll view itself needs no updates here.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(canvasView: canvasView, onDrawingChanged: onDrawingChanged)
    }

    class Coordinator: NSObject, UIScrollViewDelegate, PKCanvasViewDelegate {
        var canvasView: PKCanvasView
        var onDrawingChanged: () -> Void

        init(canvasView: PKCanvasView, onDrawingChanged: @escaping () -> Void) {
            self.canvasView = canvasView
            self.onDrawingChanged = onDrawingChanged
        }

        // MARK: - UIScrollViewDelegate
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            canvasView
        }

        // MARK: - PKCanvasViewDelegate
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            onDrawingChanged()
        }
    }
}
#else
// Native macOS AppKit - PencilKit not available natively
struct WhiteboardCanvasView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        // Placeholder for macOS (native) - PencilKit not available
        let view = NSView()
        view.frame = NSRect(x: 0, y: 0, width: 3000, height: 3000)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Update logic for macOS
    }
}
#endif