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
///
/// A paged page is a real, fixed-size *document page* (see `PageGeometry`),
/// not "whatever rectangle is left on screen". The canvas view itself fills
/// the available area, but its scroll-view content is the page, sized in
/// page points and centred: at the fit scale the whole page is visible with
/// the desk showing around it, and a two-finger pinch zooms in up to 5x fit
/// with a single finger panning. Driving the zoom through the canvas's own
/// scroll view (rather than a SwiftUI `.scaleEffect`) is what keeps zoomed
/// ink crisp - PencilKit re-renders the drawing at the new scale.
///
/// Drawing is **Pencil-only** here (and on the whiteboard) - a finger never
/// leaves ink. That keeps the multi-finger undo/redo taps, the pan and
/// scribble-to-erase from ever being mistaken for drawing, and matches how
/// GoodNotes / Freeform behave with a Pencil paired.
///
/// The canvas is pinned inside a `PagedCanvasHostView`; the finger/Pencil
/// shortcut recognizers live on that host, not on the canvas, because
/// recognizers added straight to a `PKCanvasView` are starved of touches by
/// PencilKit's own drawing recognizer.
#if targetEnvironment(macCatalyst) || canImport(UIKit)

/// The container the paged `PKCanvasView` lives in. It owns the page-fitting
/// maths - the content size, the zoom range, and the insets that keep the
/// page centred at every scale - and publishes the resulting pan/zoom so the
/// layers drawn behind and above the ink can follow it exactly.
final class PagedCanvasHostView: CanvasHostView, CanvasViewportHost {
    var viewport: CanvasViewport? {
        didSet {
            guard viewport !== oldValue else { return }
            // Only let go of a viewport we still own - SwiftUI can make the
            // next host before it dismantles this one.
            if oldValue?.host === self { oldValue?.host = nil }
            viewport?.host = self
        }
    }

    func requestViewportSync() {
        setNeedsLayout()
    }

    private var pageSize: CGSize = .zero
    private var pageIdentity: UUID?
    private var lastFittedBounds: CGSize = .zero
    /// True while we're the ones moving the scroll view, so the resulting
    /// delegate callbacks don't publish state changes in the middle of a
    /// SwiftUI update pass.
    private var isApplyingGeometry = false

    /// Called from `updateUIView`. Refitting is deliberately limited to a
    /// genuine change (different page, different page shape, resized
    /// window) - doing it on every SwiftUI update would yank the zoom back
    /// to fit while you're working.
    ///
    /// `forceRefit` is for a brand-new canvas view arriving for the same
    /// page: it starts at zoom 1 with no content size, so it has to be
    /// fitted even though nothing about the page changed.
    func apply(pageSize newSize: CGSize, pageIdentity newIdentity: UUID?, forceRefit: Bool = false) {
        let changed = newSize != pageSize || newIdentity != pageIdentity || forceRefit
        pageSize = newSize
        pageIdentity = newIdentity
        guard changed else { return }
        lastFittedBounds = .zero        // force a refit on the next layout
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard canvas != nil, bounds.width > 0, bounds.height > 0,
              pageSize.width > 0, pageSize.height > 0 else { return }

        if bounds.size != lastFittedBounds {
            lastFittedBounds = bounds.size
            fitPage()
        } else {
            centerPage()
        }
        publishViewport(deferred: true)
    }

    /// Reset to "the whole page is visible", which is where opening a page
    /// (or rotating the iPad) should always land.
    private func fitPage() {
        guard let canvas else { return }
        isApplyingGeometry = true
        defer { isApplyingGeometry = false }

        let fit = PageGeometry.fitScale(contentSize: pageSize, in: bounds.size)
        // Zoom scale multiplies content size, so the content size has to be
        // set in unzoomed page points.
        canvas.minimumZoomScale = 0.01
        canvas.maximumZoomScale = 100
        canvas.setZoomScale(1, animated: false)
        canvas.contentSize = pageSize
        canvas.minimumZoomScale = fit
        canvas.maximumZoomScale = fit * PageGeometry.maximumZoomFactor
        canvas.setZoomScale(fit, animated: false)
        centerPage()
        canvas.setContentOffset(
            CGPoint(x: -canvas.contentInset.left, y: -canvas.contentInset.top),
            animated: false
        )
    }

