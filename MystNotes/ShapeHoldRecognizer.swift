import Foundation
import CoreGraphics
#if targetEnvironment(macCatalyst) || canImport(UIKit)
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import PencilKit

/// Hold-to-snap: draw a shape, keep the pencil down and still at the end,
/// and the stroke snaps to the clean version. How GoodNotes and Apple
/// Notes do it, and it removes a mode from the toolbar.
///
/// `UILongPressGestureRecognizer` can't do this - its `allowableMovement`
/// is measured from the *first* touch point, and the user has drawn a whole
/// shape before they hold. This one tracks where the pencil went still and
/// how long ago that was.
///
/// It sits on the canvas host view next to the undo/redo tap recognizers,
/// is a pure observer (never cancels or delays anyone's touches, recognizes
/// simultaneously with everything), and records the pencil's path as it
/// goes so recognition can happen the moment the hold registers - before
/// PencilKit has committed the stroke, which it only does on touch-up.
///
/// **Two independent things can notice the hold**, which is what makes it
/// fire reliably:
///
///  - a timer, now scheduled in the *common* run-loop modes. It used to be
///    a plain `Timer.scheduledTimer`, which only runs in `.default` - so
///    while the run loop was in tracking mode (which is exactly when a
///    pencil is down) it simply never fired, and the hold was missed;
///  - the touch stream itself. A resting Apple Pencil still delivers
///    `touchesMoved` continuously from its own jitter, so the elapsed-time
///    check there catches a hold even if the timer is starved.
///
/// Callbacks are in the canvas's *drawing* coordinates (page points), so
/// they line up with `PKDrawing` whatever the zoom.
final class ShapeHoldRecognizer: UIGestureRecognizer {

    /// The pencil has been still for `holdDuration` with a stroke drawn.
    /// Returning false means "nothing recognizable yet" - the hold isn't
    /// taken, and the recognizer keeps offering as the stroke grows, so a
    /// shape that needed one more corner still snaps instead of needing
    /// the whole gesture to be started again.
    var onHold: ([CGPoint]) -> Bool = { _ in false }
    /// The pencil moved again after a hold: whatever was pending is off.
    var onHoldBroken: () -> Void = {}
    /// A new stroke has started. Anything left over from the last one is
    /// stale.
    var onBegin: () -> Void = {}
    /// The stroke ended (lifted or cancelled). `held` says whether a hold
    /// was in effect at the time.
    var onEnd: (_ held: Bool) -> Void = { _ in }

    /// How long the pencil has to stay still. Long enough that a natural
    /// pause mid-stroke doesn't fire it; short enough not to feel like a
    /// wait. GoodNotes sits around here too.
    var holdDuration: TimeInterval = 0.5
    /// Movement below this (in screen points) is the hand's tremor, not a
    /// move. A pencil held still by a human hand drifts several points -
    /// at the old 4pt this restarted the clock over and over and the hold
    /// often never registered at all.
    var stillnessTolerance: CGFloat = 9
    /// The canvas whose drawing coordinates the points are reported in.
    weak var canvas: PKCanvasView?

    private var activeTouch: UITouch?
    private var points: [CGPoint] = []
    /// Where the current period of stillness started, and when.
    private var anchor: CGPoint?
    private var anchorTime: CFTimeInterval = 0
    private var timer: Timer?
    private var didHold = false

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        // Without this a pencil touch and the finger touches around it are
        // treated as different gestures and ours is never offered the pen.
        requiresExclusiveTouchType = false
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        // A touch whose end or cancel never reached us (the canvas was torn
        // down mid-stroke on a page change) would otherwise make every new
        // touch look like a "second" one, forever.
        if let stale = activeTouch,
           Self.isStale(phase: stale.phase, hasWindow: stale.window != nil && view?.window != nil) {
            abandonStaleTouch()
        }
        guard activeTouch == nil else {
            // A second touch (the other hand steadying the iPad, a pinch)
            // is not a shape; the first one carries on alone.
            for touch in touches { ignore(touch, for: event) }
            return
        }
        guard let touch = touches.first, isDrawingTouch(touch) else {
            for touch in touches { ignore(touch, for: event) }
            return
        }
        activeTouch = touch
        points = [drawingLocation(of: touch)]
        didHold = false
        restAt(touch.location(in: view))
        onBegin()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        // Coalesced touches carry every sample the Pencil produced, not
        // just the last one per frame - a corner drawn fast is in there.
        for sample in event.coalescedTouches(for: touch) ?? [touch] {
            points.append(drawingLocation(of: sample))
        }
        let location = touch.location(in: view)
        guard let anchor else { return restAt(location) }

