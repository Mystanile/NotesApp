import Foundation
import CoreGraphics
#if targetEnvironment(macCatalyst) || canImport(UIKit)
import UIKit
import UIKit.UIGestureRecognizerSubclass
import PencilKit

/// Shared canvas-interaction helpers used by both `PencilCanvasView` (paged
/// pages) and `WhiteboardCanvasView`:
///
///  - `ScribbleErase` - "scribble to delete": a quick back-and-forth
///    scribble drawn over existing ink removes that ink instead of leaving
///    the scribble behind, the way GoodNotes/Notability do it.
///  - `CanvasHostView` - a plain container the `PKCanvasView` is pinned
///    inside. Custom gesture recognizers and the Pencil interaction live on
///    the container, not on the canvas: recognizers added directly to a
///    `PKCanvasView` lose every touch to PencilKit's own drawing recognizer
///    and the scroll view's pan/pinch, which is why the finger and Pencil
///    shortcuts did nothing before.
///  - `MultiFingerTapRecognizer` / `CanvasShortcutInstaller` - attaches the
///    Procreate-style shortcuts (two-finger tap = undo, three-finger tap =
///    redo, either one held = keep repeating, Apple Pencil (Pro) double-tap
///    = toggle eraser) to a host view, idempotently.

// MARK: - Scribble to erase

enum ScribbleErase {

    /// Whether `stroke` looks like a "scratch this out" scribble rather than
    /// intentional writing: a single stroke that retraces itself many times
    /// inside a small area, with several hard direction reversals. Tuned to
    /// be conservative - normal cursive (even a hurried signature) stays well
    /// under these thresholds.
    static func isScribble(_ stroke: PKStroke) -> Bool {
        // Highlighter/marker passes are legitimately back-and-forth; only
        // treat true pen/pencil strokes as erase gestures.
        switch stroke.ink.inkType {
        case .marker: return false
        default: break
        }

        let points = sampledPoints(of: stroke, spacing: 4)
        guard points.count > 10 else { return false }

        var pathLength: CGFloat = 0
        var reversals = 0
        var previousDirection: CGVector?
        for i in 1..<points.count {
            let delta = CGVector(dx: points[i].x - points[i - 1].x,
                                 dy: points[i].y - points[i - 1].y)
            let segment = hypot(delta.dx, delta.dy)
            pathLength += segment
            guard segment > 0.5 else { continue }
            let direction = CGVector(dx: delta.dx / segment, dy: delta.dy / segment)
            if let previous = previousDirection {
                let dot = previous.dx * direction.dx + previous.dy * direction.dy
                if dot < -0.3 { reversals += 1 }   // turned back on itself (~110°+)
            }
            previousDirection = direction
        }

        let bounds = stroke.renderBounds
        let diagonal = hypot(bounds.width, bounds.height)
        guard diagonal > 1 else { return false }

        let density = pathLength / diagonal          // how much retracing
        let longestSide = max(bounds.width, bounds.height)

        return reversals >= 4 && density >= 4 && longestSide < 600
    }

    /// The drawing with `scribble` (assumed to be the most recently added
    /// stroke) removed, along with every stroke it substantially covers.
    /// Returns `nil` if nothing under the scribble qualified for erasing, so
    /// the caller can leave the drawing untouched rather than silently
    /// swallowing a stroke the heuristic misfired on.
    static func applying(_ scribble: PKStroke, to drawing: PKDrawing) -> PKDrawing? {
        let scribblePoints = sampledPoints(of: scribble, spacing: 6)
        guard !scribblePoints.isEmpty else { return nil }

        let hitRadius: CGFloat = 16
        let searchBounds = scribble.renderBounds.insetBy(dx: -hitRadius, dy: -hitRadius)

        var erasedAnything = false
        var survivors: [PKStroke] = []
        survivors.reserveCapacity(drawing.strokes.count)

        for (index, candidate) in drawing.strokes.enumerated() {
            // The scribble itself is the last stroke - always drop it.
            if index == drawing.strokes.count - 1 {
                continue
            }
            guard candidate.renderBounds.intersects(searchBounds) else {
                survivors.append(candidate)
                continue
            }
            let candidatePoints = sampledPoints(of: candidate, spacing: 6)
            guard !candidatePoints.isEmpty else {
                survivors.append(candidate)
                continue
            }
            var covered = 0
            for point in candidatePoints where isPoint(point, within: hitRadius, of: scribblePoints) {
                covered += 1
            }
            // Erase only if the scribble runs over most of the stroke, not
            // if it just clips one end.
            if Double(covered) / Double(candidatePoints.count) >= 0.4 {
                erasedAnything = true
            } else {
                survivors.append(candidate)
            }
        }

        guard erasedAnything else { return nil }
        return PKDrawing(strokes: survivors)
    }

