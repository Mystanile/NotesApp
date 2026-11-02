import Foundation
import CoreGraphics
#if targetEnvironment(macCatalyst) || canImport(UIKit)
import UIKit
import UIKit.UIGestureRecognizerSubclass
import PencilKit
import UniformTypeIdentifiers

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
///  - `CanvasZoomCommand` / `CanvasHostView.zoom(...)` - the Mac (and
///    hardware-keyboard) ways to zoom: View-menu items with ⌘+ / ⌘- / ⌘0,
///    and ⌘- or ⌥-scroll-wheel about the pointer. A pinch is the only zoom
///    an iPad needs, but on a Mac the pointer has no second finger.

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
    /// `undoTo` is what an undo restores, when that is not the drawing
    /// being replaced: a shape snap undoes to before the freehand stroke.
    func setDrawingUndoably(_ newDrawing: PKDrawing, undoTo: PKDrawing? = nil) {
        let previous = undoTo ?? drawing
        drawing = newDrawing
        undoManager?.registerUndo(withTarget: self) { target in
            target.setDrawingUndoably(previous)
        }
    }
}

extension PKCanvasViewDrawingPolicy {
    /// Who may ink. On an iPad, only the Pencil: a finger pans, pinches and
    /// taps the undo shortcuts, and never leaves a mark. A Mac has no Pencil
    /// and no finger - the mouse and trackpad arrive as touches, so
    /// `.pencilOnly` meant nothing could draw at all there (reported Sept
    /// 12, 2026: "can't actually use the pen on Mac"). The page pans with
    /// the scroll wheel and trackpad instead.
    ///
    /// "Draw with finger" (`AppSettings.fingerDrawing`, off by default) turns
    /// an iPad's policy into `.anyInput`: the finger inks and two fingers
    /// pan and zoom, which PKCanvasView does itself.
    static var mystNotes: PKCanvasViewDrawingPolicy {
        #if targetEnvironment(macCatalyst)
        return policy(fingerDrawing: AppSettings.fingerDrawing, isMac: true)
        #else
        return policy(fingerDrawing: AppSettings.fingerDrawing, isMac: false)
        #endif
    }

