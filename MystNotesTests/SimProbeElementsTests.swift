import XCTest
import SwiftData
import SwiftUI
import UIKit
import PencilKit
import Vision
@testable import Mystnotes

/// Simulator probes for items PLAN.md owes the iPad before M1 exits, and
/// for two Oct 22 changes marked [not tested] (Oct 24, 2026).
///
/// What these can do: build the real views in a real window, set the
/// model and the controllers the way the gestures do, and look at the
/// pixels. What they cannot do: touch the screen. Public API can't make a
/// `UITouch`, so a SwiftUI `DragGesture`, `MagnifyGesture` or
/// `RotateGesture` closure never runs here - and those closures are
/// `private` inside `private` views, so they can't be called either. Each
/// test says which step that leaves to the iPad. Nothing here runs on a
/// Mac: Mac Catalyst is not one of the destinations.
///
/// Every test writes PNGs to the session's `probes/` folder (or the
/// temporary folder if that can't be written) and prints `PROBE_PNG`.
@MainActor
final class SimProbeElementsTests: XCTestCase {

    // MARK: - Shared setup

    private static let schema = Schema([
        Folder.self, Notebook.self, Page.self, TypedTextBlock.self,
        ImportedDocument.self, Link.self, Sticker.self
    ])

    /// One container for the class: screens with `@Query` (the elements
    /// overlay, the picture layer, the library) keep observing after their
    /// test, and a save in the next test would notify them about a
    /// container that had gone (CLAUDE.md gotcha). No test here inserts a
    /// Folder or a Notebook, so the library test still sees an empty one.
    private static var container: ModelContainer?
    private static func sharedContainer() throws -> ModelContainer {
        if let container { return container }
        let made = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        container = made
        return made
    }

    private var written: [URL] = []

    override func tearDown() {
        for url in written { try? FileManager.default.removeItem(at: url) }
        written = []
        super.tearDown()
    }

    private static let probeFolder = URL(fileURLWithPath:
        "/tmp/mystnotes-probes")