        if hypot(location.x - anchor.x, location.y - anchor.y) > stillnessTolerance {
            if didHold {
                didHold = false
                onHoldBroken()
            }
            restAt(location)
            return
        }
        // Still within the tolerance of where it went quiet: this is the
        // hold, if it has lasted long enough.
        checkForHold()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches)
    }

    private func finish(_ touches: Set<UITouch>) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        stopTimer()
        let held = didHold
        clearTouchState()
        // .failed rather than .recognized: failing resets the recognizer
        // without cancelling anyone else's touches.
        state = .failed
        onEnd(held)
    }

    override func reset() {
        super.reset()
        let wasTracking = activeTouch != nil
        stopTimer()
        clearTouchState()
        // Reset with a touch still tracked means we were disabled or removed
        // mid-stroke: let the owner drop any pending snap / preview.
        if wasTracking { onEnd(false) }
    }

    // MARK: Touch recovery

    /// True while a touch is being tracked.
    var hasTrackedTouch: Bool { activeTouch != nil }

    /// Drops everything tracked, without callbacks.
    func clearTrackedState() {
        stopTimer()
        clearTouchState()
    }

    /// A tracked touch is stale when UIKit has finished with it, or when it
    /// (or this recognizer) is no longer in a window.
    static func isStale(phase: UITouch.Phase, hasWindow: Bool) -> Bool {
        phase == .ended || phase == .cancelled || !hasWindow
    }

    private func abandonStaleTouch() {
        let held = didHold
        stopTimer()
        clearTouchState()
        onEnd(held)
    }

    private func clearTouchState() {
        activeTouch = nil
        points = []
        anchor = nil
        didHold = false
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: Hold

    /// The pencil is (newly) at rest here; the hold clock starts again.
    private func restAt(_ location: CGPoint) {
        anchor = location
        anchorTime = CACurrentMediaTime()
        restartTimer()
    }

    private func restartTimer() {
        stopTimer()
        // Target/selector rather than the closure form: the closure is
        // `@Sendable` and this recognizer is main-actor, so the closure
        // version can't touch it without an isolation dance. A one-shot
        // timer holds its target only until it fires.
        let timer = Timer(timeInterval: holdDuration, target: self,
                          selector: #selector(holdTimerFired), userInfo: nil, repeats: false)
        // `.common` and not the default mode: a pencil down on the canvas
        // puts the run loop in tracking mode, where a default-mode timer
        // does not fire at all. This one line is most of why the hold was
        // unreliable.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func holdTimerFired() {
        checkForHold()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// Fires the hold if the pencil is down, has been still long enough,
    /// and has actually drawn something.
    private func checkForHold() {
        guard activeTouch != nil, !didHold else { return }
        guard CACurrentMediaTime() - anchorTime >= holdDuration else { return }
        // A still pencil that hasn't drawn anything yet is a dot, not a
        // shape being held.
        guard ShapeRecognizer.pathLength(points) >= ShapeRecognizer.minimumPathLength / max(zoomScale, 0.1) else { return }
        if onHold(points) {
            didHold = true
            stopTimer()
        } else {
            // Nothing recognizable yet. Offer again after another interval
            // rather than giving up for the rest of the stroke.
            anchorTime = CACurrentMediaTime()
            restartTimer()
        }
    }

    // MARK: Geometry

    /// Only the touch type PencilKit will draw with. Under `.pencilOnly` a
    /// finger pans, and a pan held still must not snap anything.
    private func isDrawingTouch(_ touch: UITouch) -> Bool {
        guard let canvas else { return touch.type == .pencil }
        // An eraser or lasso stroke held still is not a shape. Without
        // this the hold fired anyway and the next committed stroke - some
        // unrelated ink - was swapped for the shape.
        guard canvas.tool is PKInkingTool else { return false }
        switch canvas.drawingPolicy {
        case .pencilOnly: return touch.type == .pencil
        default: return touch.type == .pencil || touch.type == .direct
        }
    }

    /// The canvas's bounds coordinates include its scroll offset and are in
    /// zoomed units, so dividing by the zoom scale lands in the drawing's
    /// own space - the same conversion `CanvasViewport.pagePoint` makes for
    /// the SwiftUI overlays.
    var zoomScale: CGFloat { canvas?.zoomScale ?? 1 }

    private func drawingLocation(of touch: UITouch) -> CGPoint {
        guard let canvas else { return touch.location(in: view) }
        let location = touch.location(in: canvas)
        let scale = max(canvas.zoomScale, 0.0001)
        return CGPoint(x: location.x / scale, y: location.y / scale)
    }
}

/// The bookkeeping between a hold and PencilKit committing the stroke,
/// shared by the paged and whiteboard coordinators. PencilKit only writes a
/// stroke into `canvasView.drawing` on touch-up, so a hold can't swap the
/// stroke in place; it recognizes, previews, and remembers, and the swap
/// happens in `canvasViewDrawingDidChange`.
@MainActor
final class ShapeSnapController {
    /// The recognized shape waiting for the stroke to be committed.
    private(set) var pending: ShapeRecognizer.RecognizedShape?
    /// Shows or hides the preview of what the stroke will snap to.
    var onPreview: (ShapeRecognizer.RecognizedShape?) -> Void = { _ in }
    /// Solid / dashed / dotted, pushed in from the toolbar's pen options.
    var lineStyle: ShapeLineStyle = .solid

    /// How long after the pencil lifts a pending shape is still applied.
    /// The commit normally lands on the same run-loop turn; this only has
    /// to outlast a busy one. A new stroke clears it regardless, which is
    /// the real protection against a stale shape landing on later ink.
    private static let commitWindow: TimeInterval = 1.5

    private let haptic = UIImpactFeedbackGenerator(style: .medium)
    private var liftedAt: CFTimeInterval?
    private weak var recognizer: ShapeHoldRecognizer?
    /// How many strokes the drawing had when the hold fired. The held
    /// stroke is the next one; any other change (an undo, a paste, a
    /// scribble-erase) must not be swapped for the shape.
    private var strokeCountAtHold: Int?

    func attach(to recognizer: ShapeHoldRecognizer) {
        self.recognizer = recognizer
        recognizer.onHold = { [weak self] points in self?.hold(points) ?? false }
        recognizer.onHoldBroken = { [weak self] in self?.clear() }
        recognizer.onBegin = { [weak self] in self?.clear() }
        recognizer.onEnd = { [weak self] held in self?.strokeEnded(held: held) }
    }

    /// Returns whether the hold was taken - false means nothing was
    /// recognized, and the recognizer will offer again as the stroke grows.
    private func hold(_ points: [CGPoint]) -> Bool {
        guard let shape = ShapeRecognizer.recognize(points, zoom: recognizer?.zoomScale ?? 1) else { return false }
        pending = shape
        strokeCountAtHold = recognizer?.canvas?.drawing.strokes.count
        liftedAt = nil
        // The haptic is what tells the hand the hold registered, before it
        // lifts.
        haptic.impactOccurred()
        onPreview(shape)
        return true
    }

    private func strokeEnded(held: Bool) {
        guard held, pending != nil else {
            clear()
            return
        }
        liftedAt = CACurrentMediaTime()
        onPreview(nil)
    }

    /// Called from `canvasViewDrawingDidChange`. If a snap is pending, the
    /// stroke just committed (the last one) is replaced with the recognized
    /// shape, undoably, in the ink of the stroke it replaces. Returns
    /// whether it did.
    func applyIfPending(to canvasView: PKCanvasView) -> Bool {
        // `liftedAt` being nil is fine: PencilKit commits the stroke on
        // touch-up, and whether that lands before or after our own
        // `touchesEnded` is not ordered. Requiring the lift first would
        // drop the snap whenever the commit won the race.
        guard let shape = pending,
              liftedAt.map({ CACurrentMediaTime() - $0 < Self.commitWindow }) ?? true,
              !canvasView.drawing.strokes.isEmpty else { return false }
        if let before = strokeCountAtHold, canvasView.drawing.strokes.count != before + 1 {
            // Not the held stroke landing. Keep waiting for it while the
            // pencil is down; after the lift it is not coming.
            if liftedAt != nil { clear() }
            return false
        }
        clear()

        var strokes = canvasView.drawing.strokes
        let source = strokes.removeLast()
        // One undo takes the shape away and does not bring the freehand
        // stroke back (user decision, Oct 22, 2026). PencilKit's own undo
        // for the stroke restores this same drawing, whether it lands in
        // the same undo group or the next one.
        let beforeStroke = PKDrawing(strokes: strokes)
        // Weight, pressure and ink all come from the stroke being replaced,
        // so the shape is the same mark the hand just made. `tool` is only
        // the fallback for a source stroke with no points.
        let spec = ShapeRecognizer.spec(
            matching: source,
            tool: canvasView.tool as? PKInkingTool,
            style: lineStyle
        )
        strokes.append(contentsOf: ShapeRecognizer.strokes(for: shape, spec: spec))
        canvasView.setDrawingUndoably(PKDrawing(strokes: strokes), undoTo: beforeStroke)
        return true
    }

    func clear() {
        liftedAt = nil
        strokeCountAtHold = nil
        if pending != nil {
            pending = nil
            onPreview(nil)
        }
    }
}

/// The shape a held stroke is about to snap to, drawn over the page in the
/// tool's own colour and width while the pencil is still down. Page
/// coordinates; the parent puts it through `PageViewportLayer`.
struct ShapePreviewView: View {
    var shape: ShapeRecognizer.RecognizedShape
    var tool: PKInkingTool?
    var lineStyle: ShapeLineStyle = .solid

    var body: some View {
        Canvas { context, _ in
            guard shape.outline.count > 1 else { return }
            var path = Path()
            path.move(to: shape.outline[0])
            for point in shape.outline.dropFirst() { path.addLine(to: point) }
            let color = tool.map { Color(uiColor: $0.color) } ?? .accentColor
            let width = tool?.width ?? 3
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dashPattern(width: width))
            )
        }
    }

    /// Mirrors `ShapeRecognizer`'s dash lengths so the preview is what you
    /// get.
    private func dashPattern(width: CGFloat) -> [CGFloat] {
        switch lineStyle {
        case .solid: return []
        case .dashed: return [max(width * 4, 6), max(width * 3, 4.5)]
        case .dotted: return [max(width * 0.35, 0.5), max(width * 2, 3)]
        }
    }
}
#endif