    private static func isPoint(_ point: CGPoint, within radius: CGFloat, of path: [CGPoint]) -> Bool {
        let squared = radius * radius
        for other in path {
            let dx = other.x - point.x
            let dy = other.y - point.y
            if dx * dx + dy * dy <= squared { return true }
        }
        return false
    }

    private static func sampledPoints(of stroke: PKStroke, spacing: CGFloat) -> [CGPoint] {
        let interpolated = stroke.path.interpolatedPoints(by: .distance(spacing))
        var points = interpolated.map { $0.location }
        if points.isEmpty {
            points = stroke.path.map { $0.location }
        }
        guard stroke.transform.isIdentity == false else { return points }
        return points.map { $0.applying(stroke.transform) }
    }
}

// MARK: - Undoable drawing changes

extension PKCanvasView {
    /// Replaces the drawing *through* the undo manager.
    ///
    /// PencilKit registers undo for strokes it draws itself, but assigning
    /// `drawing` directly is invisible to the undo stack - which is why the
    /// fill tool, the shape tool and scribble-to-erase all used to be
    /// permanent, with the undo button staying greyed out afterwards. The
    /// registered undo restores the previous drawing through this same
    /// method, so undoing re-registers the inverse and redo works too.
    func setDrawingUndoably(_ newDrawing: PKDrawing) {
        let previous = drawing
        drawing = newDrawing
        undoManager?.registerUndo(withTarget: self) { target in
            target.setDrawingUndoably(previous)
        }
    }
}

// MARK: - Per-page canvas

/// The `PKCanvasView` a single page draws into.
///
/// Every page (and every whiteboard) gets a brand-new one of these when it's
/// opened - see `NotebookDetailView.installFreshCanvas`. Pages used to share
/// one canvas with `.drawing` swapped in place, and everything else the
/// canvas carries came along for the ride: the whiteboard's 3000pt scroll
/// position and zoom, PencilKit's rendered tiles, and above all the undo
/// stack, which is how a whiteboard's ink kept turning up on the next page
/// that was added after it. A fresh view per page has nothing to leak.
///
/// It also owns its undo manager. `UIResponder.undoManager` normally walks
/// the responder chain up to the *window's* shared manager, so two canvases
/// in the same window would still have pooled their histories; answering
/// with our own keeps each page's undo/redo entirely its own.
final class PageCanvasView: PKCanvasView {
    private let pageUndoManager = UndoManager()

    override var undoManager: UndoManager? { pageUndoManager }
}

// MARK: - Canvas host container

/// A transparent container the page's `PKCanvasView` is pinned inside. It
/// exists purely so gesture recognizers have somewhere to live that isn't
/// the canvas itself.
class CanvasHostView: UIView {
    private(set) weak var canvas: PKCanvasView?

    /// Reparents `canvas` into this container (a view has one superview, so
    /// `addSubview` also removes it from a previous host) and pins it to the
    /// edges. A previously embedded canvas - the outgoing page's - is
    /// removed, so a host never shows two pages' ink stacked on top of each
    /// other.
    func embed(_ canvas: PKCanvasView) {
        guard canvas.superview !== self else { return }
        if let previous = self.canvas, previous !== canvas, previous.superview === self {
            previous.removeFromSuperview()
        }
        canvas.translatesAutoresizingMaskIntoConstraints = false
        addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: trailingAnchor),
            canvas.topAnchor.constraint(equalTo: topAnchor),
            canvas.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        self.canvas = canvas
    }
}