    /// Pure, so a test can drive both settings. A Mac always gets `.anyInput`.
    static func policy(fingerDrawing: Bool, isMac: Bool) -> PKCanvasViewDrawingPolicy {
        (isMac || fingerDrawing) ? .anyInput : .pencilOnly
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

// MARK: - Zoom commands

/// Whether the app is running on a Mac - Catalyst or "Designed for iPad" -
/// where the input is a pointer rather than fingers and a Pencil.
enum CanvasInput {
    static let isMac: Bool = {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return ProcessInfo.processInfo.isiOSAppOnMac
        #endif
    }()
}

/// A zoom request from the View menu / keyboard (`NotebookApp`'s commands).
/// It's broadcast rather than routed, because the canvas that should answer
/// is a UIKit view a SwiftUI menu can't see; the host in the key window
/// picks it up.
enum CanvasZoomCommand {
    case zoomIn
    case zoomOut
    /// Back to the whole page on screen (a paged page) or 100% (a
    /// whiteboard).
    case reset

    static let notification = Notification.Name("MystNotes.canvasZoomCommand")

    func post() {
        NotificationCenter.default.post(name: Self.notification, object: self)
    }

    /// ⌘+ / ⌘- step by this much.
    static let stepFactor: CGFloat = 1.25
}

// MARK: - Canvas host container

/// A transparent container the page's `PKCanvasView` is pinned inside. It
/// exists purely so gesture recognizers have somewhere to live that isn't
/// the canvas itself.
///
/// It also answers the pointer-driven navigation a Mac needs, where a plain
/// drag is the pen and there's no second finger to pinch or pan with:
///
///  - the menu/keyboard `CanvasZoomCommand`s (⌘+ ⌘- ⌘0),
///  - the scroll wheel / two-finger trackpad scroll, which pans, or zooms
///    about the pointer with ⌘ or ⌥ held,
///  - Space held + drag, which pans with the pointer (Figma / Photoshop).
///
/// All of it moves the canvas's own scroll view exactly like a pinch does,
/// so PencilKit still re-renders the ink crisp at the new scale and the
/// paged host's centring / viewport publishing happen through the usual
/// scroll delegate callbacks.
class CanvasHostView: UIView {
    private(set) weak var canvas: PKCanvasView?

    private var zoomCommandObserver: NSObjectProtocol?
    private var resignActiveObserver: NSObjectProtocol?
    private var wheel: UIPanGestureRecognizer?
    private lazy var wheelDelegate = WheelDelegate()
    /// Present only while Space is held; see `updateDragPanOverlay`.
    private var dragPanOverlay: UIView?
    private var isSpaceHeld = false {
        didSet { if isSpaceHeld != oldValue { updateDragPanOverlay() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        zoomCommandObserver = NotificationCenter.default.addObserver(
            forName: CanvasZoomCommand.notification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let command = note.object as? CanvasZoomCommand else { return }
            self.handle(command)
        }
        // ⌘-Tab away while holding Space and the key-up never arrives; don't
        // leave the pan overlay sitting over the canvas eating the pen.
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.isSpaceHeld = false
        }
        installWheel()
    }

    deinit {
        if let zoomCommandObserver { NotificationCenter.default.removeObserver(zoomCommandObserver) }
        if let resignActiveObserver { NotificationCenter.default.removeObserver(resignActiveObserver) }
    }

    /// Reparents `canvas` into this container (a view has one superview, so
    /// `addSubview` also removes it from a previous host) and pins it to the
    /// edges. A previously embedded canvas - the outgoing page's - is
    /// removed, so a host never shows two pages' ink stacked on top of each
    /// other.
    func embed(_ canvas: PKCanvasView) {
        guard canvas.superview !== self else { return }
        if let previous = self.canvas, previous !== canvas, previous.superview === self {
            cancelInFlightGestures(outgoing: previous)
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
        // The wheel is ours (pan or zoom - see handleWheel), so the scroll
        // view's own pan has to stand aside for it. It declines touches
        // outright, so finger / Pencil panning on iPad is never held up.
        if let wheel { canvas.panGestureRecognizer.require(toFail: wheel) }
        // The overlay must stay on top of a newly embedded canvas.
        if let dragPanOverlay { bringSubviewToFront(dragPanOverlay) }
    }

    /// Before the outgoing canvas leaves, stand down anything mid-touch. A
    /// recognizer whose touch ended while its view was being torn down never
    /// hears about it and keeps ignoring (or holding) every later touch.
    /// Toggling `isEnabled` cancels a gesture in flight and resets it.
    private func cancelInFlightGestures(outgoing: PKCanvasView) {
        var stuck: [String] = []
        let drawing = outgoing.drawingGestureRecognizer
        if drawing.state != .possible {
            stuck.append("drawing(\(drawing.state.rawValue))")
        }
        let drawingWasEnabled = drawing.isEnabled
        if drawingWasEnabled {
            drawing.isEnabled = false
            drawing.isEnabled = drawingWasEnabled
        }
        for recognizer in gestureRecognizers ?? [] {
            let tracked: Bool
            switch recognizer {
            case let r as ShapeHoldRecognizer: tracked = r.hasTrackedTouch
            case let r as InkLassoRecognizer: tracked = r.hasTrackedTouch
            case let r as MultiFingerTapRecognizer: tracked = r.hasTrackedTouch
            default: continue
            }
            guard tracked || recognizer.state != .possible else { continue }
            stuck.append("\(type(of: recognizer))(\(recognizer.state.rawValue))")
            // Disabling resets it; re-enable only if it was enabled.
            let wasEnabled = recognizer.isEnabled
            recognizer.isEnabled = false
            recognizer.isEnabled = wasEnabled
        }
        if !stuck.isEmpty {
            AppLog.note("touch", "page change found gestures mid-touch: \(stuck.joined(separator: ", "))")
        }
    }

    // MARK: Paste and drop

    /// An image (or PDF) arrived by ⌘V or by being dragged onto the page.
    /// Raw file bytes; the parent sniffs the type and imports it.
    ///
    /// On a Mac the Photos picker is the *only* way images could get in,
    /// which meant anything in Finder or Files was unreachable. Both of
    /// these routes are handled here, on the host view, because both are
    /// UIKit responder-chain business: `PKCanvasView` is the first
    /// responder and implements neither, so the action walks up to us.
    var onPasteImage: ((Data) -> Void)? {
        didSet { updateDropInteraction() }
    }
    private var dropInteraction: UIDropInteraction?
    /// The lasso's selection, so ⌘C / ⌘X / ⌘V and the Edit menu work on
    /// selected ink the way they do on a selected picture.
    weak var inkSelection: InkSelectionController? {
        didSet { if inkSelection != nil { installSelectionMenu() } }
    }

    // MARK: Selection menu

    private var editMenuInteraction: UIEditMenuInteraction?
    /// Where the menu points: the selection's box in this view, clipped to
    /// what is visible.
    fileprivate(set) var selectionMenuTargetRect: CGRect = .zero

    /// One interaction and one secondary-click recogniser, added the first
    /// time a selection controller arrives. Idempotent.
    private func installSelectionMenu() {
        guard editMenuInteraction == nil else { return }
        let interaction = UIEditMenuInteraction(delegate: self)
        addInteraction(interaction)
        editMenuInteraction = interaction
        // Mac Catalyst: a right-click opens the same menu, on the selection
        // or - with nothing selected - offering Paste where it was clicked.
        let click = UITapGestureRecognizer(target: self, action: #selector(handleSecondaryClick(_:)))
        click.buttonMaskRequired = .secondary
        click.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        click.cancelsTouchesInView = false
        addGestureRecognizer(click)
    }

    /// Opens the menu on the next run-loop turn - a touch callback is no
    /// place to present UI from. `point` is where a click landed; without
    /// one the menu points at the top of the selection.
    func presentSelectionMenu(at point: CGPoint? = nil) {
        DispatchQueue.main.async { [weak self] in self?.presentSelectionMenuNow(at: point) }
    }

    private func presentSelectionMenuNow(at point: CGPoint?) {
        guard let inkSelection, inkSelection.isActive, window != nil,
              let interaction = editMenuInteraction else { return }
        let source: CGPoint
        if inkSelection.hasSelection, let rect = inkSelection.selectionRect(in: self) {
            var visible = rect.intersection(bounds)
            if visible.isNull { visible = CGRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1) }
            selectionMenuTargetRect = visible
            source = point ?? CGPoint(x: visible.midX, y: visible.minY)
        } else if let point {
            selectionMenuTargetRect = CGRect(x: point.x, y: point.y, width: 1, height: 1)
            source = point
        } else {
            return
        }
        interaction.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: source))
    }

    func dismissSelectionMenu() {
        editMenuInteraction?.dismissMenu()
    }

    @objc private func handleSecondaryClick(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let inkSelection, inkSelection.isActive else { return }
        let point = recognizer.location(in: self)
        if inkSelection.hasSelection, let rect = inkSelection.selectionRect(in: self), !rect.contains(point) {
            return  // a click outside the box belongs to whatever is there
        }
        presentSelectionMenu(at: point)
    }

    /// Duplicate and Delete from the keyboard while ink is selected; ⌘C,
    /// ⌘X and ⌘V already arrive as `copy`, `cut` and `paste`.
    override var keyCommands: [UIKeyCommand]? {
        let duplicate = UIKeyCommand(input: "d", modifierFlags: .command, action: #selector(inkDuplicate(_:)))
        duplicate.discoverabilityTitle = "Duplicate Selection"
        let delete = UIKeyCommand(input: UIKeyCommand.inputDelete, modifierFlags: [], action: #selector(inkDelete(_:)))
        delete.discoverabilityTitle = "Delete Selection"
        return (super.keyCommands ?? []) + [duplicate, delete]
    }

    @objc func inkDuplicate(_ sender: Any?) { inkSelection?.duplicate() }
    @objc func inkDelete(_ sender: Any?) { inkSelection?.delete() }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            // Ink first: a copy of ink is on the pasteboard under our own
            // type and never looks like a picture. `hasImage` and not a
            // read: reading the pasteboard is what raises the system's
            // "pasted from" banner, and this is called every time the
            // Edit menu is built.
            if inkSelection?.isActive == true, InkSelectionController.pasteboardHasInk { return true }
            return onPasteImage != nil && CanvasPasteboard.hasImage
        }
        if action == #selector(copy(_:)) || action == #selector(cut(_:))
            || action == #selector(inkDuplicate(_:)) || action == #selector(inkDelete(_:)) {
            return inkSelection?.hasSelection == true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        if let inkSelection, inkSelection.isActive, InkSelectionController.pasteboardHasInk {
            inkSelection.paste()
            return
        }
        guard let data = CanvasPasteboard.payload() else { return }
        onPasteImage?(data)
    }

    override func copy(_ sender: Any?) {
        inkSelection?.copySelection()
    }

    override func cut(_ sender: Any?) {
        inkSelection?.cutSelection()
    }

    private func updateDropInteraction() {
        if onPasteImage != nil, dropInteraction == nil {
            let interaction = UIDropInteraction(delegate: self)
            addInteraction(interaction)
            dropInteraction = interaction
        } else if onPasteImage == nil, let interaction = dropInteraction {
            removeInteraction(interaction)
            dropInteraction = nil
        }
    }



    // MARK: Zoom

    /// The scale `CanvasZoomCommand.reset` returns to. 100% for a
    /// whiteboard; the paged host overrides this with its fit scale.
    var defaultZoomScale: CGFloat { 1 }

    /// Only the canvas the user is looking at answers a menu command - with
    /// a notebook open in a second window, both hosts hear the broadcast.
    private func handle(_ command: CanvasZoomCommand) {
        guard let window, window.isKeyWindow, !isHidden else { return }
        switch command {
        case .zoomIn:  zoom(by: CanvasZoomCommand.stepFactor, about: nil)
        case .zoomOut: zoom(by: 1 / CanvasZoomCommand.stepFactor, about: nil)
        case .reset:   setZoomScale(defaultZoomScale, about: nil)
        }
    }

    /// Multiplies the current zoom, keeping the page point under
    /// `anchor` (in this view's coordinates; nil = the middle of the view)
    /// where it is - what a scroll-wheel zoom about the pointer needs.
    func zoom(by factor: CGFloat, about anchor: CGPoint?) {
        guard let canvas else { return }
        setZoomScale(canvas.zoomScale * factor, about: anchor)
    }

    func setZoomScale(_ requested: CGFloat, about anchor: CGPoint?) {
        // isScrollEnabled is how the parent stands the pinch down while an
        // image is being placed; the keyboard shouldn't get around that.
        guard let canvas, canvas.isScrollEnabled else { return }
        let target = min(max(requested, canvas.minimumZoomScale), canvas.maximumZoomScale)
        let current = canvas.zoomScale
        guard abs(target - current) > 0.0001 else { return }

        let anchor = anchor ?? CGPoint(x: bounds.midX, y: bounds.midY)
        // The unzoomed content point under the anchor, which must stay put.
        let contentPoint = CGPoint(
            x: (anchor.x + canvas.contentOffset.x) / current,
            y: (anchor.y + canvas.contentOffset.y) / current
        )

        // Setting the scale fires scrollViewDidZoom, which is where the
        // paged host re-centres the page (via contentInset) - so the insets
        // are right by the time the offset is clamped below.
        canvas.setZoomScale(target, animated: false)

        let wanted = CGPoint(x: contentPoint.x * target - anchor.x,
                             y: contentPoint.y * target - anchor.y)
        canvas.setContentOffset(clampedOffset(wanted), animated: false)
    }

    /// Moves the content by `delta` screen points (positive = content moves
    /// right/down, the direction a finger drag carries it).
    func pan(by delta: CGPoint) {
        guard let canvas, canvas.isScrollEnabled, delta != .zero else { return }
        let wanted = CGPoint(x: canvas.contentOffset.x - delta.x,
                             y: canvas.contentOffset.y - delta.y)
        let clamped = clampedOffset(wanted)
        guard clamped != canvas.contentOffset else { return }
        canvas.setContentOffset(clamped, animated: false)
    }

    /// `offset` kept inside the scrollable range, honouring the insets the
    /// paged host centres the page with (so a page smaller than the view
    /// stays put in the middle rather than sliding into a corner).
    private func clampedOffset(_ offset: CGPoint) -> CGPoint {
        guard let canvas else { return offset }
        let inset = canvas.contentInset
        let minOffset = CGPoint(x: -inset.left, y: -inset.top)
        let maxOffset = CGPoint(
            x: max(minOffset.x, canvas.contentSize.width - canvas.bounds.width + inset.right),
            y: max(minOffset.y, canvas.contentSize.height - canvas.bounds.height + inset.bottom)
        )
        return CGPoint(x: min(max(offset.x, minOffset.x), maxOffset.x),
                       y: min(max(offset.y, minOffset.y), maxOffset.y))
    }

    // MARK: Scroll wheel: pan, or ⌘ / ⌥ zoom

    /// A pan recognizer that only ever sees scroll-wheel / trackpad-scroll
    /// events (the delegate turns every touch away). An unmodified scroll
    /// pans; with ⌘ or ⌥ held it zooms about the pointer.
    ///
    /// Panning is done here rather than left to the scroll view because
    /// `UIScrollView`'s scroll-event handling is tangled up with its
    /// touch-count rules and PencilKit's own recognizers, and on the Mac it
    /// simply wasn't moving the page. Harmless on an iPad without a
    /// trackpad: it never fires.
    private func installWheel() {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handleWheel(_:)))
        recognizer.allowedScrollTypesMask = [.continuous, .discrete]
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = wheelDelegate
        addGestureRecognizer(recognizer)
        wheel = recognizer
    }