    private func savePNG(_ image: UIImage, _ name: String) {
        guard let data = image.pngData() else { return print("PROBE_PNG \(name): no PNG data") }
        let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("probes", isDirectory: true)
        for folder in [Self.probeFolder, fallback] {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent("\(name).png")
                try data.write(to: url)
                print("PROBE_PNG \(url.path)")
                return
            } catch {
                print("PROBE_PNG could not write to \(folder.path): \(error)")
            }
        }
    }

    /// A window of its own, light mode, above everything else.
    private func show<V: View>(_ view: V, size: CGSize) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.windowLevel = .alert + 1
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        return window
    }

    /// Takes the screen down with the test, not just hidden (PageReloadTests).
    private func close(_ window: UIWindow) {
        window.rootViewController = nil
        window.isHidden = true
    }

    private func settle(_ seconds: Double = 0.8) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    /// The window as pixels, top row first.
    private struct Shot {
        let image: UIImage
        let width: Int
        let height: Int
        let scale: CGFloat
        let pixels: [UInt8]

        init(_ window: UIWindow) throws {
            image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let cg = try XCTUnwrap(image.cgImage)
            width = cg.width
            height = cg.height
            scale = CGFloat(cg.width) / window.bounds.width
            var px = [UInt8](repeating: 0, count: width * height * 4)
            let ctx = try XCTUnwrap(CGContext(data: &px, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            pixels = px
        }

        /// The colour at a point in window points, or nil off the window.
        func rgb(_ point: CGPoint) -> (r: Int, g: Int, b: Int)? {
            let x = Int(point.x * scale), y = Int(point.y * scale)
            guard x >= 0, y >= 0, x < width, y < height else { return nil }
            let i = (y * width + x) * 4
            return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
        }

        /// The pixels in `rect` (window points) that pass `test`, as points.
        func points(in rect: CGRect, where test: (Int, Int, Int) -> Bool) -> [CGPoint] {
            let x0 = max(Int(rect.minX * scale), 0), x1 = min(Int(rect.maxX * scale), width)
            let y0 = max(Int(rect.minY * scale), 0), y1 = min(Int(rect.maxY * scale), height)
            guard x0 < x1, y0 < y1 else { return [] }
            var found: [CGPoint] = []
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let i = (y * width + x) * 4
                    if test(Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2])) {
                        found.append(CGPoint(x: CGFloat(x) / scale, y: CGFloat(y) / scale))
                    }
                }
            }
            return found
        }

        func boundingBox(in rect: CGRect, where test: (Int, Int, Int) -> Bool) -> CGRect? {
            let found = points(in: rect, where: test)
            guard let first = found.first else { return nil }
            return found.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
        }
    }

    private static func isWhite(_ r: Int, _ g: Int, _ b: Int) -> Bool { r > 235 && g > 235 && b > 235 }
    private static func isTeal(_ r: Int, _ g: Int, _ b: Int) -> Bool { b > 150 && r < 150 }
    /// The accent colour. The asset catalogue's AccentColor has no colour
    /// of its own, so it is the system blue (0, 122, 255).
    private static func isAccent(_ r: Int, _ g: Int, _ b: Int) -> Bool { b > 200 && r < 90 && g < 170 }
    private static func isYellow(_ r: Int, _ g: Int, _ b: Int) -> Bool { r > 200 && g > 160 && b < 100 }

    /// What `PageViewportLayer` does to a page point.
    private func screen(_ point: CGPoint, _ viewport: CanvasViewport) -> CGPoint {
        CGPoint(x: point.x * viewport.zoomScale - viewport.contentOffset.x,
                y: point.y * viewport.zoomScale - viewport.contentOffset.y)
    }

    private func gestureRecognizers(in view: UIView) -> [UIGestureRecognizer] {
        (view.gestureRecognizers ?? []) + view.subviews.flatMap(gestureRecognizers(in:))
    }

    private func describe(_ recognizer: UIGestureRecognizer) -> String {
        let host = recognizer.view.map { String(describing: type(of: $0)) } ?? "nil"
        return "\(type(of: recognizer)) on \(host) enabled=\(recognizer.isEnabled) "
            + "touchTypes=\(recognizer.allowedTouchTypes.map(\.intValue))"
    }

    // MARK: - 1. The [adjust] log from one image resize

    @Observable final class Live { var frame: CGRect? }

    /// As the detail view stacks them: the picture layer reading the live
    /// frame, and the handles writing it through a binding, both inside a
    /// page viewport.
    private struct AdjustHost: View {
        let page: Page
        let layerID: UUID
        let live: Live
        let viewport: CanvasViewport
        let pageSize: CGSize
        var body: some View {
            ZStack(alignment: .topLeading) {
                Color(white: 0.5)
                PageViewportLayer(viewport: viewport, pageSize: pageSize) { _ in
                    ImportedPageBackgroundView(page: page, liveFrame: live.frame, liveLayerID: layerID)
                        .id(page.id)
                }
                PageViewportLayer(viewport: viewport, pageSize: pageSize) { scale in
                    ImageAdjustOverlay(
                        frame: Binding(get: { live.frame ?? CGRect(origin: .zero, size: pageSize) },
                                       set: { live.frame = $0 }),
                        containerSize: pageSize,
                        scale: scale,
                        onDone: {}
                    )
                }
            }
            .ignoresSafeArea()
        }
    }

    private func writeTealPNG() throws -> String {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
        }
        let ref = "\(UUID().uuidString).png"
        let url = FileStore.url(for: ref)
        try XCTUnwrap(image.pngData()).write(to: url)
        written.append(url)
        return ref
    }

    /// PLAN.md "Owed on the iPad": the `[adjust]` log from one image resize.
    ///
    /// That log no longer exists: `da33c62` (Sept 25, 2026, "Finishing an
    /// action no longer resets the zoom or blinks the page") removed every
    /// `AppLog.note("adjust", …)` once resizing worked, and nothing in
    /// `MystNotes/` logs "adjust" today. So the item can't be checked
    /// anywhere, and `AppLog` has no in-memory seam to capture a line
    /// anyway (it writes `diagnostics/app.log` on a private queue).
    ///
    /// What the log was for - does the picture follow the corner handle -
    /// is checked here one step past `ArtworkEditingTests`, which sets the
    /// live frame with no handles on screen and at zoom 1: the handles
    /// (`ImageAdjustOverlay`) and the picture share one binding, at zoom
    /// 1.5 with the page scrolled, and both must land on the new corners.
    ///
    /// Cannot show: the drag itself. The resize closure is private to
    /// `ImageAdjustOverlay`; this writes the frame it would end on (a
    /// bottom-right drag of 60 page points, aspect kept).
    func testImageHandlesAndPicture_landOnTheSameCorners_afterOneResize_atZoom() async throws {
        let container = try Self.sharedContainer()
        let context = container.mainContext
        let page = Page(index: 0)
        context.insert(page)
        let doc = ImportedDocument(sourceType: "image", fileRef: try writeTealPNG(), page: page)
        doc.frameX = 0.1; doc.frameY = 0.1; doc.frameWidth = 0.5; doc.frameHeight = 0.375
        context.insert(doc)
        try context.save()

        let pageSize = CGSize(width: 300, height: 400)
        let placed = CGRect(x: 30, y: 40, width: 150, height: 150)    // the fractions above, in page points
        let viewport = CanvasViewport()
        viewport.zoomScale = 1.5
        viewport.contentOffset = CGPoint(x: 30, y: 20)
        viewport.hasSynced = true
        let live = Live()
        live.frame = placed                                           // as beginAdjustingImage opens the handles
        let window = try show(AdjustHost(page: page, layerID: doc.id, live: live, viewport: viewport, pageSize: pageSize)
            .modelContainer(container), size: CGSize(width: 600, height: 700))
        defer { close(window) }

        try await settle()
        let probe = CGPoint(x: 220, y: 230)                           // outside the placed picture, inside the resized one
        let before = try Shot(window)
        savePNG(before.image, "probe-image-resize-before")
        for corner in InkSelection.corners(of: placed) {
            let point = screen(corner, viewport)
            let px = try XCTUnwrap(before.rgb(point), "corner \(point) is off the window")
            XCTAssertTrue(Self.isWhite(px.r, px.g, px.b), "no handle on the picture's corner at \(point) before the resize: \(px)")
        }
        let outside = try XCTUnwrap(before.rgb(screen(probe, viewport)))
        XCTAssertFalse(Self.isTeal(outside.r, outside.g, outside.b), "the picture is drawn larger than its frame")

        let resized = CGRect(x: 30, y: 40, width: 210, height: 210)
        live.frame = resized                                          // what the binding's setter does on every drag step
        try await settle()
        let after = try Shot(window)
        savePNG(after.image, "probe-image-resize-after")
        for corner in InkSelection.corners(of: resized) {
            let point = screen(corner, viewport)
            let px = try XCTUnwrap(after.rgb(point), "corner \(point) is off the window")
            XCTAssertTrue(Self.isWhite(px.r, px.g, px.b), "the handles didn't follow the resize to \(point): \(px)")
        }
        let grown = try XCTUnwrap(after.rgb(screen(probe, viewport)))
        XCTAssertTrue(Self.isTeal(grown.r, grown.g, grown.b), "the picture didn't grow under the handles: \(grown) at \(screen(probe, viewport))")
        let oldCorner = try XCTUnwrap(after.rgb(screen(CGPoint(x: placed.maxX, y: placed.maxY), viewport)))
        XCTAssertTrue(Self.isTeal(oldCorner.r, oldCorner.g, oldCorner.b),
                      "the old bottom-right corner should now be inside the picture, with no handle left behind: \(oldCorner)")
    }

    // MARK: - 2. Sticker pinch and rotate

    /// The elements overlay as the detail view hosts it: inside a page
    /// viewport, over paper.
    private struct ElementsHost: View {
        let page: Page
        let viewport: CanvasViewport
        let pageSize: CGSize
        var body: some View {
            ZStack(alignment: .topLeading) {
                Color(white: 0.75)
                PageViewportLayer(viewport: viewport, pageSize: pageSize) { scale in
                    PageElementsOverlayView(page: page, scale: scale, onNavigateToPage: { _ in }, onSave: {},
                                            onRequestLinkDestinationChange: { _ in })
                }
            }
            .ignoresSafeArea()
        }
    }

    /// PLAN.md "Owed on the iPad": sticker pinch and rotate.
    ///
    /// Checks the half the simulator can reach: a sticker whose model says
    /// what a pinch of 1.5x and a quarter twist leave behind (frame scaled
    /// about its centre, `rotationDegrees` 90) is drawn that size, turned,
    /// about the same centre, at zoom 1 and at zoom 2 with the page
    /// scrolled; and the change survives a save into a fresh context. A
    /// flat symbol ("minus") makes the turn visible: wide before, tall after.
    ///
    /// Undo: the code registers none for a sticker pinch or twist (only
    /// `onSave`), so none is asked for here.
    ///
    /// Cannot show: the gesture. `pinchAndRotate` is a private
    /// `MagnifyGesture().simultaneously(with: RotateGesture())` closure in
    /// the private `StickerElementView`; nothing here can call it or touch
    /// the screen. Also unseen: whether its one-finger `DragGesture`
    /// moves the sticker during a two-finger pinch (both write `frameX`),
    /// and whether the canvas's own pinch takes the fingers first. The
    /// recognizers the window holds are printed (`PROBE_GR`) for reading.
    func testSticker_isDrawnPinchedAndTurnedAboutItsCentre_andKeepsIt() async throws {
        let container = try Self.sharedContainer()
        let context = container.mainContext
        let page = Page(index: 0)
        context.insert(page)
        let sticker = Sticker(assetRef: "minus", page: page)
        sticker.frameX = 200; sticker.frameY = 200; sticker.frameWidth = 120; sticker.frameHeight = 120
        context.insert(sticker)
        page.stickers = [sticker]
        try context.save()

        let viewport = CanvasViewport()
        viewport.hasSynced = true
        let window = try show(ElementsHost(page: page, viewport: viewport, pageSize: CGSize(width: 600, height: 800))
            .modelContainer(container), size: CGSize(width: 700, height: 700))
        defer { close(window) }
        try await settle()

        for recognizer in gestureRecognizers(in: window) { print("PROBE_GR sticker: \(describe(recognizer))") }

        let all = window.bounds
        let before = try Shot(window)
        savePNG(before.image, "probe-sticker-before")
        let flat = try XCTUnwrap(before.boundingBox(in: all, where: Self.isYellow), "the sticker isn't drawn")
        XCTAssertEqual(flat.midX, 260, accuracy: 3, "sticker not centred on its frame")
        XCTAssertEqual(flat.midY, 260, accuracy: 3, "sticker not centred on its frame")
        XCTAssertGreaterThan(flat.width, flat.height * 2, "a flat symbol should be drawn wide before the turn: \(flat)")

        // What the pinch leaves: 1.5x about the centre (260, 260), turned 90°.
        sticker.frameX = 170; sticker.frameY = 170; sticker.frameWidth = 180; sticker.frameHeight = 180
        sticker.rotationDegrees = 90
        try context.save()
        try await settle()
        let after = try Shot(window)
        savePNG(after.image, "probe-sticker-pinched-turned")
        let turned = try XCTUnwrap(after.boundingBox(in: all, where: Self.isYellow), "the sticker vanished after the pinch")
        XCTAssertEqual(turned.midX, 260, accuracy: 3, "the pinch or the turn moved the sticker's centre: \(turned)")
        XCTAssertEqual(turned.midY, 260, accuracy: 3, "the pinch or the turn moved the sticker's centre: \(turned)")
        XCTAssertGreaterThan(turned.height, turned.width * 2, "the sticker isn't drawn turned a quarter: \(turned)")
        XCTAssertEqual(turned.height, flat.width * 1.5, accuracy: 8, "the sticker isn't drawn 1.5x: \(flat) -> \(turned)")

        // On the ink at zoom: through the same viewport as the page.
        viewport.zoomScale = 2
        viewport.contentOffset = CGPoint(x: 100, y: 100)
        try await settle()
        let zoomed = try Shot(window)
        savePNG(zoomed.image, "probe-sticker-zoom2")
        let big = try XCTUnwrap(zoomed.boundingBox(in: all, where: Self.isYellow), "the sticker vanished at zoom 2")
        // From where it was drawn at zoom 1, not from the frame's centre:
        // the "minus" glyph sits ~1-2 pt off its frame's centre (its side
        // bearings), and at zoom 2 that doubles past the tolerance.
        XCTAssertEqual(big.midX, turned.midX * 2 - 100, accuracy: 3, "the sticker left its place on the page at zoom 2: \(turned) -> \(big)")
        XCTAssertEqual(big.midY, turned.midY * 2 - 100, accuracy: 3, "the sticker left its place on the page at zoom 2: \(turned) -> \(big)")
        XCTAssertEqual(big.height, turned.height * 2, accuracy: 10, "the sticker didn't scale with the page: \(big)")

        // Saved: a fresh context reads the pinch back.
        let id = sticker.id
        let fresh = ModelContext(container)
        let stored = try XCTUnwrap(try fresh.fetch(FetchDescriptor<Sticker>(predicate: #Predicate { $0.id == id })).first)
        XCTAssertEqual(stored.rotationDegrees, 90)
        XCTAssertEqual(stored.frameWidth, 180)
        XCTAssertEqual(stored.frameX, 170)
    }

    // MARK: - 3. Lasso corner handles

    /// The paged canvas's lasso layers, in the order and with the modifiers
    /// `NotebookDetailView.pagedCanvas` gives them (MystNotesDetailView.swift,
    /// the `toolState.activeKind == .lasso` block). A copy of that layout,
    /// because the real screen's tool is private `@State` a test can't set
    /// to the lasso; if those lines change, this must too. The selection's
    /// actions are a system edit menu on the canvas host now, so there is no
    /// toolbar to lay out.
    private struct LassoHost: View {
        let viewport: CanvasViewport
        let selection: InkSelectionController
        let pageSize: CGSize

        var body: some View {
            ZStack {
                Color(white: 0.5)                                     // the desk
                PageViewportLayer(viewport: viewport, pageSize: pageSize) { _ in Color(white: 0.75) }   // the paper
                PageViewportLayer(viewport: viewport, pageSize: pageSize) { scale in
                    InkSelectionOverlay(display: selection.display, scale: scale)
                }
                .allowsHitTesting(false)
                if let corners = selection.display.corners, corners.count == 4 {
                    PageViewportLayer(viewport: viewport, pageSize: pageSize) { scale in
                        InkSelectionHandles(corners: corners, scale: scale, controller: selection)
                    }
                }
            }
            .ignoresSafeArea()
        }
    }

    private func line(x: CGFloat, y: CGFloat, length: CGFloat = 100, index: Int) -> PKStroke {
        let points = stride(from: x, through: x + length, by: 5).map { px in
            PKStrokePoint(location: CGPoint(x: px, y: y), timeOffset: TimeInterval(px - x) * 0.01,
                          size: CGSize(width: 6, height: 6), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let path = PKStrokePath(controlPoints: points,
                                creationDate: Date(timeIntervalSinceReferenceDate: 720_000_000 + Double(index)))
        return PKStroke(ink: PKInk(.pen, color: .black), path: path, randomSeed: UInt32(4_000 + index))
    }

    /// A canvas with three lines of "ink" at `origin`, all selected.
    private func selected(at origin: CGPoint) -> (PKCanvasView, InkSelectionController) {
        let canvas = PKCanvasView()
        canvas.drawing = PKDrawing(strokes: (0..<3).map { line(x: origin.x, y: origin.y + CGFloat($0) * 20, index: $0) })
        let selection = InkSelectionController()
        selection.canvas = canvas
        selection.isActive = true
        selection.select(lasso: InkSelection.corners(of: CGRect(x: origin.x - 20, y: origin.y - 20, width: 140, height: 80)))
        return (canvas, selection)
    }

    private func assertHandles(on corners: [CGPoint], in shot: Shot, _ viewport: CanvasViewport, _ label: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        let center = InkSelection.center(of: corners)
        for corner in corners {
            let point = screen(corner, viewport)
            guard let px = shot.rgb(point) else {
                XCTFail("\(label): corner \(point) is off the window", file: file, line: line); continue
            }
            XCTAssertTrue(Self.isWhite(px.r, px.g, px.b), "\(label): no handle on the corner at \(point): \(px)", file: file, line: line)
            // 30 screen points outward from the box, nothing white: one handle, at the corner.
            let out = screen(center, viewport)
            let dx = point.x - out.x, dy = point.y - out.y
            let length = max(hypot(dx, dy), 1)
            let beyond = CGPoint(x: point.x + dx / length * 30, y: point.y + dy / length * 30)
            if let far = shot.rgb(beyond) {
                XCTAssertFalse(Self.isWhite(far.r, far.g, far.b), "\(label): something white 30 pt outside the corner at \(beyond)", file: file, line: line)
            }
        }
    }

    /// PLAN.md "Owed on the iPad": lasso corner handles.
    ///
    /// The handles are drawn on the selection's corners, at fit and at
    /// zoom 2 with the page scrolled, and after a resize through the same
    /// controller calls a handle drag makes (`beginGesture`, `scale(by:)`,
    /// `endGesture`) they move to the new corners. Pixels: each corner's
    /// centre is the handle's white fill on grey paper.
    ///
    /// Cannot show: a finger or the Mac pointer catching a handle (the
    /// drag closure in `InkSelectionHandles` is private and needs a touch),
    /// and anything on the Mac. The ink itself isn't drawn here - only the
    /// box and handles, which is what this checks.
    func testLassoHandles_sitOnTheSelectionCorners_atFitAtZoomAndAfterAResize() async throws {
        let (canvas, selection) = selected(at: CGPoint(x: 250, y: 400))
        defer { _ = canvas }
        let corners = try XCTUnwrap(selection.display.corners, "the lasso selected nothing")
        let viewport = CanvasViewport()
        viewport.hasSynced = true
        let window = try show(LassoHost(viewport: viewport, selection: selection, pageSize: CGSize(width: 820, height: 1000)),
                              size: CGSize(width: 820, height: 700))
        defer { close(window) }

        try await settle()
        let fit = try Shot(window)
        savePNG(fit.image, "probe-lasso-handles-zoom1")
        assertHandles(on: corners, in: fit, viewport, "zoom 1")

        viewport.zoomScale = 2
        viewport.contentOffset = CGPoint(x: 300, y: 400)
        try await settle()
        let zoomed = try Shot(window)
        savePNG(zoomed.image, "probe-lasso-handles-zoom2")
        assertHandles(on: corners, in: zoomed, viewport, "zoom 2")

        // What dragging a corner outward does: one gesture, scaled 1.5x.
        selection.beginGesture()
        selection.scale(by: 1.5)
        selection.endGesture()
        let grown = try XCTUnwrap(selection.display.corners)
        XCTAssertEqual(grown[1].x - grown[0].x, (corners[1].x - corners[0].x) * 1.5, accuracy: 0.5)
        try await settle()
        let resized = try Shot(window)
        savePNG(resized.image, "probe-lasso-handles-resized")
        assertHandles(on: grown, in: resized, viewport, "after a resize at zoom 2")
    }

    // MARK: - 4. Editing a text box: drag selects, a handle moves it

    private func textInputs(in view: UIView) -> [UIView] {
        ((view is UITextView || view is UITextField) ? [view] : []) + view.subviews.flatMap(textInputs(in:))
    }

    /// PLAN.md Oct 22 [not tested]: "Editing a text box: a drag in the
    /// text selects it instead of moving the box; a move handle at the top
    /// right moves it."
    ///
    /// Checks: the box hosted in the elements overlay, focused the way a
    /// tap would leave it (its text view made first responder), shows the
    /// move handle - an accent circle centred on the top-right corner -
    /// that isn't there before editing; focusing doesn't move the box.
    /// The window's gesture recognizers before and while editing are
    /// printed (`PROBE_GR`), with the ones that changed, so whether the
    /// box drag stands down can be read off them.
    ///
    /// Cannot show: a drag. The handle's and the box's `DragGesture`s are
    /// private closures in the private `TextBlockView`, and no touch can be
    /// made, so neither "a drag selects text" nor "the handle moves the
    /// box" can be driven. Which UIKit recognizer backs which SwiftUI
    /// gesture is SwiftUI's private business, so nothing is asserted about
    /// the list. If `@FocusState` doesn't follow a programmatic
    /// `becomeFirstResponder`, the handle check fails on the probe, not
    /// the app; the message says which it saw.
    func testEditingATextBox_showsTheMoveHandleAtTheTopRight() async throws {
        let container = try Self.sharedContainer()
        let context = container.mainContext
        let page = Page(index: 0)
        context.insert(page)
        let block = TypedTextBlock(content: "Drag here to select", page: page)
        block.frameX = 100; block.frameY = 150; block.frameWidth = 260; block.frameHeight = 60
        block.fontSize = 20
        context.insert(block)
        page.textBlocks = [block]
        try context.save()

        let viewport = CanvasViewport()
        viewport.hasSynced = true
        let window = try show(ElementsHost(page: page, viewport: viewport, pageSize: CGSize(width: 700, height: 900))
            .modelContainer(container), size: CGSize(width: 700, height: 600))
        defer { close(window) }
        try await settle()

        let corner = CGPoint(x: 360, y: 150)                          // the box's top right, on screen
        let square = CGRect(x: corner.x - 13, y: corner.y - 13, width: 26, height: 26)
        let idle = try Shot(window)
        savePNG(idle.image, "probe-textbox-idle")
        let idleAccent = idle.points(in: square, where: Self.isAccent).count

        let before = gestureRecognizers(in: window)
        let beforeEnabled = Dictionary(uniqueKeysWithValues: before.map { (ObjectIdentifier($0), $0.isEnabled) })
        for recognizer in before { print("PROBE_GR textbox idle: \(describe(recognizer))") }

        let input = try XCTUnwrap(textInputs(in: window).first, "no UIKit text view behind the text box")
        print("PROBE textbox input view: \(type(of: input))")
        XCTAssertTrue(input.becomeFirstResponder(), "the text box's \(type(of: input)) wouldn't become first responder")
        try await settle(1.2)
        defer { input.resignFirstResponder() }

        let editing = try Shot(window)
        savePNG(editing.image, "probe-textbox-editing")
        let accent = editing.points(in: square, where: Self.isAccent)
        let during = gestureRecognizers(in: window)
        for recognizer in during { print("PROBE_GR textbox editing: \(describe(recognizer))") }
        for recognizer in during {
            if let was = beforeEnabled[ObjectIdentifier(recognizer)] {
                if was != recognizer.isEnabled { print("PROBE_GR textbox changed: \(describe(recognizer)) (was enabled=\(was))") }
            } else {
                print("PROBE_GR textbox appeared: \(describe(recognizer))")
            }
        }
        let duringIDs = Set(during.map(ObjectIdentifier.init))
        for recognizer in before where !duringIDs.contains(ObjectIdentifier(recognizer)) {
            print("PROBE_GR textbox went away: \(describe(recognizer))")
        }

        // A 22 pt filled circle is ~380 pt²; the focused border alone
        // crossing this square is ~40.
        let handleArea = CGFloat(accent.count) / (editing.scale * editing.scale)
        XCTAssertGreaterThan(handleArea, 150,
                             "no move handle at the box's top right while editing (\(Int(handleArea)) pt² of accent there, "
                             + "\(idleAccent) px before editing); the text view is first responder: \(input.isFirstResponder)")
        if handleArea > 150 {
            let cx = accent.map(\.x).reduce(0, +) / CGFloat(accent.count)
            let cy = accent.map(\.y).reduce(0, +) / CGFloat(accent.count)
            XCTAssertEqual(cx, corner.x, accuracy: 4, "the move handle isn't centred on the top-right corner")
            XCTAssertEqual(cy, corner.y, accuracy: 4, "the move handle isn't centred on the top-right corner")
        }
        XCTAssertLessThan(CGFloat(idleAccent) / (idle.scale * idle.scale), 40, "a handle is drawn before the box is being edited")
        XCTAssertEqual(block.frameX, 100, "focusing the box moved it")
        XCTAssertEqual(block.frameY, 150, "focusing the box moved it")
    }

    // MARK: - 5. Empty library

    private func recognizedText(in image: UIImage) throws -> [(text: String, box: CGRect)] {
        let cg = try XCTUnwrap(image.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: cg).perform([request])
        let size = image.size
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let b = observation.boundingBox
            return (text, CGRect(x: b.minX * size.width, y: (1 - b.maxY) * size.height,
                                 width: b.width * size.width, height: b.height * size.height))
        }
    }

    /// PLAN.md Oct 22 [not tested]: "Empty library shows New Notebook and
    /// Import PDF or Image buttons."
    ///
    /// The real `LibraryView` at the top level, in a navigation stack as
    /// `ContentView` hosts it, over an empty container, full screen and at
    /// a Slide Over width. Vision reads the picture: both buttons' titles
    /// must be on screen. The tutorial seed is held off for the test (its
    /// flag set, then put back), or the library wouldn't stay empty.
    ///
    /// Cannot show: a tap on either button (no touches), so not that New
    /// Notebook opens its sheet or Import opens the file picker.
    func testEmptyLibrary_showsNewNotebookAndImportPDFOrImage() async throws {
        let container = try Self.sharedContainer()
        let context = container.mainContext
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Notebook>()), 0, "precondition: the library isn't empty")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Folder>()), 0, "precondition: the library isn't empty")
        let seeded = AppSettings.hasSeededTutorialNotebook
        AppSettings.hasSeededTutorialNotebook = true
        defer { AppSettings.hasSeededTutorialNotebook = seeded }

        for size in [CGSize(width: 1024, height: 768), CGSize(width: 375, height: 700)] {
            let window = try show(NavigationStack { LibraryView(parentFolder: nil) }.modelContainer(container), size: size)
            try await settle(1.5)
            let shot = try Shot(window)
            close(window)
            savePNG(shot.image, "probe-library-empty-\(Int(size.width))")

            let lines = try recognizedText(in: shot.image)
            print("PROBE library \(Int(size.width)) pt reads: \(lines.map(\.text))")
            for title in ["New Notebook", "Import PDF or Image"] {
                // Vision reads the capital I of "Image" as a lower-case l
                // ("Import PDF or lmage"), so compare with the two folded.
                func fold(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "l", with: "i") }
                let hit = lines.first { fold($0.text).contains(fold(title)) }
                XCTAssertNotNil(hit, "\(Int(size.width)) pt: no \"\(title)\" on the empty library; read \(lines.map(\.text))")
                if let hit {
                    XCTAssertTrue(CGRect(origin: .zero, size: size).contains(hit.box),
                                  "\(Int(size.width)) pt: \"\(title)\" is cut off at \(hit.box)")
                }
            }
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<Notebook>()), 0, "showing the library made a notebook")
        }
    }
}
