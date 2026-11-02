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
/// On a Mac there's no second finger to pinch with, so the host also
/// answers the View menu's Zoom In / Zoom Out / Zoom to Fit (⌘+ ⌘- ⌘0) and
/// ⌘/⌥-scroll-wheel - see `CanvasHostView`.
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

    /// "Draw with finger", as last applied by the representable. Written
    /// only when it differs; the pan requirement follows it.
    var fingerDrawing = false {
        didSet {
            guard fingerDrawing != oldValue else { return }
            updatePanTouchRequirement()
        }
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
            let isNewPage = lastFittedBounds == .zero
            lastFittedBounds = bounds.size
            if isNewPage { fitPage() } else { resizeKeepingZoom() }
        } else {
            centerPage()
        }
        publishViewport(deferred: true)
    }

    /// Reset to "the whole page is visible", which is where opening a page
    /// should always land.
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

    /// The view changed size on the same page (the page strip shown,
    /// hidden or dragged taller, a window resized, the iPad rotated). A
    /// page at fit is fitted again; a zoomed-in page keeps its zoom and the
    /// page point at the top-left of the view.
    private func resizeKeepingZoom() {
        guard let canvas else { return }
        let oldFit = canvas.minimumZoomScale
        guard canvas.zoomScale > oldFit * 1.001 else { fitPage(); return }
        isApplyingGeometry = true
        defer { isApplyingGeometry = false }

        let oldZoom = canvas.zoomScale
        let anchor = CGPoint(x: (canvas.contentOffset.x + canvas.contentInset.left) / oldZoom,
                             y: (canvas.contentOffset.y + canvas.contentInset.top) / oldZoom)
        let fit = PageGeometry.fitScale(contentSize: pageSize, in: bounds.size)
        canvas.minimumZoomScale = fit
        canvas.maximumZoomScale = fit * PageGeometry.maximumZoomFactor
        canvas.setZoomScale(min(max(oldZoom, fit), fit * PageGeometry.maximumZoomFactor), animated: false)
        centerPage()
        let zoom = canvas.zoomScale
        let inset = canvas.contentInset
        let maxX = max(-inset.left, pageSize.width * zoom + inset.right - bounds.width)
        let maxY = max(-inset.top, pageSize.height * zoom + inset.bottom - bounds.height)
        canvas.setContentOffset(
            CGPoint(x: min(max(anchor.x * zoom - inset.left, -inset.left), maxX),
                    y: min(max(anchor.y * zoom - inset.top, -inset.top), maxY)),
            animated: false
        )
    }

    /// `CanvasZoomCommand.reset` (⌘0) puts the whole page back on screen.
    override var defaultZoomScale: CGFloat {
        canvas?.minimumZoomScale ?? 1
    }

    /// One finger pans the page only when there's something to pan - that
    /// is, zoomed in past the fit.
    ///
    /// At the fit the page already fills the view and can't scroll, so a
    /// one-finger pan there would claim drags it has no use for and lose to
    /// iPadOS's full-width back swipe anyway: a left-to-right drag anywhere
    /// on the page popped straight out of the notebook. Two fingers pan and
    /// pinch at every scale, the way Procreate moves its canvas.
    ///
    /// On a Mac the pointer is the pen (`PKCanvasViewDrawingPolicy.mystNotes`),
    /// so a drag never pans: the page moves with the trackpad and scroll
    /// wheel, which the host handles itself (`CanvasHostView.handleWheel`),
    /// and with Space + drag. A one-touch pan here is what took the drag
    /// away from the ink.
    /// Pure, so a test can drive it. A finger that draws can't also pan.
    nonisolated static func panTouches(zoomedIn: Bool, isMac: Bool, fingerDrawing: Bool) -> Int {
        (zoomedIn && !isMac && !fingerDrawing) ? 1 : 2
    }

    private func updatePanTouchRequirement() {
        guard let canvas else { return }
        let zoomedIn = canvas.zoomScale > canvas.minimumZoomScale * 1.001
        let required = Self.panTouches(zoomedIn: zoomedIn, isMac: CanvasInput.isMac, fingerDrawing: fingerDrawing)
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
        guard canvas != nil, let viewport else { return }
        let identity = pageIdentity
        let apply = { [weak self] in
            // A host that's been dismantled (or re-pointed) since this was
            // queued has nothing valid to say about the page on screen.
            guard let self, self.viewport === viewport, let canvas = self.canvas else { return }
            // Read when it lands, not when it was queued: a deferred publish
            // from a layout pass mid-pinch used to overwrite a newer one with
            // the old zoom, and the overlays sat off the ink until the next
            // scroll.
            let scale = canvas.zoomScale
            let offset = canvas.contentOffset
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

/// One-finger left/right swipe to turn the page. Fingers only, and only
/// while a finger can't draw and the page is at fit (zoomed in, one finger
/// pans). Not on a Mac, where the pointer is the pen. The outgoing page
/// slides off as a snapshot over the incoming one, which is laid out
/// underneath it in the meantime.
final class PageSwipeInstaller: NSObject, UIGestureRecognizerDelegate {
    private let left = UISwipeGestureRecognizer()
    private let right = UISwipeGestureRecognizer()
    /// +1 next, -1 previous; false when there's no page that way.
    private var onSwipe: ((Int) -> Bool)?
    private weak var host: PagedCanvasHostView?

    func install(on host: PagedCanvasHostView, onSwipe: ((Int) -> Bool)?, fingerDrawing: Bool) {
        self.onSwipe = onSwipe
        if self.host !== host {
            remove()
            for (recognizer, direction) in [(left, UISwipeGestureRecognizer.Direction.left), (right, .right)] {
                recognizer.direction = direction
                recognizer.cancelsTouchesInView = false
                recognizer.delegate = self
                recognizer.addTarget(self, action: #selector(handle(_:)))
                host.addGestureRecognizer(recognizer)
            }
            self.host = host
        }
        let enabled = Self.isEnabled(hasHandler: onSwipe != nil, isMac: CanvasInput.isMac,
                                     fingerDrawing: fingerDrawing)
        if left.isEnabled != enabled { left.isEnabled = enabled; right.isEnabled = enabled }
    }

    /// A one-finger swipe turns the page only while a finger can't draw.
    nonisolated static func isEnabled(hasHandler: Bool, isMac: Bool, fingerDrawing: Bool) -> Bool {
        hasHandler && !isMac && !fingerDrawing
    }

    func remove() {
        for recognizer in [left, right] {
            recognizer.view?.removeGestureRecognizer(recognizer)
            recognizer.removeTarget(self, action: nil)
        }
        host = nil
    }

    @objc private func handle(_ recognizer: UISwipeGestureRecognizer) {
        guard recognizer.state == .ended, let onSwipe else { return }
        let step = recognizer.direction == .left ? 1 : -1
        // Taken before the page changes: the paper and pictures are SwiftUI
        // layers behind the host, so only the window has the whole page.
        guard let host, let window = host.window else { _ = onSwipe(step); return }
        let frame = host.convert(host.bounds, to: window)
        guard let snapshot = window.resizableSnapshotView(from: frame, afterScreenUpdates: false,
                                                           withCapInsets: .zero),
              onSwipe(step) else { return }
        let clip = UIView(frame: frame)
        clip.clipsToBounds = true
        clip.isUserInteractionEnabled = false
        snapshot.frame = clip.bounds
        clip.addSubview(snapshot)
        window.addSubview(clip)
        UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            snapshot.transform = CGAffineTransform(translationX: -CGFloat(step) * frame.width, y: 0)
            snapshot.alpha = 0.6
        } completion: { _ in
            clip.removeFromSuperview()
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touch.type == .direct && host?.canvas?.drawingPolicy == .pencilOnly
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let canvas = host?.canvas else { return false }
        return canvas.zoomScale <= canvas.minimumZoomScale * 1.001
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

/// Turns off iPadOS 26's full-screen back swipe while a notebook is open:
/// a sideways drag anywhere on the page left the notebook, mid-pan when
/// zoomed in. The swipe from the left edge still goes back.
struct ContentPopGate: UIViewRepresentable {
    func makeUIView(context: Context) -> GateView { GateView() }
    func updateUIView(_ view: GateView, context: Context) {}

    final class GateView: UIView {
        private weak var gated: UIGestureRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                let nav = sequence(first: self as UIResponder, next: { $0.next })
                    .lazy.compactMap { $0 as? UINavigationController }.first
                gated = nav?.interactiveContentPopGestureRecognizer
                gated?.isEnabled = false
            } else {
                gated?.isEnabled = true
                gated = nil
            }
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
    /// handles for an imported image on this page. Handed the press's
    /// location in the host view's coordinates (`viewport.pagePoint(from:)`
    /// maps it onto the page) so the parent can pick which of several
    /// pictures was pressed.
    var onLongPress: (CGPoint) -> Void = { _ in }
    /// Set while the fill tool is in hand: a tap - finger or Pencil - on
    /// the page, in host coordinates like `onLongPress`. A recognizer on
    /// the host, not a view over the canvas, so two fingers still pan and
    /// pinch the page with the fill tool selected.
    var onFillTap: ((CGPoint) -> Void)? = nil
    /// Apple Pencil (Pro) double-tap: parent toggles the eraser.
    var onPencilDoubleTap: () -> Void = {}
    /// Apple Pencil Pro squeeze: parent opens the colour options.
    var onPencilSqueeze: () -> Void = {}
    /// Hold-to-snap: the shape the current stroke will snap to when the
    /// pencil lifts, or nil when there's none - drawn as a preview over the
    /// page. See `ShapeHoldRecognizer`.
    var onShapePreview: (ShapeRecognizer.RecognizedShape?) -> Void = { _ in }
    /// Solid / dashed / dotted for those snapped shapes.
    var shapeLineStyle: ShapeLineStyle = .solid
    /// An image arrived by paste (⌘V) or a drag from Finder/Files.
    var onPasteImage: (Data) -> Void = { _ in }
    /// The lasso's selection, owned by the detail view (like `viewport`)
    /// so its overlay and toolbar can read it; installed on the host here,
    /// where its recognizers share touches with the Pencil.
    var inkSelection: InkSelectionController? = nil
    /// A one-finger swipe at fit zoom: +1 for the next page, -1 for the
    /// previous; returns false when there's no such page. Nil turns
    /// swiping off.
    var onSwipePage: ((Int) -> Bool)? = nil
    /// "Draw with finger", handed down by the detail view (which observes
    /// the setting) so a change reaches an open page at once.
    var fingerDrawing: Bool = false

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
        context.coordinator.installFillTap(on: host, onTap: onFillTap)
        if host.fingerDrawing != fingerDrawing { host.fingerDrawing = fingerDrawing }
        context.coordinator.pageSwipe.install(on: host, onSwipe: onSwipePage, fingerDrawing: fingerDrawing)
        context.coordinator.installShortcuts(on: host)
        context.coordinator.installShapeHold(on: host)
        context.coordinator.shapeSnap.onPreview = onShapePreview
        context.coordinator.shapeSnap.lineStyle = shapeLineStyle
        host.onPasteImage = onPasteImage
        attachInkSelection(to: host)

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
        context.coordinator.shortcuts.onPencilSqueeze = onPencilSqueeze
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
        context.coordinator.installFillTap(on: host, onTap: onFillTap)
        if host.fingerDrawing != fingerDrawing { host.fingerDrawing = fingerDrawing }
        context.coordinator.pageSwipe.install(on: host, onSwipe: onSwipePage, fingerDrawing: fingerDrawing)
        context.coordinator.installShortcuts(on: host)
        context.coordinator.installShapeHold(on: host)
        context.coordinator.shapeSnap.onPreview = onShapePreview
        context.coordinator.shapeSnap.lineStyle = shapeLineStyle
        host.onPasteImage = onPasteImage
        attachInkSelection(to: host)
        host.apply(pageSize: pageSize, pageIdentity: pageIdentity, forceRefit: canvasChanged)

        if canvasChanged {
            DispatchQueue.main.async {
                self.canvasView.becomeFirstResponder()
            }
        }
    }

    static func dismantleUIView(_ host: PagedCanvasHostView, coordinator: Coordinator) {
        coordinator.shortcuts.removeAll()
        coordinator.removeShapeHold()
        coordinator.removeFillTap()
        coordinator.pageSwipe.remove()
        host.viewport = nil
        host.inkSelection = nil
    }

    /// Only writes what differs - this runs on every update (see
    /// `configure`). The controller's own setters are guarded the same way.
    private func attachInkSelection(to host: PagedCanvasHostView) {
        guard let inkSelection else { return }
        inkSelection.install(on: host)
        inkSelection.canvas = canvasView
        if host.inkSelection !== inkSelection { host.inkSelection = inkSelection }
    }

    /// Runs on **every** SwiftUI update of this representable - which is
    /// every time anything in the (large) detail view changes, including
    /// picking a colour. Each property is therefore only written when it
    /// actually differs: re-setting `drawingPolicy` or
    /// `overrideUserInterfaceStyle` makes PencilKit reconfigure its
    /// recognizers and re-resolve traits, and none of that belongs on the
    /// drawing path.
    private func configure(_ canvas: PKCanvasView, context: Context) {
        // A finger draws on an iPad only with "Draw with finger"; the mouse does on a Mac.
        let policy = PKCanvasViewDrawingPolicy.policy(fingerDrawing: fingerDrawing, isMac: CanvasInput.isMac)
        if canvas.drawingPolicy != policy { canvas.drawingPolicy = policy }
        if canvas.backgroundColor != .clear { canvas.backgroundColor = .clear }
        if canvas.isOpaque { canvas.isOpaque = false }
        if canvas.delegate !== context.coordinator { canvas.delegate = context.coordinator }

        // PencilKit auto-inverts ink in dark mode (it assumes a black
        // canvas); the page is always a light paper background, so pin the
        // canvas to light - see the dark-mode ink history in git.
        if canvas.overrideUserInterfaceStyle != .light { canvas.overrideUserInterfaceStyle = .light }

        // The page scrolls and zooms inside the canvas's own scroll view.
        // `isScrollEnabled` stands down the pan only; the pinch has to be
        // told separately or it keeps zooming the page under the image
        // handles. (Selected ink gates both itself, synchronously - see
        // `InkSelectionController.gateCanvasGestures`.)
        if canvas.isScrollEnabled != isZoomEnabled { canvas.isScrollEnabled = isZoomEnabled }
        if let pinch = canvas.pinchGestureRecognizer, pinch.isEnabled != isZoomEnabled {
            pinch.isEnabled = isZoomEnabled
        }
        if !canvas.bouncesZoom { canvas.bouncesZoom = true }
        if canvas.alwaysBounceVertical { canvas.alwaysBounceVertical = false }
        if canvas.alwaysBounceHorizontal { canvas.alwaysBounceHorizontal = false }
        if canvas.showsVerticalScrollIndicator { canvas.showsVerticalScrollIndicator = false }
        if canvas.showsHorizontalScrollIndicator { canvas.showsHorizontalScrollIndicator = false }
        // The nav bar / safe area must never nudge the page mid-stroke.
        if canvas.contentInsetAdjustmentBehavior != .never { canvas.contentInsetAdjustmentBehavior = .never }
        // Two fingers pan and pinch; one finger joins in only once you're
        // zoomed past the fit (see updatePanTouchRequirement). A finger
        // never inks either way.
        if canvas.panGestureRecognizer.maximumNumberOfTouches != 2 {
            canvas.panGestureRecognizer.maximumNumberOfTouches = 2
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onDrawingChanged: onDrawingChanged, onLongPress: onLongPress)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIGestureRecognizerDelegate {
        var onDrawingChanged: () -> Void
        var onLongPress: (CGPoint) -> Void
        weak var canvas: PKCanvasView?
        weak var host: PagedCanvasHostView?
        let shortcuts = CanvasShortcutInstaller()
        let shapeHold = ShapeHoldRecognizer()
        let shapeSnap = ShapeSnapController()
        let pageSwipe = PageSwipeInstaller()
        private weak var longPressRecognizer: UILongPressGestureRecognizer?
        private let fillTap = UITapGestureRecognizer()
        private var onFillTap: ((CGPoint) -> Void)?
        private var isApplyingScribbleErase = false
        private var isApplyingShapeSnap = false

        init(onDrawingChanged: @escaping () -> Void, onLongPress: @escaping (CGPoint) -> Void) {
            self.onDrawingChanged = onDrawingChanged
            self.onLongPress = onLongPress
            super.init()
            shortcuts.onUndo = { [weak self] in self?.canvas?.undoManager?.undo() }
            shortcuts.onRedo = { [weak self] in self?.canvas?.undoManager?.redo() }
            shapeSnap.attach(to: shapeHold)
        }

        func installShortcuts(on host: UIView) {
            shortcuts.install(on: host)
        }

        /// Idempotent, like the others. The recognizer reads the canvas for
        /// its drawing policy and zoom, so it follows a swapped-in canvas.
        func installShapeHold(on host: UIView) {
            shapeHold.canvas = canvas
            guard shapeHold.view !== host else { return }
            // Moving between hosts mid-touch would strand the tracked touch.
            shapeHold.clearTrackedState()
            shapeHold.view?.removeGestureRecognizer(shapeHold)
            shapeHold.delegate = self
            host.addGestureRecognizer(shapeHold)
        }

        func removeShapeHold() {
            shapeHold.view?.removeGestureRecognizer(shapeHold)
            shapeSnap.clear()
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

        /// Idempotent. Enabled only while the fill tool is in hand.
        func installFillTap(on host: UIView, onTap: ((CGPoint) -> Void)?) {
            onFillTap = onTap
            if fillTap.view !== host {
                fillTap.view?.removeGestureRecognizer(fillTap)
                fillTap.removeTarget(nil, action: nil)
                fillTap.addTarget(self, action: #selector(handleFillTap(_:)))
                fillTap.cancelsTouchesInView = false
                fillTap.delegate = self
                host.addGestureRecognizer(fillTap)
            }
            if fillTap.isEnabled != (onTap != nil) { fillTap.isEnabled = onTap != nil }
        }

        func removeFillTap() {
            fillTap.view?.removeGestureRecognizer(fillTap)
        }

        @objc private func handleFillTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            onFillTap?(recognizer.location(in: recognizer.view))
        }

        @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began else { return }
            onLongPress(recognizer.location(in: recognizer.view))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        // MARK: PKCanvasViewDelegate

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // A held stroke has just been committed: swap it for its shape
            // before anything else looks at it.
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
