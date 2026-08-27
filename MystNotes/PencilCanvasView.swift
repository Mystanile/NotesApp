import SwiftUI
#if targetEnvironment(macCatalyst) || canImport(UIKit)
import UIKit
import PencilKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Wraps PKCanvasView for use in SwiftUI. Tool selection is driven entirely
/// by `NotebookDetailView`'s `DrawingToolState`/`DrawingToolbarView` (our
/// own custom UI) rather than Apple's system `PKToolPicker` - this view
/// never shows one. A delegate callback fires on every stroke change (used
/// for debounced autosave and undo/redo button state in the parent view).
#if targetEnvironment(macCatalyst) || canImport(UIKit)
struct PencilCanvasView: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView
    var onDrawingChanged: () -> Void = {}

    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.drawingPolicy = .anyInput   // allow Pencil, finger, and (on Catalyst) mouse/trackpad
        canvasView.backgroundColor = .clear
        canvasView.tool = AppSettings.initialTool()   // starting tool/color/width; DrawingToolbarView takes over from here
        canvasView.delegate = context.coordinator

        // PencilKit deliberately auto-inverts ink colors in dark mode - it
        // assumes a black canvas and swaps black strokes to white (and vice
        // versa) so they stay visible, regardless of what UIColor a tool was
        // built with. The page itself is always a light paper background
        // here (PageBackgroundView/ImportedPageBackgroundView don't invert
        // for dark mode), so that assumption is wrong for this app - pin
        // the canvas to light so PencilKit stops "fixing" ink that was never
        // actually invisible.
        canvasView.overrideUserInterfaceStyle = .light

        // becomeFirstResponder() can silently fail if called before the view
        // is actually attached to a window (i.e. right at construction time
        // here) - Pencil/touch input then doesn't reliably start working
        // until some later event happens to re-trigger the responder chain.
        // Deferring one tick, after this view has actually been placed in
        // the hierarchy, makes it succeed immediately instead.
        DispatchQueue.main.async {
            canvasView.becomeFirstResponder()
        }

        return canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        // canvasView.drawing is swapped directly by the parent view when
        // switching pages, so there's nothing to sync here.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onDrawingChanged: onDrawingChanged)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let onDrawingChanged: () -> Void

        init(onDrawingChanged: @escaping () -> Void) {
            self.onDrawingChanged = onDrawingChanged
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            onDrawingChanged()
        }
    }
}
#else
// Native macOS AppKit - PencilKit not available natively
struct PencilCanvasView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        // Placeholder for macOS (native) - PencilKit not available
        let view = NSView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Update logic for macOS
    }
}
#endif