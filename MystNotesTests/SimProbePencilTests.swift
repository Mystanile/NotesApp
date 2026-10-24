import XCTest
import SwiftUI
import PencilKit
import UIKit.UIGestureRecognizerSubclass
@testable import Mystnotes

/// Simulator probes for the Pencil items PLAN.md lists under "Owed on the
/// iPad before M1 exits", and for the shape-snap undo in the Handoff.
///
/// The simulator has no Apple Pencil, and public API cannot make a
/// `UITouch`. So none of these tests send a Pencil touch. What they do
/// instead: host the real canvas views in a real window, read the gesture
/// configuration a Pencil touch would meet (touch types, enabled state,
/// delegate answers), and call the same controller methods the recognizers
/// call, with the same coordinate conversion. Each test says what it
/// cannot show. A device check is still owed for the touch delivery itself.
///
/// No `@Query` in these screens, so no shared `ModelContainer` is needed.
@MainActor
final class SimProbePencilTests: XCTestCase {

    // MARK: - Hosting

    private struct PagedHost: View {
        static let pageID = UUID()
        @State var canvas: PKCanvasView = PageCanvasView()
        let viewport: CanvasViewport
        let selection: InkSelectionController
        let onCanvas: (PKCanvasView) -> Void
        var body: some View {
            PencilCanvasView(canvasView: $canvas,
                             pageSize: PageGeometry.contentSize(aspectRatio: PageGeometry.defaultAspectRatio),
                             pageIdentity: Self.pageID,
                             viewport: viewport,
                             inkSelection: selection)
                .onAppear { onCanvas(canvas) }
        }
    }

    /// The whiteboard as `WhiteboardLassoTests` hosts it, with the
    /// selection overlay drawn through the viewport, so a picture shows the
    /// box on the ink. `PageCanvasView`, as the app uses, for its own undo.
    private struct BoardHost: View {
        @State var canvas: PKCanvasView = PageCanvasView()
        let viewport: CanvasViewport
        let selection: InkSelectionController
        let onCanvas: (PKCanvasView) -> Void
        var body: some View {
            let size = CGSize(width: WhiteboardCanvasView.boardSize, height: WhiteboardCanvasView.boardSize)
            ZStack {
                WhiteboardCanvasView(canvasView: $canvas, viewport: viewport, inkSelection: selection)
                PageViewportLayer(viewport: viewport, pageSize: size) { scale in
                    InkSelectionOverlay(display: selection.display, scale: scale)
                }
                .allowsHitTesting(false)
            }
            .onAppear { onCanvas(canvas) }
        }
    }