    @objc private func handleWheel(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            let delta = recognizer.translation(in: self)
            recognizer.setTranslation(.zero, in: self)
            let modifiers = recognizer.modifierFlags
            if modifiers.contains(.command) || modifiers.contains(.alternate) {
                guard delta.y != 0 else { return }
                // Wheel up (content would move down) zooms in, like Maps / Figma.
                zoom(by: exp(delta.y * 0.006), about: recognizer.location(in: self))
            } else {
                pan(by: delta)
            }
        default:
            break
        }
    }

    // MARK: Space + drag

    /// Space held and the pointer drags the page around. PencilKit would
    /// otherwise turn the drag into a stroke, so while Space is down a
    /// transparent overlay sits over the canvas and takes the drag itself -
    /// the canvas never sees it.
    ///
    /// The key presses arrive because the canvas is first responder and
    /// forwards what it doesn't handle up to us, its superview.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if CanvasInput.isMac, presses.contains(where: { $0.key?.keyCode == .keyboardSpacebar }) {
            isSpaceHeld = true
            return
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.key?.keyCode == .keyboardSpacebar }) {
            isSpaceHeld = false
            return
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.key?.keyCode == .keyboardSpacebar }) {
            isSpaceHeld = false
            return
        }
        super.pressesCancelled(presses, with: event)
    }

    private func updateDragPanOverlay() {
        if isSpaceHeld {
            guard dragPanOverlay == nil else { return }
            let overlay = UIView(frame: bounds)
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.backgroundColor = .clear
            let drag = UIPanGestureRecognizer(target: self, action: #selector(handleDragPan(_:)))
            drag.maximumNumberOfTouches = 1
            overlay.addGestureRecognizer(drag)
            addSubview(overlay)
            dragPanOverlay = overlay
        } else {
            dragPanOverlay?.removeFromSuperview()
            dragPanOverlay = nil
        }
    }

    @objc private func handleDragPan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            let delta = recognizer.translation(in: self)
            recognizer.setTranslation(.zero, in: self)
            pan(by: delta)
        default:
            break
        }
    }

    /// Lives outside the host so the host's own `UIGestureRecognizerDelegate`
    /// conformance (subclasses have their own) doesn't get tangled up.
    private final class WheelDelegate: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive event: UIEvent) -> Bool {
            event.type == .scroll
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            false
        }
    }
}

