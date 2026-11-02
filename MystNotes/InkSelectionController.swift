import Foundation
#if targetEnvironment(macCatalyst) || canImport(UIKit)
import UIKit
import PencilKit
import Observation

/// What the overlay draws: the selection's box - four corners in page
/// points, a rotated box once the ink has been turned - and the loop being
/// drawn right now.
struct InkSelectionDisplay: Equatable {
    var corners: [CGPoint]?
    var lasso: [CGPoint] = []
    var hasSelection: Bool { corners != nil }
}

/// The lasso tool's brain: owns the selection on a page's canvas and turns
/// gestures on the host view into `InkSelection` edits.
///
/// While the lasso tool is active the canvas's own drawing gesture is
/// stood down (`isActive`), so the Pencil draws a loop instead of ink.
/// With a selection on screen the canvas's own pan *and pinch* are stood
/// down (`gateCanvasGestures`) - `isScrollEnabled = false` alone leaves
/// the pinch zooming the page under the selection - so a one-finger drag
/// inside the box moves the ink, a **pinch resizes it** and a twist
/// rotates it, all about the selection's own centre, with the page held
/// still. A tap or a Pencil stroke outside the box lets go of it.
///
/// Every gesture step rewrites `canvas.drawing` with the selected strokes'
/// transforms updated - and *nothing removed*. The canvas always holds the
/// whole drawing, so an autosave landing mid-gesture saves complete ink
/// (invariant 1). The step is committed as one undoable change when the
/// last finger lifts.
///
/// The selection is remembered as the strokes' fingerprints, not their
/// indices: a fingerprint survives our own transforms and is simply absent
/// after an undo, an erase or a page change, at which point the selection
/// quietly lets go rather than acting on the wrong strokes.
@Observable
@MainActor
final class InkSelectionController: NSObject {