    private func window(size: CGSize) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        return window
    }

    private func hostPage() async throws -> (UIWindow, PKCanvasView, InkSelectionController, PagedCanvasHostView) {
        let window = try window(size: CGSize(width: 1024, height: 768))
        let selection = InkSelectionController()
        var hosted: PKCanvasView?
        window.rootViewController = UIHostingController(rootView:
            PagedHost(viewport: CanvasViewport(), selection: selection) { hosted = $0 })
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(600))
        let canvas = try XCTUnwrap(hosted)
        let host = try XCTUnwrap(canvas.superview as? PagedCanvasHostView, "the canvas sits in its host")
        selection.canvas = canvas
        return (window, canvas, selection, host)
    }

    private func hostBoard() async throws -> (UIWindow, PKCanvasView, InkSelectionController, CanvasViewport, WhiteboardHostView) {
        let window = try window(size: CGSize(width: 800, height: 600))
        let viewport = CanvasViewport()
        let selection = InkSelectionController()
        var hosted: PKCanvasView?
        window.rootViewController = UIHostingController(rootView:
            BoardHost(viewport: viewport, selection: selection) { hosted = $0 })
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(600))
        let canvas = try XCTUnwrap(hosted)
        let host = try XCTUnwrap(canvas.superview as? WhiteboardHostView, "the canvas sits in its host")
        selection.canvas = canvas
        return (window, canvas, selection, viewport, host)
    }

    private func close(_ window: UIWindow) {
        window.rootViewController = nil
        window.isHidden = true
    }

    /// What `applyToolState` does when the lasso is picked.
    private func pickLasso(_ canvas: PKCanvasView, _ selection: InkSelectionController) {
        canvas.tool = PKLassoTool()
        selection.isActive = true
    }

    // MARK: - Helpers

    private func touchTypes(_ recognizer: UIGestureRecognizer) -> Set<UITouch.TouchType> {
        Set(recognizer.allowedTouchTypes.compactMap { UITouch.TouchType(rawValue: $0.intValue) })
    }

    private func describe(_ recognizer: UIGestureRecognizer) -> String {
        let types = touchTypes(recognizer).map { type -> String in
            switch type {
            case .direct: return "direct"
            case .pencil: return "pencil"
            case .indirect: return "indirect"
            case .indirectPointer: return "pointer"
            @unknown default: return "\(type.rawValue)"
            }
        }.sorted()
        var text = "\(type(of: recognizer)) enabled=\(recognizer.isEnabled) types=\(types)"
        if let pan = recognizer as? UIPanGestureRecognizer {
            text += " touches=\(pan.minimumNumberOfTouches)...\(pan.maximumNumberOfTouches)"
        }
        return text
    }

    private func prints(_ drawing: PKDrawing) -> [StrokeIDMap.Fingerprint] {
        drawing.strokes.map(StrokeIDMap.Fingerprint.init)
    }

    private func line(x: CGFloat, y: CGFloat, index: Int) -> PKStroke {
        let points = stride(from: x, through: x + 80, by: 5).map { px in
            PKStrokePoint(location: CGPoint(x: px, y: y), timeOffset: TimeInterval(px - x) * 0.01,
                          size: CGSize(width: 6, height: 6), opacity: 1, force: 1,
                          azimuth: 0, altitude: .pi / 2)
        }
        let path = PKStrokePath(controlPoints: points,
                                creationDate: Date(timeIntervalSinceReferenceDate: 710_000_000 + Double(index)))
        return PKStroke(ink: PKInk(.pen, color: .black), path: path, randomSeed: UInt32(1300 + index))
    }

    /// A hand-drawn circle: a deterministic wobble on an ellipse, at about
    /// Pencil sample spacing.
    private func circlePoints(center: CGPoint, radius: CGFloat) -> [CGPoint] {
        (0...180).map { i in
            let angle = -CGFloat.pi / 2 + 2 * .pi * CGFloat(i) / 180
            let wobble = 1.5 * sin(CGFloat(i) * 1.7)
            return CGPoint(x: center.x + (radius + wobble) * cos(angle),
                           y: center.y + (radius - wobble) * sin(angle))
        }
    }

    private func freehandStroke(_ points: [CGPoint]) -> PKStroke {
        let controls = points.enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: TimeInterval(i) * 0.008,
                          size: CGSize(width: 3, height: 3), opacity: 1, force: 0.5,
                          azimuth: 0, altitude: .pi / 2)
        }
        let path = PKStrokePath(controlPoints: controls, creationDate: Date(timeIntervalSinceReferenceDate: 720_000_000))
        return PKStroke(ink: PKInk(.pen, color: .black), path: path, randomSeed: 4242)
    }

    /// Stands in for a touch's location: answers `location(in:)` with a
    /// point given in the host's coordinates, converted the way UIKit
    /// converts a touch's location (through the scroll view's bounds
    /// origin, which is its content offset). `InkSelectionController`'s
    /// `pagePoint(of: UIGestureRecognizer)` and `pagePoint(of: UITouch)`
    /// both end in the same `pagePoint(canvasPoint:)`.
    private final class PointRecognizer: UIGestureRecognizer {
        weak var host: UIView?
        var hostPoint: CGPoint = .zero
        override func location(in view: UIView?) -> CGPoint {
            guard let host, let view else { return hostPoint }
            return host.convert(hostPoint, to: view)
        }
    }

    private func savePNG(of window: UIWindow, name: String) throws {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try savePNG(image: image, name: name)
    }

    private func savePNG(image: UIImage, name: String) throws {
        let data = try XCTUnwrap(image.pngData())
        let probes = URL(fileURLWithPath: "/tmp/mystnotes-probes")
        do {
            try FileManager.default.createDirectory(at: probes, withIntermediateDirectories: true)
            let url = probes.appendingPathComponent("\(name).png")
            try data.write(to: url)
            print("PROBE_PNG \(url.path)")
        } catch {
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(name).png")
            try data.write(to: url)
            print("PROBE_PNG \(url.path) (host path failed: \(error))")
        }
    }

    // MARK: - 1. The Pencil lasso on a normal page

    /// PLAN.md, owed on the iPad: "The Pencil lasso on a normal page: the
    /// host recognizer gets the Pencil, and the Pencil does not pan the
    /// canvas."
    ///
    /// Checks, on a hosted `PencilCanvasView` with the lasso picked the way
    /// `applyToolState` picks it: the canvas is `.pencilOnly`; PencilKit's
    /// drawing recognizer is off; `InkLassoRecognizer` is on the host,
    /// enabled, takes Pencil touches, never cancels or delays anyone's and
    /// shares with the scroll view's pan; a point on the page hit-tests into
    /// the canvas under the host, so touches reach the host's recognizers;
    /// the finger drag takes fingers only. Then the pan: at fit it needs
    /// two touches, so one Pencil cannot pan. Zoomed in it needs one, and
    /// the test fails if the scroll view's pan still lists `.pencil` in its
    /// allowed touch types while the lasso is in hand - the app sets nothing
    /// there itself, and with PencilKit's drawing recognizer disabled
    /// nothing visible stops a Pencil lasso loop from panning the page.
    ///
    /// Cannot show: a real Pencil touch arriving. A private PencilKit
    /// delegate (`gestureRecognizer(_:shouldReceive:)` on the scroll view)
    /// could still refuse the Pencil for the pan; that answer needs a
    /// `UITouch`, so if this fails, confirm it on the iPad: zoom in, pick the
    /// lasso, draw a loop, and see whether the page moves.
    func testPagedLasso_hostGetsThePencil_andThePencilCannotPanThePage() async throws {
        let (window, canvas, selection, host) = try await hostPage()
        defer { close(window) }
        canvas.drawing = PKDrawing(strokes: [line(x: 300, y: 400, index: 0)])
        pickLasso(canvas, selection)

        if !CanvasInput.isMac {
            XCTAssertEqual(canvas.drawingPolicy, .pencilOnly, "on an iPad only the Pencil inks")
        }
        XCTAssertFalse(canvas.drawingGestureRecognizer.isEnabled, "with the lasso, PencilKit's drawing recognizer stands down")

        let lassos = host.gestureRecognizers?.compactMap { $0 as? InkLassoRecognizer } ?? []
        XCTAssertEqual(lassos.count, 1, "exactly one lasso recognizer on the host")
        let lasso = try XCTUnwrap(lassos.first)
        XCTAssertTrue(lasso.isEnabled)
        XCTAssertTrue(touchTypes(lasso).contains(.pencil), "the lasso recognizer must accept Pencil touches")
        XCTAssertFalse(lasso.requiresExclusiveTouchType)
        XCTAssertFalse(lasso.cancelsTouchesInView)
        XCTAssertFalse(lasso.delaysTouchesBegan)
        XCTAssertTrue(lasso.delegate?.gestureRecognizer?(lasso, shouldRecognizeSimultaneouslyWith: canvas.panGestureRecognizer) ?? false,
                      "the lasso shares the touch with the scroll view's pan")

        // Recognizers on a superview of the hit-test view get its touches.
        let pageCentre = CGPoint(x: host.bounds.midX, y: host.bounds.midY)
        let hit = try XCTUnwrap(host.hitTest(pageCentre, with: nil), "something on the page takes the touch")
        XCTAssertTrue(hit.isDescendant(of: canvas), "the touch lands in the canvas, under the host: \(type(of: hit))")

        let fingerPan = host.gestureRecognizers?.first { $0 is UIPanGestureRecognizer && $0.delegate === selection }
        XCTAssertNotNil(fingerPan, "the selection's finger drag is on the host")
        XCTAssertEqual(fingerPan.map { touchTypes($0) }, Set([UITouch.TouchType.direct]),"the selection's drag is for fingers; the Pencil drags through the lasso recognizer")

        let pan = canvas.panGestureRecognizer
        print("PROBE paged fit: zoom=\(canvas.zoomScale) min=\(canvas.minimumZoomScale)")
        print("PROBE paged fit: pan \(describe(pan))")
        if let pinch = canvas.pinchGestureRecognizer { print("PROBE paged fit: pinch \(describe(pinch))") }
        for recognizer in canvas.gestureRecognizers ?? [] { print("PROBE paged canvas recognizer: \(describe(recognizer))") }
        for recognizer in host.gestureRecognizers ?? [] { print("PROBE paged host recognizer: \(describe(recognizer))") }
        XCTAssertEqual(pan.minimumNumberOfTouches, 2, "at fit one touch cannot pan the page, so one Pencil cannot")

        canvas.setZoomScale(canvas.minimumZoomScale * 2.5, animated: false)
        host.setNeedsLayout()
        host.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(pan.minimumNumberOfTouches, 1, "precondition: zoomed in, one touch pans")
        print("PROBE paged zoomed: zoom=\(canvas.zoomScale) pan \(describe(pan))")
        XCTAssertTrue(pan.isEnabled, "precondition: nothing is selected yet, so the pan is live while the loop is drawn")
        XCTAssertFalse(touchTypes(pan).contains(.pencil),
                       "Zoomed in with the lasso in hand, the page's pan takes one touch and allows Pencil touches \(describe(pan)). "
                       + "PencilKit's drawing recognizer is disabled, and the app sets nothing else, so a Pencil lasso loop can pan the page "
                       + "unless a private PencilKit delegate refuses it. Check on the iPad.")
    }

    // MARK: - 2. The Pencil lasso on a zoomed whiteboard

    /// PLAN.md, owed on the iPad: "The Pencil lasso on a zoomed whiteboard."
    /// `WhiteboardLassoTests` selects with a loop given in page points; this
    /// goes one step further back, to where a Pencil touch starts.
    ///
    /// Checks: on a whiteboard zoomed to 2.5x and scrolled far from the
    /// origin, a loop drawn in *screen* points around one stroke, converted
    /// through `pagePoint(of:)` (the conversion `InkLassoRecognizer` uses for
    /// every sample), then `lassoBegan`/`lassoMoved`/`select(lasso:)` as the
    /// recognizer calls them, selects exactly that stroke and not the two
    /// beside it; the box is on the stroke in page points; a Pencil drag
    /// from inside the box by 50x30 screen points moves the ink by 20x12
    /// page points and nothing else; one undo puts it back. Saves a picture
    /// of the box on the zoomed board (`wb-zoomed-lasso.png`).
    ///
    /// Cannot show: a real Pencil delivering touches to `InkLassoRecognizer`
    /// on the board, `isDrawingTouch` (needs a `UITouch`), or the coalesced
    /// samples a fast loop produces.
    func testZoomedWhiteboardLasso_screenLoopSelectsTheInkUnderIt() async throws {
        let (window, canvas, selection, viewport, host) = try await hostBoard()
        defer { close(window) }
        let target = line(x: 1200, y: 900, index: 0)
        let below = line(x: 1200, y: 1000, index: 1)
        let right = line(x: 1340, y: 900, index: 2)
        canvas.drawing = PKDrawing(strokes: [target, below, right])
        pickLasso(canvas, selection)
        XCTAssertFalse(canvas.drawingGestureRecognizer.isEnabled)
        let lassos = host.gestureRecognizers?.compactMap { $0 as? InkLassoRecognizer } ?? []
        XCTAssertEqual(lassos.count, 1, "the whiteboard host carries the lasso recognizer")
        XCTAssertTrue(lassos.first?.isEnabled ?? false)

        let zoom: CGFloat = 2.5
        canvas.setZoomScale(zoom, animated: false)
        canvas.setContentOffset(CGPoint(x: 1200 * zoom - 200, y: 900 * zoom - 200), animated: false)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(canvas.zoomScale, zoom, accuracy: 0.001, "precondition: zoomed")
        let offset = canvas.contentOffset

        // The target's ink on screen, in host points, with a margin that
        // stays clear of its neighbours (100 page points = 250 on screen).
        let bounds = target.renderBounds
        let screenBox = CGRect(x: bounds.minX * zoom - offset.x, y: bounds.minY * zoom - offset.y,
                               width: bounds.width * zoom, height: bounds.height * zoom).insetBy(dx: -20, dy: -20)
        XCTAssertTrue(host.bounds.contains(screenBox), "precondition: the target is on screen at \(screenBox)")

        let finger = PointRecognizer()
        finger.host = host
        func page(_ screen: CGPoint) -> CGPoint {
            finger.hostPoint = screen
            return selection.pagePoint(of: finger)
        }
        let corners = InkSelection.corners(of: screenBox) + [CGPoint(x: screenBox.minX, y: screenBox.minY)]
        var loop: [CGPoint] = []
        for (a, b) in zip(corners, corners.dropFirst()) {
            for step in 0..<20 {
                let t = CGFloat(step) / 20
                loop.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        selection.lassoBegan(at: page(loop[0]))
        for point in loop.dropFirst() { selection.lassoMoved(to: page(point)) }

        // The conversion itself: screen point plus offset, over the zoom.
        let first = try XCTUnwrap(selection.display.lasso.first)
        XCTAssertEqual(first.x, (loop[0].x + offset.x) / zoom, accuracy: 0.01)
        XCTAssertEqual(first.y, (loop[0].y + offset.y) / zoom, accuracy: 0.01)

        selection.select(lasso: selection.display.lasso)
        let selected = try XCTUnwrap(selection.selectedStrokes, "the loop around the stroke on screen selects it")
        XCTAssertEqual(selected.strokes.map(StrokeIDMap.Fingerprint.init), [StrokeIDMap.Fingerprint(target)],
                       "exactly the stroke under the loop, not its neighbours")
        let box = try XCTUnwrap(selection.display.corners)
        let xs = box.map(\.x), ys = box.map(\.y)
        XCTAssertEqual(xs.min()!, bounds.minX, accuracy: 1, "the box is on the ink, in page points")
        XCTAssertEqual(xs.max()!, bounds.maxX, accuracy: 1)
        XCTAssertEqual(ys.min()!, bounds.minY, accuracy: 1)
        XCTAssertEqual(ys.max()!, bounds.maxY, accuracy: 1)

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(viewport.zoomScale, zoom, accuracy: 0.001, "the overlay draws through the board's zoom")
        try savePNG(of: window, name: "wb-zoomed-lasso")

        // A Pencil down inside the box drags it (InkLassoRecognizer's
        // isMoving branch): page-point deltas between samples.
        let startScreen = CGPoint(x: screenBox.midX, y: screenBox.midY)
        let endScreen = CGPoint(x: startScreen.x + 50, y: startScreen.y + 30)
        let start = page(startScreen)
        XCTAssertTrue(selection.contains(pagePoint: start), "a Pencil down on the ink on screen is inside the box")
        let end = page(endScreen)
        let before = canvas.drawing.strokes.map(\.renderBounds)
        selection.beginGesture()
        selection.translate(by: CGPoint(x: end.x - start.x, y: end.y - start.y))
        selection.endGesture()
        let after = canvas.drawing.strokes.map(\.renderBounds)
        XCTAssertEqual(after[0].minX - before[0].minX, 50 / zoom, accuracy: 0.5, "the ink follows the Pencil at the zoom")
        XCTAssertEqual(after[0].minY - before[0].minY, 30 / zoom, accuracy: 0.5)
        XCTAssertEqual(after[1], before[1], "the stroke below is untouched")
        XCTAssertEqual(after[2], before[2], "the stroke beside it is untouched")

        try await Task.sleep(for: .milliseconds(100))   // the event's undo group closes
        canvas.undoManager?.undo()
        XCTAssertEqual(canvas.drawing.strokes[0].renderBounds, before[0], "one undo puts the dragged ink back")
    }

    /// PLAN.md, owed on the iPad: "The Pencil lasso on a zoomed whiteboard",
    /// the panning half. On the board one finger always pans (minimum one
    /// touch on an iPad), at every zoom, so the question "does the Pencil
    /// pan while lassoing" is open at zoom 1 as well as zoomed in.
    ///
    /// Checks: with the lasso picked, the board's pan is live while the loop
    /// is drawn (nothing selected yet), takes one touch, and fails if its
    /// allowed touch types include `.pencil` - the same reasoning as the
    /// paged test above. Logs every recognizer on the board and its host.
    ///
    /// Cannot show: a private PencilKit delegate refusing the Pencil for the
    /// pan; that needs a real touch. If this fails, check on the iPad: open
    /// a whiteboard, zoom in, pick the lasso, draw a loop, watch the board.
    func testWhiteboardLasso_thePencilCannotPanTheBoard() async throws {
        let (window, canvas, selection, _, host) = try await hostBoard()
        defer { close(window) }
        canvas.drawing = PKDrawing(strokes: [line(x: 300, y: 250, index: 0)])
        pickLasso(canvas, selection)
        canvas.setZoomScale(2.5, animated: false)
        try await Task.sleep(for: .milliseconds(200))

        let pan = canvas.panGestureRecognizer
        for recognizer in canvas.gestureRecognizers ?? [] { print("PROBE board canvas recognizer: \(describe(recognizer))") }
        for recognizer in host.gestureRecognizers ?? [] { print("PROBE board host recognizer: \(describe(recognizer))") }
        XCTAssertFalse(canvas.drawingGestureRecognizer.isEnabled)
        XCTAssertTrue(pan.isEnabled, "precondition: nothing selected, the pan is live while the loop is drawn")
        if !CanvasInput.isMac {
            XCTAssertEqual(pan.minimumNumberOfTouches, 1, "precondition: one touch pans the board")
        }
        XCTAssertFalse(touchTypes(pan).contains(.pencil),
                       "With the lasso in hand, the board's pan takes one touch and allows Pencil touches \(describe(pan)). "
                       + "PencilKit's drawing recognizer is disabled and the app sets nothing else, so a Pencil lasso loop can pan the board "
                       + "unless a private PencilKit delegate refuses it. Check on the iPad.")
    }

    // MARK: - 3. Hold-to-snap gets the Pencil during a PencilKit stroke

    /// PLAN.md, owed on the iPad: "The shape hold-to-snap recognizer gets
    /// the Pencil touch during a PencilKit stroke."
    ///
    /// Checks, on both a hosted paged canvas and a hosted whiteboard, with a
    /// pen in hand: exactly one `ShapeHoldRecognizer` on the host, pointed at
    /// this canvas, enabled, accepting Pencil touches, not exclusive about
    /// touch type, cancelling and delaying nothing; PencilKit's drawing
    /// recognizer is live and sits on the canvas under the host, so both see
    /// the same touch; our delegate says the hold recognizes simultaneously
    /// with the drawing recognizer and asks for no failure requirement.
    /// PencilKit's own delegate answer and `canPrevent` are logged, not
    /// asserted: our "yes" to simultaneity is enough for UIKit not to fail
    /// the hold when the drawing begins.
    ///
    /// Cannot show: touches arriving during a real stroke, or the hold timer
    /// firing. The timer is private and only exists after `touchesBegan`,
    /// which needs a `UITouch`. That it is added to `RunLoop.main` in
    /// `.common` is read from the source (`ShapeHoldRecognizer.restartTimer`),
    /// not run.
    func testShapeHold_isOnTheHost_takesThePencil_andSharesWithPencilKit() async throws {
        do {
            let (window, canvas, _, host) = try await hostPage()
            defer { close(window) }
            checkShapeHold(on: host, canvas: canvas, label: "paged")
        }
        do {
            let (window, canvas, _, _, host) = try await hostBoard()
            defer { close(window) }
            checkShapeHold(on: host, canvas: canvas, label: "board")
        }
    }

    private func checkShapeHold(on host: UIView, canvas: PKCanvasView, label: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
        let holds = host.gestureRecognizers?.compactMap { $0 as? ShapeHoldRecognizer } ?? []
        XCTAssertEqual(holds.count, 1, "\(label): exactly one hold recognizer on the host", file: file, line: line)
        guard let hold = holds.first else { return }
        XCTAssertTrue(hold.canvas === canvas, "\(label): it reads this canvas's zoom and policy", file: file, line: line)
        XCTAssertTrue(hold.isEnabled, "\(label)", file: file, line: line)
        XCTAssertTrue(touchTypes(hold).contains(.pencil), "\(label): it accepts Pencil touches", file: file, line: line)
        XCTAssertFalse(hold.requiresExclusiveTouchType, "\(label)", file: file, line: line)
        XCTAssertFalse(hold.cancelsTouchesInView, "\(label): a pure observer", file: file, line: line)
        XCTAssertFalse(hold.delaysTouchesBegan, "\(label)", file: file, line: line)
        XCTAssertFalse(hold.delaysTouchesEnded, "\(label)", file: file, line: line)

        let drawing = canvas.drawingGestureRecognizer
        XCTAssertTrue(drawing.isEnabled, "\(label): with a pen in hand PencilKit draws", file: file, line: line)
        XCTAssertTrue(drawing.view?.isDescendant(of: host) ?? false,
                      "\(label): PencilKit's recognizer is under the host, so a touch reaches both", file: file, line: line)
        XCTAssertTrue(hold.delegate?.gestureRecognizer?(hold, shouldRecognizeSimultaneouslyWith: drawing) ?? false,
                      "\(label): the hold recognizes alongside PencilKit's drawing", file: file, line: line)
        XCTAssertNotEqual(hold.delegate?.gestureRecognizer?(hold, shouldRequireFailureOf: drawing), true,
                          "\(label): the hold does not wait for the drawing to fail", file: file, line: line)

        let pkSimultaneous = drawing.delegate?.gestureRecognizer?(drawing, shouldRecognizeSimultaneouslyWith: hold)
        print("PROBE \(label) hold: \(describe(hold))")
        print("PROBE \(label) drawing: \(describe(drawing)) delegate=\(drawing.delegate.map { String(describing: type(of: $0)) } ?? "nil")")
        print("PROBE \(label) PencilKit simultaneous with hold: \(pkSimultaneous.map { "\($0)" } ?? "not answered")")
        print("PROBE \(label) drawing.canPrevent(hold)=\(drawing.canPrevent(hold)) hold.canBePrevented(by: drawing)=\(hold.canBePrevented(by: drawing))")
    }

    // MARK: - 4. One undo after a snap

    /// What PencilKit does when the Pencil lifts, as far as the app sees
    /// it: an undo registration for the stroke (here a snapshot restore,
    /// as `ShapeRecognizerTests` stands it in), the stroke in `drawing`,
    /// and `canvasViewDrawingDidChange`. Returns whether assigning
    /// `drawing` called the delegate by itself; if it did not, it is called
    /// here, as PencilKit would.
    private func commitLikePencilKit(_ stroke: PKStroke, on canvas: PKCanvasView) -> Bool {
        let before = canvas.drawing
        canvas.undoManager?.registerUndo(withTarget: canvas) { $0.setDrawingUndoably(before) }
        var after = before
        after.strokes.append(stroke)
        canvas.drawing = after
        let fired = canvas.drawing.strokes.last.map(StrokeIDMap.Fingerprint.init) != StrokeIDMap.Fingerprint(stroke)
        if !fired { canvas.delegate?.canvasViewDrawingDidChange?(canvas) }
        return fired
    }

    /// Undoes until there is nothing left: how many steps it took to reach
    /// `target`, and how many steps changed nothing.
    private func countUndo(on canvas: PKCanvasView, to target: [StrokeIDMap.Fingerprint]) -> (toTarget: Int?, noOps: Int, total: Int) {
        let undo = canvas.undoManager!
        var toTarget: Int?
        var noOps = 0
        var total = 0
        while undo.canUndo, total < 6 {
            let before = prints(canvas.drawing)
            undo.undo()
            total += 1
            let after = prints(canvas.drawing)
            if after == before { noOps += 1 }
            if toTarget == nil, after == target { toTarget = total }
        }
        return (toTarget, noOps, total)
    }

    private struct SnapSetup {
        let window: UIWindow
        let canvas: PKCanvasView
        let earlier: PKStroke
        let freehand: PKStroke
        let hold: ShapeHoldRecognizer
        let snap: ShapeSnapController
    }

    /// A hosted page with one earlier stroke, an empty undo stack, a pen in
    /// hand, and a held circle the snap controller has recognized: the
    /// state when the Pencil lifts after a hold.
    private func heldCircle() async throws -> SnapSetup {
        let (window, canvas, _, _) = try await hostPage()
        canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
        let earlier = line(x: 100, y: 150, index: 0)
        canvas.drawing = PKDrawing(strokes: [earlier])
        try await Task.sleep(for: .milliseconds(100))
        let coordinator = try XCTUnwrap(canvas.delegate as? PencilCanvasView.Coordinator)
        XCTAssertTrue(canvas.undoManager !== window.undoManager, "precondition: the page has its own undo stack")
        canvas.undoManager?.removeAllActions()

        let points = circlePoints(center: CGPoint(x: 390, y: 520), radius: 90)
        let hold = coordinator.shapeHold
        XCTAssertTrue(hold.canvas === canvas)
        // What the recognizer does when the Pencil has been still long
        // enough, and then when it lifts.
        XCTAssertTrue(hold.onHold(points), "precondition: the held circle is recognized")
        XCTAssertNotNil(coordinator.shapeSnap.pending)
        hold.onEnd(true)
        return SnapSetup(window: window, canvas: canvas, earlier: earlier, freehand: freehandStroke(points),
                         hold: hold, snap: coordinator.shapeSnap)
    }

    /// Handoff, item 4 (decided Oct 22): after a shape snap, one undo leaves
    /// the page as it was before the stroke.
    ///
    /// Checks the app's half, through the real path: the hosted page's
    /// coordinator, its `ShapeHoldRecognizer` callbacks and
    /// `canvasViewDrawingDidChange` -> `ShapeSnapController.applyIfPending`,
    /// on the page's own `UndoManager` with its default event grouping. The
    /// stroke's commit and the snap land in the same run-loop turn, as they
    /// do when PencilKit registers its stroke undo before it calls the
    /// delegate. Then: the freehand stroke is gone and a shape is in its
    /// place, one undo gives exactly the pre-stroke drawing, there is no
    /// further undo step (so none that changes nothing), and redo brings the
    /// shape back.
    ///
    /// Cannot show: PencilKit's own stroke undo. Without a real stroke it
    /// cannot be produced, so a snapshot restore registered just before the
    /// commit stands in for it. When and how PencilKit really registers it
    /// (same group, own group, "remove this stroke" rather than a snapshot)
    /// is what the iPad has to show.
    func testShapeSnap_oneUndoInTheSameEvent_isThePageBeforeTheStroke() async throws {
        let setup = try await heldCircle()
        defer { close(setup.window) }
        let canvas = setup.canvas
        let preStroke = prints(PKDrawing(strokes: [setup.earlier]))

        let fired = commitLikePencilKit(setup.freehand, on: canvas)
        print("PROBE assigning drawing called canvasViewDrawingDidChange by itself: \(fired)")
        XCTAssertNil(setup.snap.pending, "the pending shape is used up")
        let snapped = prints(canvas.drawing)
        XCTAssertEqual(snapped.first, preStroke.first, "the earlier stroke stays")
        XCTAssertFalse(snapped.contains(StrokeIDMap.Fingerprint(setup.freehand)), "the freehand stroke was replaced")
        XCTAssertEqual(snapped.count, 2, "earlier stroke + one solid shape")
        let shape = try XCTUnwrap(canvas.drawing.strokes.last)
        print("PROBE snapped shape renderBounds=\(shape.renderBounds) points=\(shape.path.count) size=\(shape.path.first?.size ?? .zero)")
        XCTAssertGreaterThan(shape.renderBounds.width, 150, "the shape spans the held circle (radius 90)")

        try await Task.sleep(for: .milliseconds(400))   // the event's undo group closes, PencilKit redraws
        try savePNG(of: setup.window, name: "shape-snap-after")
        // The drawing itself, off-screen, on the main thread (never the
        // cooperative pool), in light mode: tells "the canvas had not
        // redrawn" apart from "the shape renders as nothing".
        let page = CGRect(x: 0, y: 0, width: 800, height: 800)
        var inkImage = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            inkImage = canvas.drawing.image(from: page, scale: 1)
        }
        let inkPNG = UIGraphicsImageRenderer(size: page.size).image { context in
            UIColor.white.setFill(); context.fill(page)
            inkImage.draw(in: page)
        }
        try savePNG(image: inkPNG, name: "shape-snap-drawing")

        let result = countUndo(on: canvas, to: preStroke)
        XCTAssertEqual(result.toTarget, 1, "one undo leaves the page as before the stroke (took \(String(describing: result.toTarget)))")
        XCTAssertEqual(result.total, 1, "no further undo step after that one; there were \(result.total)")
        XCTAssertEqual(result.noOps, 0, "\(result.noOps) undo step(s) changed nothing")

        canvas.undoManager?.redo()
        XCTAssertEqual(prints(canvas.drawing), snapped, "redo brings the shape back, not the freehand stroke")
    }
}
