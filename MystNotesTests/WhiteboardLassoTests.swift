import XCTest
import SwiftUI
import PencilKit
@testable import Mystnotes

/// The whiteboard uses our own lasso (move, resize, overlay) like a paged
/// page. Hosted in a real window: the board scrolls and zooms itself, and
/// the overlay has to follow.
@MainActor
final class WhiteboardLassoTests: XCTestCase {

    private struct Board: View {
        @State var canvas = PKCanvasView()
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

    private func line(x: CGFloat, y: CGFloat, index: Int) -> PKStroke {
        let points = stride(from: x, through: x + 80, by: 5).map { px in
            PKStrokePoint(location: CGPoint(x: px, y: y), timeOffset: TimeInterval(px - x) * 0.01,
                          size: CGSize(width: 6, height: 6), opacity: 1, force: 1,
                          azimuth: 0, altitude: .pi / 2)
        }
        let path = PKStrokePath(controlPoints: points,
                                creationDate: Date(timeIntervalSinceReferenceDate: 700_000_000 + Double(index)))
        return PKStroke(ink: PKInk(.pen, color: .black), path: path, randomSeed: UInt32(900 + index))
    }

    private func host() async throws -> (UIWindow, PKCanvasView, InkSelectionController, CanvasViewport) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let viewport = CanvasViewport()
        let selection = InkSelectionController()
        var canvas: PKCanvasView?
        window.rootViewController = UIHostingController(rootView:
            Board(viewport: viewport, selection: selection) { canvas = $0 })
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(600))
        let c = try XCTUnwrap(canvas)
        c.drawing = PKDrawing(strokes: [line(x: 300, y: 250, index: 0), line(x: 300, y: 700, index: 1)])
        selection.canvas = c
        selection.isActive = true
        return (window, c, selection, viewport)
    }

    private func close(_ window: UIWindow) {
        window.rootViewController = nil
        window.isHidden = true
    }

    func testWhiteboard_moveAndScale_touchOnlyTheSelection() async throws {
        let (window, canvas, selection, _) = try await host()
        defer { close(window) }
        let before = canvas.drawing.strokes.map(\.renderBounds)

        selection.select(lasso: InkSelection.corners(of: CGRect(x: 250, y: 200, width: 250, height: 100)))
        XCTAssertTrue(selection.hasSelection)
        selection.beginGesture()
        selection.translate(by: CGPoint(x: 40, y: 20))
        selection.endGesture()
        let moved = canvas.drawing.strokes.map(\.renderBounds)
        XCTAssertEqual(moved[0].minX, before[0].minX + 40, accuracy: 0.5)
        XCTAssertEqual(moved[0].minY, before[0].minY + 20, accuracy: 0.5)
        XCTAssertEqual(moved[1], before[1], "the unselected stroke is untouched")

        selection.beginGesture()
        selection.scale(by: 2)
        selection.endGesture()
        let scaled = canvas.drawing.strokes.map(\.renderBounds)
        XCTAssertEqual(scaled[0].width, moved[0].width * 2, accuracy: 4)   // renderBounds pads by the ink width
        XCTAssertEqual(scaled[1], before[1])
    }

    func testWhiteboard_overlayFollowsTheStrokesWhenZoomedAndScrolled() async throws {
        let (window, canvas, selection, viewport) = try await host()
        defer { close(window) }

        canvas.setZoomScale(2, animated: false)
        canvas.setContentOffset(CGPoint(x: 400, y: 300), animated: false)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(viewport.zoomScale, 2, accuracy: 0.001, "the board publishes its zoom")
        XCTAssertEqual(viewport.contentOffset.x, 400, accuracy: 0.5)
        XCTAssertEqual(viewport.contentOffset.y, 300, accuracy: 0.5)

        selection.select(lasso: InkSelection.corners(of: CGRect(x: 250, y: 200, width: 250, height: 100)))
        let corners = try XCTUnwrap(selection.display.corners)
        // What PageViewportLayer does: scale, then subtract the offset.
        let screen = corners.map { CGPoint(x: $0.x * viewport.zoomScale - viewport.contentOffset.x,
                                           y: $0.y * viewport.zoomScale - viewport.contentOffset.y) }
        let xs = screen.map(\.x), ys = screen.map(\.y)
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        let stroke = canvas.drawing.strokes[0].renderBounds
        let expected = CGRect(x: stroke.minX * 2 - 400, y: stroke.minY * 2 - 300,
                              width: stroke.width * 2, height: stroke.height * 2)
        // The box is the strokes' bounds, so it must hug them on screen.
        XCTAssertEqual(box.minX, expected.minX, accuracy: 1)
        XCTAssertEqual(box.minY, expected.minY, accuracy: 1)
        XCTAssertEqual(box.width, expected.width, accuracy: 1)
        XCTAssertEqual(box.height, expected.height, accuracy: 1)

        // A screen point on the ink lands inside the selection.
        let viewPoint = CGPoint(x: expected.midX, y: expected.midY)
        XCTAssertTrue(selection.contains(pagePoint: viewport.pagePoint(from: viewPoint)))

        // Picture for the eye.
        try await Task.sleep(for: .milliseconds(400))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { window.layer.render(in: $0.cgContext) }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wb-selection.png")
        try image.pngData()?.write(to: url)
        print("WB_SCREENSHOT \(url.path)")
    }
}