    private(set) var display = InkSelectionDisplay()
    var hasSelection: Bool { display.hasSelection }
    /// True when the lasso tool is the active tool.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            applyActivity()
            if !isActive { clear() }
        }
    }
    /// After every committed edit, for the autosave.
    @ObservationIgnored var onDrawingChanged: () -> Void = {}
    /// The screen's side of the edit menu (Colour, Copy as Image, Convert to
    /// Text, Link, Make Node). Refreshed by the detail view as it renders;
    /// the menu reads it when it opens.
    @ObservationIgnored var menuActions = SelectionMenuActions()
    func setMenuActions(_ actions: SelectionMenuActions) { menuActions = actions }

    /// The page's canvas. A fresh one arrives with every page, and a
    /// selection never outlives the page it was made on.
    @ObservationIgnored weak var canvas: PKCanvasView? {
        didSet {
            guard canvas !== oldValue else { return }
            oldValue?.drawingGestureRecognizer.isEnabled = true
            Self.gateCanvasGestures(of: oldValue, locked: false)
            clear()
            applyActivity()
        }
    }

    // MARK: Selection state

    @ObservationIgnored private var fingerprints: [StrokeIDMap.Fingerprint] = []
    @ObservationIgnored private var corners: [CGPoint]? {
        didSet {
            display.corners = corners
            if (corners == nil) != (oldValue == nil) {
                Self.gateCanvasGestures(of: canvas, locked: corners != nil)
            }
        }
    }

    /// The page holds still while ink is selected: the scroll view's pan
    /// and pinch are disabled outright, here and now, rather than through
    /// `isScrollEnabled` on the next SwiftUI update - which never reached
    /// the pinch anyway, so a resize used to zoom the whole page with it.
    static func gateCanvasGestures(of canvas: PKCanvasView?, locked: Bool) {
        guard let canvas else { return }
        if canvas.panGestureRecognizer.isEnabled == locked { canvas.panGestureRecognizer.isEnabled = !locked }
        if let pinch = canvas.pinchGestureRecognizer, pinch.isEnabled == locked { pinch.isEnabled = !locked }
    }

    // MARK: Gesture state

    /// The drawing when the current gesture began; every step is applied
    /// to this, so steps don't compound rounding.
    @ObservationIgnored private var base: PKDrawing?
    @ObservationIgnored private var baseCorners: [CGPoint] = []
    @ObservationIgnored private var accumulated = CGAffineTransform.identity
    @ObservationIgnored private var activeGestures = 0

    // MARK: Recognizers

    @ObservationIgnored private let lasso = InkLassoRecognizer()
    @ObservationIgnored private let fingerPan = UIPanGestureRecognizer()
    @ObservationIgnored private let pinch = UIPinchGestureRecognizer()
    @ObservationIgnored private let rotation = UIRotationGestureRecognizer()
    @ObservationIgnored private let tapOutside = UITapGestureRecognizer()
    private var recognizers: [UIGestureRecognizer] { [lasso, fingerPan, pinch, rotation, tapOutside] }
    @ObservationIgnored private weak var host: UIView?
    /// The host as a `CanvasHostView`, which owns the edit menu.
    @ObservationIgnored private weak var menuHost: CanvasHostView?

    override init() {
        super.init()
        // An undo or redo can take the selected strokes away (undoing a
        // paste or duplicate) or move them (undoing a drag): the box must
        // follow, or it sits on screen with nothing in it.
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(undoManagerChanged(_:)), name: name, object: nil)
        }
        lasso.controller = self
        fingerPan.addTarget(self, action: #selector(handlePan(_:)))
        fingerPan.maximumNumberOfTouches = 1
        fingerPan.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        pinch.addTarget(self, action: #selector(handlePinch(_:)))
        rotation.addTarget(self, action: #selector(handleRotation(_:)))
        tapOutside.addTarget(self, action: #selector(handleTap(_:)))
        for recognizer in recognizers {
            recognizer.delegate = self
            recognizer.cancelsTouchesInView = false
            recognizer.isEnabled = false
        }
    }

    /// Idempotent: the host is re-passed on every SwiftUI update.
    func install(on host: UIView) {
        guard self.host !== host else { return }
        if let old = self.host {
            for recognizer in recognizers { old.removeGestureRecognizer(recognizer) }
        }
        self.host = host
        menuHost = host as? CanvasHostView
        for recognizer in recognizers { host.addGestureRecognizer(recognizer) }
    }

    func uninstall() {
        if let host {
            for recognizer in recognizers { host.removeGestureRecognizer(recognizer) }
        }
        menuHost?.dismissSelectionMenu()
        host = nil
        menuHost = nil
    }

    private func applyActivity() {
        canvas?.drawingGestureRecognizer.isEnabled = !isActive
        for recognizer in recognizers { recognizer.isEnabled = isActive }
    }

    // MARK: Selecting

    func clear() {
        menuHost?.dismissSelectionMenu()
        fingerprints = []
        corners = nil
        inkBoundsAfterChange = nil
        base = nil
        accumulated = .identity
        activeGestures = 0
        display.lasso = []
    }

    /// Takes whatever the loop encloses; nothing enclosed, nothing
    /// selected.
    func select(lasso loop: [CGPoint]) {
        display.lasso = []
        guard let canvas else { return clear() }
        let drawing = canvas.drawing
        let indices = InkSelection.strokeIndices(of: drawing, insideLasso: loop)
        guard !indices.isEmpty else { return clear() }
        fingerprints = indices.map { StrokeIDMap.Fingerprint(drawing.strokes[$0]) }
        inkBoundsAfterChange = InkSelection.bounds(of: drawing, indices: indices)
        corners = InkSelection.corners(of: inkBoundsAfterChange!)
        presentMenu()
    }

    /// Selects strokes that are already in the drawing - after a duplicate
    /// or a paste, so the copy can be dragged straight into place.
    private func select(indices: [Int], in drawing: PKDrawing) {
        guard !indices.isEmpty else { return clear() }
        fingerprints = indices.map { StrokeIDMap.Fingerprint(drawing.strokes[$0]) }
        inkBoundsAfterChange = InkSelection.bounds(of: drawing, indices: indices)
        corners = InkSelection.corners(of: inkBoundsAfterChange!)
    }

    /// Where the selected strokes are in the canvas's drawing right now -
    /// or nil, and the selection let go, if any of them is gone.
    private func currentIndices(in drawing: PKDrawing) -> [Int]? {
        guard !fingerprints.isEmpty else { return nil }
        var byPrint: [StrokeIDMap.Fingerprint: Int] = [:]
        for (index, stroke) in drawing.strokes.enumerated() {
            byPrint[StrokeIDMap.Fingerprint(stroke)] = index
        }
        var indices: [Int] = []
        for print in fingerprints {
            guard let index = byPrint[print] else {
                clear()
                return nil
            }
            indices.append(index)
        }
        return indices
    }

    @objc private func undoManagerChanged(_ note: Notification) {
        guard let canvas, (note.object as? UndoManager) === canvas.undoManager, hasSelection, activeGestures == 0 else { return }
        guard let indices = currentIndices(in: canvas.drawing) else { return }  // gone: currentIndices cleared it
        let bounds = InkSelection.bounds(of: canvas.drawing, indices: indices)
        if let known = inkBoundsAfterChange, !Self.same(bounds, known) {
            corners = InkSelection.corners(of: bounds)
            inkBoundsAfterChange = bounds
        }
    }

    /// Where the selected ink was after our own last change to it. Ink
    /// somewhere else means an undo moved it.
    private var inkBoundsAfterChange: CGRect?

    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 && abs(a.maxX - b.maxX) <= 1 && abs(a.maxY - b.maxY) <= 1
    }

    /// Bumped on copy and cut, so a Paste button reading `canPaste`
    /// re-renders; the pasteboard itself is not observable.
    private var clipboardVersion = 0
    var canPaste: Bool {
        _ = clipboardVersion
        return Self.pasteboardHasInk
    }

    func contains(pagePoint: CGPoint) -> Bool {
        guard let corners else { return false }
        return InkSelection.polygon(corners, contains: pagePoint)
    }

    // MARK: Edit menu

    /// Shows the edit menu at the selection. A no-op without a selection or
    /// a host; the host presents on the next run-loop turn, so this is safe
    /// to call from inside a touch callback.
    func presentMenu() {
        guard hasSelection else { return }
        menuHost?.presentSelectionMenu()
    }

    /// The selection's bounding box in `view`'s coordinates - the page
    /// points of `corners` through the zoom and the scroll offset, the
    /// inverse of `pagePoint(canvasPoint:)`.
    func selectionRect(in view: UIView) -> CGRect? {
        guard let canvas, let corners, !corners.isEmpty else { return nil }
        let zoom = max(canvas.zoomScale, 0.0001)
        let points = corners.map { canvas.convert(CGPoint(x: $0.x * zoom, y: $0.y * zoom), to: view) }
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: Gestures, in page points

    /// A pan, pinch or twist has started. Several can run at once (a
    /// pinch is also a pan); the base is taken by the first and the
    /// commit made by the last.
    func beginGesture() {
        menuHost?.dismissSelectionMenu()
        if activeGestures > 0 {
            activeGestures += 1
            return
        }
        guard let canvas else { return }
        let drawing = canvas.drawing
        guard let indices = currentIndices(in: drawing), var corners else { return }
        // An undo since the box was drawn has moved the ink but not the
        // box: start again from where the ink actually is. Judged against
        // where our own last change left the ink, not against the box: a
        // rotated box's centre and the turned ink's upright bounds never
        // match, and every gesture after a rotation threw the rotation away.
        let bounds = InkSelection.bounds(of: drawing, indices: indices)
        if let known = inkBoundsAfterChange, !Self.same(bounds, known) {
            corners = InkSelection.corners(of: bounds)
            self.corners = corners
            inkBoundsAfterChange = bounds
        }
        base = drawing
        baseCorners = corners
        accumulated = .identity
        activeGestures = 1
    }

    func translate(by delta: CGPoint) {
        apply(InkSelection.transform(translation: delta, about: .zero))
    }

    func scale(by factor: CGFloat) {
        guard let corners else { return }
        apply(InkSelection.transform(scale: factor, about: InkSelection.center(of: corners)))
    }

    func rotate(by angle: CGFloat) {
        guard let corners else { return }
        apply(InkSelection.transform(rotation: angle, about: InkSelection.center(of: corners)))
    }

    private func apply(_ step: CGAffineTransform) {
        guard let canvas, let base, activeGestures > 0,
              let indices = currentIndices(in: base) else { return }
        accumulated = accumulated.concatenating(step)
        corners = baseCorners.map { $0.applying(accumulated) }
        canvas.drawing = InkSelection.transforming(base, indices: indices, by: accumulated)
    }

    func endGesture() {
        activeGestures = max(activeGestures - 1, 0)
        guard activeGestures == 0 else { return }
        defer { base = nil; accumulated = .identity }
        guard let canvas, let base else { return }
        guard !accumulated.isIdentity else {
            presentMenu()   // a tap inside the box: bring the menu back
            return
        }
        // One undo step for the whole gesture: back to the drawing it
        // started from, not to the frame before the last finger lifted.
        let final = canvas.drawing
        canvas.drawing = base
        canvas.setDrawingUndoably(final)
        if let indices = currentIndices(in: final) { inkBoundsAfterChange = InkSelection.bounds(of: final, indices: indices) }
        onDrawingChanged()
        presentMenu()
    }

    // MARK: Commands

    func delete() {
        guard let canvas, let indices = currentIndices(in: canvas.drawing) else { return }
        canvas.setDrawingUndoably(InkSelection.removing(canvas.drawing, indices: indices))
        clear()
        onDrawingChanged()
    }

    /// A copy a little down and to the right, selected, so it can be
    /// dragged where it's wanted.
    func duplicate() {
        guard let canvas, let indices = currentIndices(in: canvas.drawing) else { return }
        let copies = InkSelection.reidentified(InkSelection.strokes(of: canvas.drawing, indices: indices))
        insert(copies, offsetBy: Self.copyOffset)
    }

    /// `copySelection`, not `copy()`: NSObject already has one of those.
    func copySelection() {
        guard let canvas, let indices = currentIndices(in: canvas.drawing) else { return }
        let strokes = InkSelection.strokes(of: canvas.drawing, indices: indices)
        UIPasteboard.general.setData(InkSelection.pasteboardData(for: strokes), forPasteboardType: InkSelection.pasteboardType)
        clipboardVersion += 1
        pasteCount = 0
    }

    /// The selection in another colour; still selected, one undo step.
    func recolor(_ color: UIColor) {
        guard let canvas else { return }
        let drawing = canvas.drawing
        guard let indices = currentIndices(in: drawing) else { return }
        // One pass over the selected strokes only, one undo step, one
        // autosave. The fingerprints don't include ink, so the selection
        // survives the change as it is.
        guard let recoloured = InkSelection.recoloringIfChanged(drawing, indices: indices, to: color) else { return }
        canvas.setDrawingUndoably(recoloured)
        onDrawingChanged()
    }

    /// The selection as a picture on the clipboard, for other apps.
    func copySelectionAsImage() {
        guard let canvas, let indices = currentIndices(in: canvas.drawing),
              let image = InkSelection.image(of: InkSelection.strokes(of: canvas.drawing, indices: indices)) else { return }
        UIPasteboard.general.image = image
    }

    /// The selected strokes and their bounds, for Convert to Text.
    var selectedStrokes: (strokes: [PKStroke], bounds: CGRect)? {
        guard let canvas, let indices = currentIndices(in: canvas.drawing) else { return nil }
        return (InkSelection.strokes(of: canvas.drawing, indices: indices), InkSelection.bounds(of: canvas.drawing, indices: indices))
    }

    /// Removes exactly these strokes - matched by id, not by what happens
    /// to be selected now - or nothing, if any of them has gone or changed
    /// since. Convert to Text reads the ink for a second or two; the user
    /// may have moved on. Returns where the strokes were when removed,
    /// which is not where they were when read if the selection moved.
    @discardableResult
    func delete(exactly strokes: [PKStroke]) -> CGRect? {
        guard let canvas, !strokes.isEmpty else { return nil }
        let wanted = strokes.map(StrokeIDMap.Fingerprint.init)
        let present = canvas.drawing.strokes.map(StrokeIDMap.Fingerprint.init)
        let indices = wanted.compactMap { present.firstIndex(of: $0) }
        guard indices.count == wanted.count else { return nil }
        let bounds = InkSelection.bounds(of: canvas.drawing, indices: indices)
        canvas.setDrawingUndoably(InkSelection.removing(canvas.drawing, indices: indices))
        clear()
        onDrawingChanged()
        return bounds
    }

    func cutSelection() {
        copySelection()
        delete()
    }

    static var pasteboardHasInk: Bool {
        UIPasteboard.general.contains(pasteboardTypes: [InkSelection.pasteboardType])
    }

    /// Pastes where the ink was copied from, nudged the same way a
    /// duplicate is - and selected, since the next thing you do with a
    /// paste is put it somewhere.
    func paste() {
        guard canvas != nil,
              let data = UIPasteboard.general.data(forPasteboardType: InkSelection.pasteboardType),
              let strokes = InkSelection.strokes(fromPasteboardData: data), !strokes.isEmpty else { return }
        // Each paste of the same copy steps further, so they never stack
        // exactly; one that would land off screen goes to its middle.
        pasteCount += 1
        let step = CGPoint(x: Self.copyOffset.x * CGFloat(pasteCount), y: Self.copyOffset.y * CGFloat(pasteCount))
        insert(InkSelection.reidentified(strokes), offsetBy: Self.onScreen(strokes, offsetBy: step, visible: visiblePageRect))
    }

    /// Pastes since the last copy.
    private var pasteCount = 0

    /// The part of the page on screen, in page coordinates.
    private var visiblePageRect: CGRect? {
        guard let canvas, canvas.bounds.width > 0 else { return nil }
        let zoom = max(canvas.zoomScale, 0.0001)
        return CGRect(x: canvas.contentOffset.x / zoom, y: canvas.contentOffset.y / zoom,
                      width: canvas.bounds.width / zoom, height: canvas.bounds.height / zoom)
    }

    /// `offset`, unless the strokes moved by it would be off screen: then
    /// the offset that centres them in `visible`.
    static func onScreen(_ strokes: [PKStroke], offsetBy offset: CGPoint, visible: CGRect?) -> CGPoint {
        let bounds = strokes.reduce(CGRect.null) { $0.union($1.renderBounds) }
        guard let visible, !bounds.isNull,
              !visible.intersects(bounds.offsetBy(dx: offset.x, dy: offset.y)) else { return offset }
        return CGPoint(x: visible.midX - bounds.midX, y: visible.midY - bounds.midY)
    }

    private static let copyOffset = CGPoint(x: 24, y: 24)

    private func insert(_ strokes: [PKStroke], offsetBy offset: CGPoint) {
        guard let canvas else { return }
        let nudge = CGAffineTransform(translationX: offset.x, y: offset.y)
        let nudged = strokes.map { stroke -> PKStroke in
            var copy = stroke
            copy.transform = stroke.transform.concatenating(nudge)
            return copy
        }
        let (drawing, indices) = InkSelection.appending(nudged, to: canvas.drawing)
        canvas.setDrawingUndoably(drawing)
        select(indices: indices, in: drawing)
        onDrawingChanged()
    }

    // MARK: Coordinates

    /// The canvas's bounds coordinates include its scroll offset and are
    /// in zoomed units, so dividing by the zoom scale lands in the
    /// drawing's own space - the same conversion `CanvasViewport.pagePoint`
    /// makes for the SwiftUI overlays.
    func pagePoint(of touch: UITouch) -> CGPoint {
        guard let canvas else { return touch.location(in: host) }
        return pagePoint(canvasPoint: touch.location(in: canvas))
    }

    func pagePoint(of recognizer: UIGestureRecognizer) -> CGPoint {
        guard let canvas else { return recognizer.location(in: host) }
        return pagePoint(canvasPoint: recognizer.location(in: canvas))
    }

    private func pagePoint(canvasPoint: CGPoint) -> CGPoint {
        let scale = max(canvas?.zoomScale ?? 1, 0.0001)
        return CGPoint(x: canvasPoint.x / scale, y: canvasPoint.y / scale)
    }

    /// Screen-point deltas divided by the zoom, so the ink follows the
    /// finger whatever the magnification.
    func pageDelta(screenDelta: CGPoint) -> CGPoint {
        let scale = max(canvas?.zoomScale ?? 1, 0.0001)
        return CGPoint(x: screenDelta.x / scale, y: screenDelta.y / scale)
    }

    /// Whether this touch is the one that would have inked: the Pencil
    /// under `.pencilOnly`, anything on a Mac, where the pointer is the pen.
    func isDrawingTouch(_ touch: UITouch) -> Bool {
        if touch.type == .pencil { return true }
        if CanvasInput.isMac { return touch.type == .direct || touch.type == .indirectPointer }
        return canvas?.drawingPolicy != .pencilOnly && touch.type == .direct
    }

    // MARK: Lasso in progress

    func lassoBegan(at point: CGPoint) {
        display.lasso = [point]
    }

    func lassoMoved(to point: CGPoint) {
        display.lasso.append(point)
    }

    // MARK: Finger gestures

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            beginGesture()
        case .changed:
            let delta = recognizer.translation(in: host)
            recognizer.setTranslation(.zero, in: host)
            translate(by: pageDelta(screenDelta: delta))
        case .ended, .cancelled, .failed:
            endGesture()
        default:
            break
        }
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            beginGesture()
        case .changed:
            let factor = recognizer.scale
            recognizer.scale = 1
            scale(by: factor)
        case .ended, .cancelled, .failed:
            endGesture()
        default:
            break
        }
    }

    @objc private func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
        switch recognizer.state {
        case .began:
            beginGesture()
        case .changed:
            let angle = recognizer.rotation
            recognizer.rotation = 0
            rotate(by: angle)
        case .ended, .cancelled, .failed:
            endGesture()
        default:
            break
        }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        clear()
    }
}