// MARK: - Finger / Pencil shortcut recognizers

/// Procreate's undo/redo gesture: a **single** tap with N fingers, and
/// tap-and-hold with N fingers to keep repeating it.
///
/// This deliberately never leaves `.possible` except to fail, so it acts as
/// a pure touch observer: it can't win the gesture-arbitration fight against
/// PencilKit's drawing recognizer or the canvas scroll view's pan/pinch, and
/// it can't cancel their touches either. That's the difference from the
/// `UITapGestureRecognizer(numberOfTouchesRequired:2, numberOfTapsRequired:2)`
/// this replaces - those were being starved by PencilKit and, even when they
/// weren't, a two-finger *double* tap is a much harder gesture to land than
/// the single tap Procreate actually uses.
final class MultiFingerTapRecognizer: UIGestureRecognizer {

    /// Exactly this many fingers, so a three-finger redo never also fires
    /// the two-finger undo.
    let requiredTouches: Int
    var onTrigger: () -> Void = {}

    /// A tap has to be quick and near-still; anything slower or further is
    /// a pan/pinch and is left alone.
    private let movementTolerance: CGFloat = 24
    private let tapDuration: TimeInterval = 0.5
    /// Hold past this and it starts repeating, like holding down undo.
    private let holdDelay: TimeInterval = 0.45
    private let repeatInterval: TimeInterval = 0.14

    private var activeTouches: Set<UITouch> = []
    private var startLocations: [ObjectIdentifier: CGPoint] = [:]
    private var peakTouchCount = 0
    private var startTimestamp: TimeInterval?
    private var strayed = false
    private var didRepeat = false
    private var repeatTimer: Timer?

    init(requiredTouches: Int, target: Any?, action: Selector?) {
        self.requiredTouches = requiredTouches
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        requiresExclusiveTouchType = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            // The Pencil draws; it never drives these shortcuts.
            guard touch.type != .pencil else {
                ignore(touch, for: event)
                continue
            }
            activeTouches.insert(touch)
            startLocations[ObjectIdentifier(touch)] = touch.location(in: view)
        }
        guard !activeTouches.isEmpty else { return }
        if startTimestamp == nil { startTimestamp = event.timestamp }
        peakTouchCount = max(peakTouchCount, activeTouches.count)
        // An extra finger landing late (three-finger taps never land as one
        // instant) has to stand the two-finger hold back down.
        if peakTouchCount != requiredTouches { stopRepeating() }
        restartHoldTimerIfNeeded()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches where activeTouches.contains(touch) {
            guard let start = startLocations[ObjectIdentifier(touch)] else { continue }
            let current = touch.location(in: view)
            if hypot(current.x - start.x, current.y - start.y) > movementTolerance {
                strayed = true
                stopRepeating()
                return
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches, timestamp: event.timestamp, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches, timestamp: event.timestamp, cancelled: true)
    }

    private func finish(_ touches: Set<UITouch>, timestamp: TimeInterval, cancelled: Bool) {
        for touch in touches { activeTouches.remove(touch) }
        guard activeTouches.isEmpty else { return }

        let duration = timestamp - (startTimestamp ?? timestamp)
        let isTap = !cancelled
            && !strayed
            && !didRepeat                      // a hold already delivered its work
            && peakTouchCount == requiredTouches
            && duration <= tapDuration
        stopRepeating()
        // .failed rather than .recognized: failing resets the recognizer
        // without cancelling anyone else's touches.
        state = .failed
        if isTap { onTrigger() }
    }

    deinit {
        // A repeating Timer is retained by the run loop, so one left running
        // past this recognizer's life would tick forever doing nothing.
        stopRepeating()
    }

    override func reset() {
        super.reset()
        stopRepeating()
        activeTouches.removeAll()
        startLocations.removeAll()
        peakTouchCount = 0
        startTimestamp = nil
        strayed = false
        didRepeat = false
    }