    /// One finger pans the page only when there's something to pan - that
    /// is, zoomed in past the fit.
    ///
    /// At the fit the page already fills the view and can't scroll, so a
    /// one-finger pan there would claim drags it has no use for and lose to
    /// iPadOS's full-width back swipe anyway: a left-to-right drag anywhere
    /// on the page popped straight out of the notebook. Two fingers pan and
    /// pinch at every scale, the way Procreate moves its canvas.
    private func updatePanTouchRequirement() {
        guard let canvas else { return }
        let zoomedIn = canvas.zoomScale > canvas.minimumZoomScale * 1.001
        let required = zoomedIn ? 1 : 2
        if canvas.panGestureRecognizer.minimumNumberOfTouches != required {
            canvas.panGestureRecognizer.minimumNumberOfTouches = required
        }
    }

    /// Keeps the page in the middle of the canvas whenever it's smaller than
    /// the visible area - without this it clings to the top-left corner as
    /// you zoom back out.
    func centerPage() {
        guard let canvas else { return }
        let zoomed = CGSize(width: pageSize.width * canvas.zoomScale,
                            height: pageSize.height * canvas.zoomScale)
        let insetX = max(0, (bounds.width - zoomed.width) / 2)
        let insetY = max(0, (bounds.height - zoomed.height) / 2)
        let inset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
        if canvas.contentInset != inset {
            let wasApplying = isApplyingGeometry
            isApplyingGeometry = true
            canvas.contentInset = inset
            isApplyingGeometry = wasApplying
        }
        updatePanTouchRequirement()
    }

    /// Hands the current pan/zoom to the observable viewport the SwiftUI
    /// layers read.
    func publishViewport(deferred: Bool = false) {
        guard let canvas, let viewport else { return }
        let scale = canvas.zoomScale
        let offset = canvas.contentOffset
        let identity = pageIdentity
        let apply = { [weak self] in
            // A host that's been dismantled (or re-pointed) since this was
            // queued has nothing valid to say about the page on screen.
            guard let self, self.viewport === viewport else { return }
            if viewport.zoomScale != scale { viewport.zoomScale = scale }
            if viewport.contentOffset != offset { viewport.contentOffset = offset }
            let isExpectedPage = viewport.expectedPage == nil || viewport.expectedPage == identity
            if !viewport.hasSynced, isExpectedPage { viewport.hasSynced = true }
        }
        // Publishing straight out of layoutSubviews (or out of a scroll
        // callback we provoked ourselves) would be a state write inside a
        // SwiftUI update; everything else is a real user gesture and has to
        // land in the same frame as the ink.
        if deferred || isApplyingGeometry {
            DispatchQueue.main.async(execute: apply)
        } else {
            apply()
        }
    }
}

