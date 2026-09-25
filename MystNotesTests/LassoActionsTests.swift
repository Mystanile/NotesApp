import XCTest
import PencilKit
@testable import Mystnotes

/// Lasso: recolour, copy as image, convert to text (M1, Sept 25, 2026).
final class LassoActionsTests: XCTestCase {

    private func line(from a: CGPoint, to b: CGPoint, ink: PKInk = PKInk(.pen, color: .black)) -> PKStroke {
        let points = (0...10).map { step -> PKStrokePoint in
            let t = CGFloat(step) / 10
            return PKStrokePoint(location: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t),
                                 timeOffset: Double(step) * 0.01, size: CGSize(width: 4, height: 4),
                                 opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }

    func testRecolouring_changesOnlyTheSelection_andKeepsIDsAndTransparency() {
        let highlighter = PKInk(.marker, color: UIColor.yellow.withAlphaComponent(0.4))
        let drawing = PKDrawing(strokes: [line(from: .zero, to: CGPoint(x: 50, y: 0)),
                                          line(from: CGPoint(x: 0, y: 20), to: CGPoint(x: 50, y: 20), ink: highlighter),
                                          line(from: CGPoint(x: 0, y: 40), to: CGPoint(x: 50, y: 40))])
        let recoloured = InkSelection.recoloring(drawing, indices: [0, 1], to: .red)

        func rgba(_ color: UIColor) -> [CGFloat] {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return [r, g, b, a].map { ($0 * 100).rounded() / 100 }
        }
        XCTAssertEqual(rgba(recoloured.strokes[0].ink.color), [1, 0, 0, 1])
        XCTAssertEqual(rgba(recoloured.strokes[1].ink.color), [1, 0, 0, 0.4], "a highlighter stays see-through")
        XCTAssertEqual(recoloured.strokes[1].ink.inkType, PKInk.InkType.marker)
        XCTAssertEqual(rgba(recoloured.strokes[2].ink.color), [0, 0, 0, 1], "unselected ink untouched")
        XCTAssertEqual(recoloured.strokes.map(StrokeIDMap.Fingerprint.init), drawing.strokes.map(StrokeIDMap.Fingerprint.init),
                       "a recoloured stroke is the same stroke (invariant 6)")
    }

    func testImageOfTheSelection_coversItsInk() throws {
        let strokes = [line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 160))]
        let image = try XCTUnwrap(InkSelection.image(of: strokes))
        XCTAssertEqual(image.size.width, strokes[0].renderBounds.width + 16, accuracy: 2)
        XCTAssertEqual(image.size.height, strokes[0].renderBounds.height + 16, accuracy: 2)
        XCTAssertNotNil(image.pngData())
    }

    /// Block capitals written as centre-line strokes, the way a hand
    /// writes them. The recogniser must read them back.
    func testRecogniser_readsTheSelectedStrokes() async throws {
        // Each letter in a 60 x 100 box, as polylines.
        let ellipse = (0...24).map { i -> CGPoint in
            let t = CGFloat(i) / 24 * 2 * .pi
            return CGPoint(x: 30 + 30 * cos(t), y: 50 + 50 * sin(t))
        }
        let letters: [[[CGPoint]]] = [
            [[CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 100)], [CGPoint(x: 60, y: 0), CGPoint(x: 60, y: 100)],
             [CGPoint(x: 0, y: 50), CGPoint(x: 60, y: 50)]],                                              // H
            [[CGPoint(x: 55, y: 0), CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 100), CGPoint(x: 55, y: 100)],
             [CGPoint(x: 0, y: 50), CGPoint(x: 45, y: 50)]],                                              // E
            [[CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 100), CGPoint(x: 55, y: 100)]],                        // L
            [[CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 100), CGPoint(x: 55, y: 100)]],                        // L
            [ellipse]                                                                                     // O
        ]
        var strokes: [PKStroke] = []
        for (index, letter) in letters.enumerated() {
            let origin = CGPoint(x: 40 + CGFloat(index) * 90, y: 60)
            for polyline in letter {
                // Corners tripled so the spline keeps them sharp, like a pen.
                let points = polyline.flatMap { [$0, $0, $0] }.enumerated().map {
                    PKStrokePoint(location: CGPoint(x: origin.x + $1.x, y: origin.y + $1.y), timeOffset: Double($0) * 0.01,
                                  size: CGSize(width: 6, height: 6), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
                }
                strokes.append(PKStroke(ink: PKInk(.pen, color: .black),
                                        path: PKStrokePath(controlPoints: points, creationDate: Date())))
            }
        }
        let text = await HandwritingRecognizer.text(in: PKDrawing(strokes: strokes))
        XCTAssertEqual(text?.uppercased().replacingOccurrences(of: " ", with: ""), "HELLO", "read: \(text ?? "nothing")")
    }

    // MARK: Through the controller, on a real canvas

    @MainActor
    func testDeleteExactly_removesThoseStrokes_orNothingIfOneHasGone() {
        let controller = InkSelectionController()
        let canvas = PKCanvasView()
        let strokes = [line(from: .zero, to: CGPoint(x: 50, y: 0)),
                       line(from: CGPoint(x: 0, y: 20), to: CGPoint(x: 50, y: 20)),
                       line(from: CGPoint(x: 0, y: 40), to: CGPoint(x: 50, y: 40))]
        canvas.drawing = PKDrawing(strokes: strokes)
        controller.canvas = canvas

        let gone = line(from: CGPoint(x: 0, y: 90), to: CGPoint(x: 10, y: 90))
        XCTAssertFalse(controller.delete(exactly: [strokes[0], gone]), "one stroke isn't there any more")
        XCTAssertEqual(canvas.drawing.strokes.count, 3, "nothing removed when refusing")

        XCTAssertTrue(controller.delete(exactly: [strokes[0], strokes[2]]))
        XCTAssertEqual(canvas.drawing.strokes.map(StrokeIDMap.Fingerprint.init), [StrokeIDMap.Fingerprint(strokes[1])])
    }

    @MainActor
    func testRecolor_changesTheLassoedStrokes() {
        let controller = InkSelectionController()
        let canvas = PKCanvasView()
        canvas.drawing = PKDrawing(strokes: [line(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 10)),
                                             line(from: CGPoint(x: 10, y: 200), to: CGPoint(x: 60, y: 200))])
        controller.canvas = canvas
        controller.select(lasso: [CGPoint(x: 0, y: 0), CGPoint(x: 80, y: 0), CGPoint(x: 80, y: 30), CGPoint(x: 0, y: 30)])
        XCTAssertTrue(controller.hasSelection)
        controller.recolor(.red)
        var red: CGFloat = 0
        canvas.drawing.strokes[0].ink.color.getRed(&red, green: nil, blue: nil, alpha: nil)
        XCTAssertEqual(red, 1, accuracy: 0.01)
        canvas.drawing.strokes[1].ink.color.getRed(&red, green: nil, blue: nil, alpha: nil)
        XCTAssertEqual(red, 0, accuracy: 0.01, "the stroke outside the loop stays black")
    }
}