/// Dragging a picture out of Finder, Files or another app and onto the page
/// - the gesture a Mac user reaches for first.
extension CanvasHostView: UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let inkSelection else { return nil }
        return SelectionMenu.menu(for: inkSelection, host: self)
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        selectionMenuTargetRect
    }
}

extension CanvasHostView: UIDropInteractionDelegate {
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        session.canLoadObjects(ofClass: UIImage.self)
            || session.hasItemsConforming(toTypeIdentifiers: [UTType.image.identifier, UTType.pdf.identifier])
    }

    func dropInteraction(_ interaction: UIDropInteraction,
                         sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        guard let onPasteImage else { return }
        // The file's own bytes, so a PNG stays a PNG and a PDF is still a
        // PDF; loading it as a UIImage would throw both away.
        for identifier in [UTType.pdf.identifier, UTType.image.identifier] {
            guard let item = session.items.first(where: {
                $0.itemProvider.hasItemConformingToTypeIdentifier(identifier)
            }) else { continue }
            item.itemProvider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                guard let data else { return }
                DispatchQueue.main.async { onPasteImage(data) }
            }
            return
        }
        // Something that is only offered as an image object (a drag out of
        // another app's canvas, say).
        session.loadObjects(ofClass: UIImage.self) { images in
            guard let image = images.first as? UIImage, let data = image.pngData() else { return }
            onPasteImage(data)
        }
    }
}