struct PencilCanvasView: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView
    /// The page's own coordinate space - what ink, element frames and
    /// artwork fractions are all measured in.
    var pageSize: CGSize
    /// Identifies which page is on screen, so switching pages refits.
    var pageIdentity: UUID?
    /// Published pan/zoom, read by the background/element layers.
    var viewport: CanvasViewport
    /// Pinch/pan are stood down while artwork is being placed, so the
    /// handles aren't fighting the scroll view for the same two fingers.
    var isZoomEnabled: Bool = true
    var onDrawingChanged: () -> Void = {}
    /// Long-press anywhere on the canvas - used to re-open the adjust
    /// handles for an imported image on this page.
    var onLongPress: () -> Void = {}
    /// Apple Pencil (Pro) double-tap: parent toggles the eraser.
    var onPencilDoubleTap: () -> Void = {}

    func makeUIView(context: Context) -> PagedCanvasHostView {
        let host = PagedCanvasHostView()
        host.backgroundColor = .clear
        host.clipsToBounds = true
        host.viewport = viewport

        configure(canvasView, context: context)
        // canvasView.tool is owned entirely by the parent's applyToolState()
        // (seeded from the same AppSettings defaults, kept live by the
        // toolbar) - setting it here too would just fight that and flash the
        // default tool when switching page types.
        host.embed(canvasView)

        context.coordinator.canvas = canvasView
        context.coordinator.host = host
        context.coordinator.attachLongPress(to: host)
        context.coordinator.installShortcuts(on: host)

        host.apply(pageSize: pageSize, pageIdentity: pageIdentity)

        // becomeFirstResponder() can silently fail if called before the view
        // is actually attached to a window - defer one tick.
        DispatchQueue.main.async {
            self.canvasView.becomeFirstResponder()
        }

        return host
    }

    func updateUIView(_ host: PagedCanvasHostView, context: Context) {
        context.coordinator.onDrawingChanged = onDrawingChanged
        context.coordinator.onLongPress = onLongPress
        context.coordinator.shortcuts.onPencilDoubleTap = onPencilDoubleTap
        context.coordinator.canvas = canvasView
        context.coordinator.host = host
        host.viewport = viewport

        // Every page brings its own, freshly made canvas view (see
        // PageCanvasView). It arrives unfitted, so swap it in and lay the
        // page out for it from scratch.
        let canvasChanged = host.canvas !== canvasView
        host.embed(canvasView)
        configure(canvasView, context: context)
        context.coordinator.attachLongPress(to: host)
        context.coordinator.installShortcuts(on: host)
        host.apply(pageSize: pageSize, pageIdentity: pageIdentity, forceRefit: canvasChanged)

        if canvasChanged {
            DispatchQueue.main.async {
                self.canvasView.becomeFirstResponder()
            }
        }
    }

    static func dismantleUIView(_ host: PagedCanvasHostView, coordinator: Coordinator) {
        coordinator.shortcuts.removeAll()
        host.viewport = nil
    }

    private func configure(_ canvas: PKCanvasView, context: Context) {
        canvas.drawingPolicy = .pencilOnly          // finger never draws
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.delegate = context.coordinator

        // PencilKit auto-inverts ink in dark mode (it assumes a black
        // canvas); the page is always a light paper background, so pin the
        // canvas to light - see the dark-mode ink history in git.
        canvas.overrideUserInterfaceStyle = .light

        // The page scrolls and zooms inside the canvas's own scroll view.
        canvas.isScrollEnabled = isZoomEnabled
        canvas.bouncesZoom = true
        canvas.alwaysBounceVertical = false
        canvas.alwaysBounceHorizontal = false
        canvas.showsVerticalScrollIndicator = false
        canvas.showsHorizontalScrollIndicator = false
        // The nav bar / safe area must never nudge the page mid-stroke.
        canvas.contentInsetAdjustmentBehavior = .never
        // Two fingers pan and pinch; one finger joins in only once you're
        // zoomed past the fit (see updatePanTouchRequirement). A finger
        // never inks either way.
        canvas.panGestureRecognizer.maximumNumberOfTouches = 2
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onDrawingChanged: onDrawingChanged, onLongPress: onLongPress)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIGestureRecognizerDelegate {
        var onDrawingChanged: () -> Void
        var onLongPress: () -> Void
        weak var canvas: PKCanvasView?
        weak var host: PagedCanvasHostView?
        let shortcuts = CanvasShortcutInstaller()
        private weak var longPressRecognizer: UILongPressGestureRecognizer?
        private var isApplyingScribbleErase = false

        init(onDrawingChanged: @escaping () -> Void, onLongPress: @escaping () -> Void) {
            self.onDrawingChanged = onDrawingChanged
            self.onLongPress = onLongPress
            super.init()
            shortcuts.onUndo = { [weak self] in self?.canvas?.undoManager?.undo() }
            shortcuts.onRedo = { [weak self] in self?.canvas?.undoManager?.redo() }
        }

        func installShortcuts(on host: UIView) {
            shortcuts.install(on: host)
        }

        /// Idempotent: the host is re-passed on every SwiftUI update.
        func attachLongPress(to view: UIView) {
            if let existing = longPressRecognizer, existing.view === view { return }
            if let existing = longPressRecognizer { existing.view?.removeGestureRecognizer(existing) }

            let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            recognizer.minimumPressDuration = 0.6
            // A single finger is the pan gesture now, so only a stationary
            // press counts - and it must never cancel that pan.
            recognizer.allowableMovement = 12
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            view.addGestureRecognizer(recognizer)
            longPressRecognizer = recognizer
        }

        @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began else { return }
            onLongPress()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        // MARK: PKCanvasViewDelegate

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

        // MARK: UIScrollViewDelegate (PKCanvasViewDelegate refines it)
        //
        // Deliberately no viewForZooming(in:) - PencilKit supplies its own
        // zooming view, and answering that question would break it.

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            host?.publishViewport()
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            host?.centerPage()
            host?.publishViewport()
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