    private func restartHoldTimerIfNeeded() {
        stopRepeating()
        guard activeTouches.count == requiredTouches, peakTouchCount == requiredTouches, !strayed else { return }
        repeatTimer = Timer.scheduledTimer(withTimeInterval: holdDelay, repeats: false) { [weak self] _ in
            self?.beginRepeating()
        }
    }

    private func beginRepeating() {
        guard activeTouches.count == requiredTouches, !strayed else { return }
        didRepeat = true
        onTrigger()
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: repeatInterval, repeats: true) { [weak self] _ in
            guard let self, self.activeTouches.count == self.requiredTouches, !self.strayed else {
                self?.stopRepeating()
                return
            }
            self.onTrigger()
        }
    }

    private func stopRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
}

/// Owns the shortcut gesture recognizers and the Pencil interaction for one
/// canvas coordinator and tears them down cleanly, so switching between a
/// paged page and a whiteboard doesn't leave stale recognizers stacked on a
/// reused host.
///
/// The gestures, matching Procreate:
///  - two-finger tap = undo, held = keep undoing
///  - three-finger tap = redo, held = keep redoing
///  - Apple Pencil (Pro) double-tap = toggle the eraser
final class CanvasShortcutInstaller: NSObject, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {

    /// Undo / redo are routed through the canvas's own `undoManager` - the
    /// same one the toolbar buttons use - so the parent view's button state
    /// refreshes through the normal drawing-changed callback.
    var onUndo: () -> Void = {}
    var onRedo: () -> Void = {}
    /// Apple Pencil (Pro) double-tap. The parent flips `DrawingToolState`
    /// between the eraser and the previously selected tool.
    var onPencilDoubleTap: () -> Void = {}

    private weak var hostView: UIView?
    private var twoFingerUndo: MultiFingerTapRecognizer?
    private var threeFingerRedo: MultiFingerTapRecognizer?
    private var pencilInteraction: UIPencilInteraction?

    func install(on host: UIView) {
        if hostView === host, twoFingerUndo != nil { return }
        removeAll()

        // Without this the window hands the host a single touch at a time
        // and a two-finger tap can never be seen as two fingers.
        host.isMultipleTouchEnabled = true

        let undoTap = MultiFingerTapRecognizer(requiredTouches: 2, target: nil, action: nil)
        undoTap.onTrigger = { [weak self] in self?.onUndo() }
        undoTap.delegate = self
        host.addGestureRecognizer(undoTap)
        twoFingerUndo = undoTap

        let redoTap = MultiFingerTapRecognizer(requiredTouches: 3, target: nil, action: nil)
        redoTap.onTrigger = { [weak self] in self?.onRedo() }
        redoTap.delegate = self
        host.addGestureRecognizer(redoTap)
        threeFingerRedo = redoTap

        let pencil = UIPencilInteraction()
        pencil.delegate = self
        host.addInteraction(pencil)
        pencilInteraction = pencil

        hostView = host
    }

    func removeAll() {
        if let host = hostView {
            if let undoTap = twoFingerUndo { host.removeGestureRecognizer(undoTap) }
            if let redoTap = threeFingerRedo { host.removeGestureRecognizer(redoTap) }
            if let pencil = pencilInteraction { host.removeInteraction(pencil) }
        }
        twoFingerUndo = nil
        threeFingerRedo = nil
        pencilInteraction = nil
        hostView = nil
    }

    // MARK: UIGestureRecognizerDelegate

    // Sit alongside PencilKit's own drawing / the scroll view's pan+pinch
    // rather than fighting them for the touch.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        touch.type != .pencil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        false
    }

    // MARK: UIPencilInteractionDelegate

    func pencilInteraction(_ interaction: UIPencilInteraction,
                           didReceiveTap tap: UIPencilInteraction.Tap) {
        onPencilDoubleTap()
    }

    // Older callback - harmless to keep for anything that still delivers it.
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        onPencilDoubleTap()
    }
}
#endif