// MARK: - Pasteboard

/// Reading an image off the system pasteboard, for ⌘V on the canvas and for
/// the Import menu's "Paste Image".
///
/// Two levels on purpose: `hasImage` is a cheap, silent check (used to
/// enable the menu item and the Edit menu's Paste), while `payload()`
/// actually reads - which is what raises iOS's "pasted from" banner, so it
/// only happens when someone really did paste.
enum CanvasPasteboard {
    /// Best first: the original bytes beat a re-encode of
    /// `UIPasteboard.image`.
    private static let types = ["com.adobe.pdf", "public.png", "public.jpeg",
                                "public.heic", "com.compuserve.gif", "public.tiff"]

    static var hasImage: Bool {
        let pasteboard = UIPasteboard.general
        return pasteboard.hasImages || pasteboard.hasURLs
            || types.contains { pasteboard.contains(pasteboardTypes: [$0]) }
    }

    static func payload() -> Data? {
        let pasteboard = UIPasteboard.general
        for type in types {
            if let data = pasteboard.data(forPasteboardType: type) { return data }
        }
        // A file copied in Finder arrives as a URL, not as pixels.
        if let url = pasteboard.urls?.first, let data = try? Data(contentsOf: url) { return data }
        return pasteboard.image?.pngData()
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
        dropStaleTouches()
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
        clearTrackedState()
    }

