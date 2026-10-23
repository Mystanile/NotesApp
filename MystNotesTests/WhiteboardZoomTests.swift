import XCTest
import SwiftUI
import PencilKit
@testable import Mystnotes

/// Zoom on a whiteboard survives the SwiftUI updates that every tool or
/// colour change causes.
@MainActor
final class WhiteboardZoomTests: XCTestCase {

    @Observable final class Knob { var style: ShapeLineStyle = .solid }

    private struct Board: View {
        @State var canvas = PKCanvasView()
        let knob: Knob
        let onCanvas: (PKCanvasView) -> Void
        var body: some View {
            WhiteboardCanvasView(canvasView: $canvas, shapeLineStyle: knob.style)
                .onAppear { onCanvas(canvas) }
        }
    }

    /// The content size is in zoomed points. Setting the board's 3000 again
    /// on an update while zoomed to 2x halved the area you could pan to.
    func testZoomedBoard_keepsItsScrollableSize_acrossAnUpdate() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        defer { window.rootViewController = nil; window.isHidden = true }
        let knob = Knob()
        var hosted: PKCanvasView?
        window.rootViewController = UIHostingController(rootView: Board(knob: knob) { hosted = $0 })
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(600))
        let canvas = try XCTUnwrap(hosted)

        canvas.setZoomScale(2, animated: false)
        XCTAssertEqual(canvas.contentSize.width, 6000, accuracy: 1, "precondition: zoom multiplies the content size")

        knob.style = .dashed
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(canvas.zoomScale, 2, accuracy: 0.001)
        XCTAssertEqual(canvas.contentSize.width, 6000, accuracy: 1, "the whole board is still reachable")
        XCTAssertEqual(canvas.minimumZoomScale, 800 / WhiteboardCanvasView.boardSize, accuracy: 0.001,
                       "zoomed all the way out, the board fills the view instead of sitting in a corner")
    }
}