extension InkSelectionController: UIGestureRecognizerDelegate {
    /// The finger gestures only mean anything with a selection on screen:
    /// a drag starts inside the box, a tap outside lets go. With nothing
    /// selected none of them begin, and fingers pan and zoom the page as
    /// usual.
    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard hasSelection else { return false }
        switch recognizer {
        case fingerPan: return contains(pagePoint: pagePoint(of: recognizer))
        case tapOutside: return !contains(pagePoint: pagePoint(of: recognizer))
        default: return true
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

/// The Pencil's part of the lasso. A pure touch observer, like
/// `ShapeHoldRecognizer` and `MultiFingerTapRecognizer`: it never leaves
/// `.possible` except to fail, so it can't be starved by, or starve,
/// anything else on the host. With the canvas's drawing gesture stood
/// down there is nothing else that wants the Pencil anyway.
///
/// Pencil down inside the selection's box drags it; anywhere else starts a
/// new loop (and lets go of the old selection).
final class InkLassoRecognizer: UIGestureRecognizer {
    weak var controller: InkSelectionController?

    private var activeTouch: UITouch?
    private var isMoving = false
    private var lastPoint: CGPoint = .zero

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        requiresExclusiveTouchType = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        // An end/cancel that never arrived (host torn down mid-touch) must
        // not leave every later touch ignored.
        if let stale = activeTouch,
           ShapeHoldRecognizer.isStale(phase: stale.phase, hasWindow: stale.window != nil && view?.window != nil) {
            abandonStaleTouch()
        }
        guard activeTouch == nil, let controller else {
            for touch in touches { ignore(touch, for: event) }
            return
        }
        guard let touch = touches.first, controller.isDrawingTouch(touch) else {
            for touch in touches { ignore(touch, for: event) }
            return
        }
        activeTouch = touch
        let point = controller.pagePoint(of: touch)
        lastPoint = point
        if controller.contains(pagePoint: point) {
            isMoving = true
            controller.beginGesture()
        } else {
            isMoving = false
            controller.clear()
            controller.lassoBegan(at: point)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = activeTouch, touches.contains(touch), let controller else { return }
        if isMoving {
            let point = controller.pagePoint(of: touch)
            controller.translate(by: CGPoint(x: point.x - lastPoint.x, y: point.y - lastPoint.y))
            lastPoint = point
        } else {
            for sample in event.coalescedTouches(for: touch) ?? [touch] {
                controller.lassoMoved(to: controller.pagePoint(of: sample))
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches, cancelled: true)
    }

    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        activeTouch = nil
        let moving = isMoving
        isMoving = false
        // Always reach a terminal state, whatever happens to the controller.
        state = .failed
        guard let controller else { return }
        if moving {
            controller.endGesture()
        } else if cancelled {
            controller.clear()
        } else {
            controller.select(lasso: controller.display.lasso)
        }
    }

    override func reset() {
        super.reset()
        let wasTracking = activeTouch != nil
        let moving = isMoving
        activeTouch = nil
        isMoving = false
        // Reset with a touch tracked: disabled or removed mid-gesture. Close
        // out what the controller was told had begun.
        if wasTracking, let controller {
            if moving { controller.endGesture() } else { controller.clear() }
        }
    }

    /// True while a touch is being tracked.
    var hasTrackedTouch: Bool { activeTouch != nil }

    /// Drops everything tracked, without telling the controller.
    func clearTrackedState() {
        activeTouch = nil
        isMoving = false
    }

    private func abandonStaleTouch() {
        let moving = isMoving
        activeTouch = nil
        isMoving = false
        guard let controller else { return }
        if moving { controller.endGesture() } else { controller.clear() }
    }
}
#endif