    /// True while any finger is being tracked.
    var hasTrackedTouch: Bool { !activeTouches.isEmpty }

    /// Drops everything tracked (and any repeat timer).
    func clearTrackedState() {
        stopRepeating()
        activeTouches.removeAll()
        startLocations.removeAll()
        peakTouchCount = 0
        startTimestamp = nil
        strayed = false
        didRepeat = false
    }

    /// Fingers whose end never reached us (host torn down mid-touch) would
    /// make the finger count wrong for every later tap.
    private func dropStaleTouches() {
        guard !activeTouches.isEmpty else { return }
        let hostHasWindow = view?.window != nil
        let stale = activeTouches.filter {
            ShapeHoldRecognizer.isStale(phase: $0.phase, hasWindow: hostHasWindow && $0.window != nil)
        }
        guard !stale.isEmpty else { return }
        for touch in stale {
            activeTouches.remove(touch)
            startLocations[ObjectIdentifier(touch)] = nil
        }
        // A dropped touch means the old gesture is over; whatever lands next
        // is a fresh one.
        peakTouchCount = 0
        startTimestamp = nil
        strayed = false
        stopRepeating()
        if activeTouches.isEmpty { clearTrackedState() }
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
///  - Apple Pencil Pro squeeze = open the active tool's colour options
final class CanvasShortcutInstaller: NSObject, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {

    /// Undo / redo are routed through the canvas's own `undoManager` - the
    /// same one the toolbar buttons use - so the parent view's button state
    /// refreshes through the normal drawing-changed callback.
    var onUndo: () -> Void = {}
    var onRedo: () -> Void = {}
    /// Apple Pencil (Pro) double-tap. The parent flips `DrawingToolState`
    /// between the eraser and the previously selected tool.
    var onPencilDoubleTap: () -> Void = {}
    /// Apple Pencil Pro squeeze. Fired once, when the squeeze ends.
    var onPencilSqueeze: () -> Void = {}

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
            if let undoTap = twoFingerUndo { undoTap.clearTrackedState(); host.removeGestureRecognizer(undoTap) }
            if let redoTap = threeFingerRedo { redoTap.clearTrackedState(); host.removeGestureRecognizer(redoTap) }
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

    func pencilInteraction(_ interaction: UIPencilInteraction,
                           didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        onPencilSqueeze()
    }
}
#endif
