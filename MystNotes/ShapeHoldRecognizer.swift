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
/// shape before they hold. This one restarts a timer every time the pencil
/// moves; if the timer fires with the pencil still down, that's a hold.
///
/// It sits on the canvas host view next to the undo/redo tap recognizers,
/// is a pure observer (never cancels or delays anyone's touches, recognizes
/// simultaneously with everything), and records the pencil's path as it
/// goes so recognition can happen the moment the hold registers - before
/// PencilKit has committed the stroke, which it only does on touch-up.
///
/// Callbacks are in the canvas's *drawing* coordinates (page points), so
/// they line up with `PKDrawing` whatever the zoom.
final class ShapeHoldRecognizer: UIGestureRecognizer {

    /// The pencil has been still for `holdDuration` with a stroke drawn.
    var onHold: ([CGPoint]) -> Void = { _ in }
    /// The pencil moved again after a hold: whatever was pending is off.
    var onHoldBroken: () -> Void = {}
    /// The stroke ended (lifted or cancelled). `held` says whether a hold
    /// was in effect at the time.
    var onEnd: (_ held: Bool) -> Void = { _ in }

    /// How long the pencil has to stay still. Long enough that a natural
    /// pause mid-stroke doesn't fire it; short enough not to feel like a
    /// wait.
    var holdDuration: TimeInterval = 0.8
    /// Movement below this (in screen points) is the hand's tremor, not a
    /// move; it doesn't restart the timer.
    var stillnessTolerance: CGFloat = 4
    /// The canvas whose drawing coordinates the points are reported in.
    weak var canvas: PKCanvasView?

    private var activeTouch: UITouch?
    private var points: [CGPoint] = []
    private var restLocation: CGPoint?
    private var timer: Timer?
    private var didHold = false

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        requiresExclusiveTouchType = false
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
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
        restLocation = touch.location(in: view)
        didHold = false
        restartTimer()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        // Coalesced touches carry every sample the Pencil produced, not
        // just the last one per frame - a corner drawn fast is in there.
        for sample in event.coalescedTouches(for: touch) ?? [touch] {
            points.append(drawingLocation(of: sample))
        }
        let location = touch.location(in: view)
        if let rest = restLocation, hypot(location.x - rest.x, location.y - rest.y) <= stillnessTolerance {
            return
        }
        restLocation = location
        if didHold {
            didHold = false
            onHoldBroken()
        }
        restartTimer()
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
        activeTouch = nil
        points = []
        restLocation = nil
        didHold = false
        // .failed rather than .recognized: failing resets the recognizer
        // without cancelling anyone else's touches.
        state = .failed
        onEnd(held)
    }

    override func reset() {
        super.reset()
        stopTimer()
        activeTouch = nil
        points = []
        restLocation = nil
        didHold = false
    }

    deinit {
        stopTimer()
    }

    // MARK: Hold

    private func restartTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: holdDuration, repeats: false) { [weak self] _ in
            self?.timerFired()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func timerFired() {
        guard activeTouch != nil, !didHold else { return }
        // A still pencil that hasn't drawn anything yet is a dot, not a
        // shape being held.
        guard ShapeRecognizer.pathLength(points) >= ShapeRecognizer.minimumPathLength else { return }
        didHold = true
        onHold(points)
    }

    // MARK: Geometry

    /// Only the touch type PencilKit will draw with. Under `.pencilOnly` a
    /// finger pans, and a pan held still must not snap anything.
    private func isDrawingTouch(_ touch: UITouch) -> Bool {
        guard let canvas else { return touch.type == .pencil }
        switch canvas.drawingPolicy {
        case .pencilOnly: return touch.type == .pencil
        default: return touch.type == .pencil || touch.type == .direct
        }
    }

    /// The canvas's bounds coordinates include its scroll offset and are in
    /// zoomed units, so dividing by the zoom scale lands in the drawing's
    /// own space - the same conversion `CanvasViewport.pagePoint` makes for
    /// the SwiftUI overlays.
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
    private let haptic = UIImpactFeedbackGenerator(style: .medium)
    private var expiry: Task<Void, Never>?

    func attach(to recognizer: ShapeHoldRecognizer) {
        recognizer.onHold = { [weak self] points in self?.hold(points) }
        recognizer.onHoldBroken = { [weak self] in self?.clear() }
        recognizer.onEnd = { [weak self] held in self?.strokeEnded(held: held) }
    }

    private func hold(_ points: [CGPoint]) {
        guard let shape = ShapeRecognizer.recognize(points) else { return }
        pending = shape
        // The haptic is what tells the hand the hold registered, before it
        // lifts.
        haptic.impactOccurred()
        onPreview(shape)
    }

    private func strokeEnded(held: Bool) {
        guard held, pending != nil else {
            clear()
            return
        }
        // The commit is expected on this same run-loop turn or the next.
        // If it never comes (the stroke was cancelled), don't let a stale
        // shape replace some later stroke.
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.clear()
        }
    }

    /// Called from `canvasViewDrawingDidChange`. If a snap is pending, the
    /// stroke just committed (the last one) is replaced with the recognized
    /// shape, undoably, in the ink of the tool that drew it. Returns whether
    /// it did.
    func applyIfPending(to canvasView: PKCanvasView) -> Bool {
        guard let shape = pending else { return false }
        clear()
        guard let tool = canvasView.tool as? PKInkingTool,
              !canvasView.drawing.strokes.isEmpty else { return false }
        var strokes = canvasView.drawing.strokes
        strokes[strokes.count - 1] = ShapeRecognizer.stroke(for: shape, tool: tool)
        canvasView.setDrawingUndoably(PKDrawing(strokes: strokes))
        return true
    }

    func clear() {
        expiry?.cancel()
        expiry = nil
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

    var body: some View {
        Canvas { context, _ in
            guard shape.outline.count > 1 else { return }
            var path = Path()
            path.move(to: shape.outline[0])
            for point in shape.outline.dropFirst() { path.addLine(to: point) }
            let color = tool.map { Color(uiColor: $0.color) } ?? .accentColor
            let width = tool?.width ?? 3
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
    }
}
#endif
