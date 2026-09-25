import XCTest
import PencilKit
import UIKit
@testable import Mystnotes

/// The lasso's arithmetic: what a loop selects, and what moving, resizing
/// and rotating does to the strokes - above all that none of it changes
/// which stroke a stroke is.
final class InkSelectionTests: XCTestCase {

    // MARK: - Helpers

    /// A straight horizontal stroke from `from` to `to` at `y`, `width`
    /// points wide.
    private func line(from: CGFloat, to: CGFloat, y: CGFloat, width: CGFloat = 4, index: Int = 0) -> PKStroke {
        let points = stride(from: from, through: to, by: 5).map { x in
            PKStrokePoint(location: CGPoint(x: x, y: y), timeOffset: TimeInterval(x - from) * 0.01,
                          size: CGSize(width: width, height: width), opacity: 1, force: 1,
                          azimuth: 0, altitude: .pi / 2)
        }
        let path = PKStrokePath(controlPoints: points,
                                creationDate: Date(timeIntervalSinceReferenceDate: 700_000_000 + Double(index)))
        return PKStroke(ink: PKInk(.pen, color: .black), path: path, randomSeed: UInt32(500 + index))
    }

    private func rect(_ r: CGRect) -> [CGPoint] { InkSelection.corners(of: r) }

    private func fingerprints(_ drawing: PKDrawing) -> [StrokeIDMap.Fingerprint] {
        drawing.strokes.map(StrokeIDMap.Fingerprint.init)
    }

    /// Dark pixels in a render of the drawing - a proxy for "how much ink
    /// is on the page".
    private func inkArea(_ drawing: PKDrawing, in bounds: CGRect) throws -> Int {
        let image = drawing.image(from: bounds, scale: 1)
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var count = 0
        for pixel in stride(from: 0, to: bytes.count, by: 4) where bytes[pixel + 3] > 128 { count += 1 }
        return count
    }

    // MARK: - Selecting

    /// A loop takes the strokes that are mostly inside it, not the ones it
    /// merely clips.
    func testLasso_takesStrokesMostlyInside() {
        let drawing = PKDrawing(strokes: [
            line(from: 10, to: 90, y: 50, index: 0),      // fully inside
            line(from: 10, to: 90, y: 150, index: 1),     // fully outside
            line(from: 60, to: 200, y: 60, index: 2),     // clipped: 40 of 140 inside
            line(from: 10, to: 120, y: 70, index: 3),     // mostly inside: 90 of 110
        ])
        let loop = rect(CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(InkSelection.strokeIndices(of: drawing, insideLasso: loop), [0, 3])
        XCTAssertEqual(InkSelection.strokeIndices(of: drawing, insideLasso: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]), [],
                       "a loop needs three points to enclose anything")
    }

    /// A stroke that has already been moved is judged where it *is*, not
    /// where it was drawn.
    func testLasso_seesStrokesWhereTheirTransformPutThem() {
        var moved = line(from: 10, to: 90, y: 50)
        moved.transform = CGAffineTransform(translationX: 300, y: 0)
        let drawing = PKDrawing(strokes: [moved])
        XCTAssertEqual(InkSelection.strokeIndices(of: drawing, insideLasso: rect(CGRect(x: 0, y: 0, width: 100, height: 100))), [])
        XCTAssertEqual(InkSelection.strokeIndices(of: drawing, insideLasso: rect(CGRect(x: 300, y: 0, width: 100, height: 100))), [0])
    }

    // MARK: - Moving, resizing, rotating

    /// Invariant 6: the strokes are the same strokes afterwards. And only
    /// the selected ones move.
    func testTransforming_movesOnlyTheSelection_andKeepsEveryIdentity() {
        let drawing = PKDrawing(strokes: [line(from: 0, to: 100, y: 10, index: 0), line(from: 0, to: 100, y: 200, index: 1)])
        let before = fingerprints(drawing)
        let boundsBefore = drawing.strokes.map(\.renderBounds)

        let moved = InkSelection.transforming(drawing, indices: [0],
                                              by: InkSelection.transform(translation: CGPoint(x: 50, y: 30), about: .zero))
        XCTAssertEqual(moved.strokes.count, 2)
        XCTAssertEqual(fingerprints(moved), before, "a move never changes which stroke a stroke is")
        XCTAssertEqual(moved.strokes[0].renderBounds.origin.x, boundsBefore[0].origin.x + 50, accuracy: 0.5)
        XCTAssertEqual(moved.strokes[0].renderBounds.origin.y, boundsBefore[0].origin.y + 30, accuracy: 0.5)
        XCTAssertEqual(moved.strokes[1].renderBounds, boundsBefore[1], "the unselected stroke stays put")
    }

    /// A pinch doubles the selection about its own centre: twice the size,
    /// same middle.
    func testScaling_isAboutTheSelectionsCentre() {
        let drawing = PKDrawing(strokes: [line(from: 100, to: 200, y: 100, index: 0), line(from: 100, to: 200, y: 140, index: 1)])
        let bounds = InkSelection.bounds(of: drawing, indices: [0, 1])
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let scaled = InkSelection.transforming(drawing, indices: [0, 1],
                                               by: InkSelection.transform(scale: 2, about: center))
        let after = InkSelection.bounds(of: scaled, indices: [0, 1])
        XCTAssertEqual(after.midX, bounds.midX, accuracy: 1)
        XCTAssertEqual(after.midY, bounds.midY, accuracy: 1)
        XCTAssertEqual(after.width, bounds.width * 2, accuracy: 6, "render bounds include the ink's width, hence the slack")
        XCTAssertEqual(fingerprints(scaled), fingerprints(drawing))
    }

    /// Two steps compose: scaling and then moving lands where one combined
    /// transform would.
    func testGestureSteps_compose() {
        let center = CGPoint(x: 50, y: 50)
        let step1 = InkSelection.transform(scale: 2, about: center)
        let step2 = InkSelection.transform(translation: CGPoint(x: 10, y: 0), about: center)
        let point = CGPoint(x: 60, y: 50)
        let stepwise = point.applying(step1).applying(step2)
        let combined = point.applying(step1.concatenating(step2))
        XCTAssertEqual(stepwise.x, combined.x, accuracy: 0.0001)
        XCTAssertEqual(stepwise.x, 80, accuracy: 0.0001)
    }

    /// The box the overlay draws follows a rotation as a rotated box, and
    /// hit-testing it uses the rotated shape.
    func testRotatedBox_hitTestsAsRotated() {
        let corners = InkSelection.corners(of: CGRect(x: 0, y: 0, width: 100, height: 20))
        let rotated = corners.map { $0.applying(InkSelection.transform(rotation: .pi / 2, about: CGPoint(x: 50, y: 10))) }
        XCTAssertTrue(InkSelection.polygon(rotated, contains: CGPoint(x: 50, y: 50)))
        XCTAssertFalse(InkSelection.polygon(rotated, contains: CGPoint(x: 90, y: 10)),
                       "the unrotated box would have contained this")
        XCTAssertEqual(InkSelection.center(of: rotated).x, 50, accuracy: 0.0001)
    }

    // MARK: - Duplicate, cut, paste

    /// A duplicate is a new stroke, never a second reference to the old
    /// one's identity - and duplicates of a batch differ from each other.
    func testReidentified_givesEveryCopyItsOwnFingerprint() {
        let originals = [line(from: 0, to: 100, y: 10, index: 0), line(from: 0, to: 100, y: 20, index: 1)]
        let copies = InkSelection.reidentified(originals, at: Date(timeIntervalSinceReferenceDate: 900_000_000))
        let originalPrints = Set(originals.map(StrokeIDMap.Fingerprint.init))
        let copyPrints = copies.map(StrokeIDMap.Fingerprint.init)
        XCTAssertEqual(Set(copyPrints).count, copies.count, "each copy is its own stroke")
        XCTAssertTrue(originalPrints.isDisjoint(with: copyPrints), "and none of them is the original")
        XCTAssertEqual(copies.map { $0.path.count }, originals.map { $0.path.count }, "same ink, same points")
        XCTAssertEqual(copies.map(\.randomSeed), originals.map(\.randomSeed), "same texture")
    }

    func testPasteboardData_roundTripsTheStrokes() throws {
        let strokes = [line(from: 0, to: 100, y: 10, index: 0), line(from: 0, to: 50, y: 20, index: 1)]
        let data = InkSelection.pasteboardData(for: strokes)
        let back = try XCTUnwrap(InkSelection.strokes(fromPasteboardData: data))
        XCTAssertEqual(back.count, 2)
        XCTAssertEqual(back.map { $0.path.count }, strokes.map { $0.path.count })
        XCTAssertEqual(back.map(\.renderBounds), strokes.map(\.renderBounds))
        XCTAssertNil(InkSelection.strokes(fromPasteboardData: Data("not ink".utf8)))
    }

    func testRemoving_andAppending() {
        let drawing = PKDrawing(strokes: [line(from: 0, to: 100, y: 10, index: 0), line(from: 0, to: 100, y: 20, index: 1)])
        let removed = InkSelection.removing(drawing, indices: [0])
        XCTAssertEqual(fingerprints(removed), [fingerprints(drawing)[1]])
        let (appended, indices) = InkSelection.appending(InkSelection.strokes(of: drawing, indices: [0]), to: removed)
        XCTAssertEqual(indices, [1])
        XCTAssertEqual(appended.strokes.count, 2)
    }

    // MARK: - The controller on a real canvas

    @MainActor
    private func canvas(with strokes: [PKStroke]) -> (PageCanvasView, InkSelectionController) {
        let canvas = PageCanvasView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        canvas.drawing = PKDrawing(strokes: strokes)
        let controller = InkSelectionController()
        controller.canvas = canvas
        controller.isActive = true
        return (canvas, controller)
    }

    /// A drag is many small steps and one undo: the whole move comes back
    /// in a single undo, and goes again in a single redo.
    @MainActor
    func testController_moveIsOneUndoStep_andTheSelectionSurvivesIt() {
        let (canvas, controller) = canvas(with: [line(from: 10, to: 90, y: 50, index: 0), line(from: 10, to: 90, y: 300, index: 1)])
        let original = canvas.drawing.strokes[0].renderBounds
        var changes = 0
        controller.onDrawingChanged = { changes += 1 }

        controller.select(lasso: rect(CGRect(x: 0, y: 0, width: 100, height: 100)))
        XCTAssertTrue(controller.hasSelection)
        XCTAssertEqual(controller.display.corners?.count, 4)

        controller.beginGesture()
        for _ in 0..<3 { controller.translate(by: CGPoint(x: 10, y: 5)) }
        XCTAssertEqual(canvas.drawing.strokes.count, 2, "a gesture in progress never removes ink")
        controller.endGesture()

        XCTAssertEqual(canvas.drawing.strokes[0].renderBounds.minX, original.minX + 30, accuracy: 0.5)
        XCTAssertEqual(canvas.drawing.strokes[0].renderBounds.minY, original.minY + 15, accuracy: 0.5)
        XCTAssertEqual(changes, 1, "one autosave per gesture, not per step")

        canvas.undoManager?.undo()
        XCTAssertEqual(canvas.drawing.strokes[0].renderBounds, original, "one undo takes the whole drag back")
        XCTAssertTrue(controller.hasSelection, "the strokes are still there, so the selection is")
        // The box re-syncs to where the ink actually is when the next
        // gesture starts.
        controller.beginGesture()
        let corners = controller.display.corners ?? []
        XCTAssertEqual(InkSelection.center(of: corners).x, original.midX, accuracy: 1)
        controller.endGesture()

        canvas.undoManager?.redo()
        XCTAssertEqual(canvas.drawing.strokes[0].renderBounds.minX, original.minX + 30, accuracy: 0.5)
    }

    /// The ask: a pinch resizes the selection - about its own middle, and
    /// the box follows.
    @MainActor
    func testController_pinchResizesAboutTheSelectionsCentre() {
        let (canvas, controller) = canvas(with: [line(from: 100, to: 200, y: 100, index: 0), line(from: 100, to: 200, y: 140, index: 1)])
        let before = InkSelection.bounds(of: canvas.drawing, indices: [0, 1])
        let prints = canvas.drawing.strokes.map(StrokeIDMap.Fingerprint.init)
        controller.select(lasso: rect(CGRect(x: 80, y: 80, width: 140, height: 80)))

        controller.beginGesture()
        controller.scale(by: 1.5)
        controller.scale(by: 1.5)   // two pinch steps compound to 2.25x
        controller.endGesture()

        let after = InkSelection.bounds(of: canvas.drawing, indices: [0, 1])
        XCTAssertEqual(after.midX, before.midX, accuracy: 1)
        XCTAssertEqual(after.midY, before.midY, accuracy: 1)
        XCTAssertEqual(after.width, before.width * 2.25, accuracy: 8)
        XCTAssertEqual(canvas.drawing.strokes.map(StrokeIDMap.Fingerprint.init), prints, "invariant 6")

        let corners = try! XCTUnwrap(controller.display.corners)
        XCTAssertEqual(InkSelection.center(of: corners).x, before.midX, accuracy: 1)
        XCTAssertEqual(corners[1].x - corners[0].x, before.width * 2.25, accuracy: 1, "the box grew with the ink")
    }

    /// A twist turns the ink and the box together, and a pinch and a
    /// twist at once are one gesture with one undo.
    @MainActor
    func testController_rotateAndPinchTogether_areOneGesture() {
        let (canvas, controller) = canvas(with: [line(from: 100, to: 200, y: 100)])
        let original = canvas.drawing
        controller.select(lasso: rect(CGRect(x: 80, y: 80, width: 140, height: 40)))
        let center = InkSelection.center(of: controller.display.corners ?? [])

        controller.beginGesture()          // pinch began
        controller.beginGesture()          // rotation began
        controller.scale(by: 2)
        controller.rotate(by: .pi / 2)
        controller.endGesture()
        XCTAssertNotEqual(canvas.drawing.strokes[0].transform, original.strokes[0].transform, "still mid-gesture: the second finger is down")
        controller.endGesture()

        let bounds = canvas.drawing.strokes[0].renderBounds
        XCTAssertGreaterThan(bounds.height, bounds.width, "a horizontal line, turned upright")
        XCTAssertEqual(bounds.midX, center.x, accuracy: 1)
        XCTAssertEqual(bounds.midY, center.y, accuracy: 1)

        canvas.undoManager?.undo()
        XCTAssertEqual(canvas.drawing.strokes[0].transform, original.strokes[0].transform, "one undo for the pinch and the twist")
    }

    /// If the strokes go away under the selection - an undo of the stroke,
    /// an erase, a sync - the selection lets go rather than acting on
    /// whatever is at those indices now.
    @MainActor
    func testController_letsGoWhenAStrokeIsGone() {
        let (canvas, controller) = canvas(with: [line(from: 10, to: 90, y: 50, index: 0), line(from: 10, to: 90, y: 60, index: 1)])
        controller.select(lasso: rect(CGRect(x: 0, y: 0, width: 100, height: 100)))
        XCTAssertTrue(controller.hasSelection)

        canvas.drawing = InkSelection.removing(canvas.drawing, indices: [0])
        controller.beginGesture()
        controller.translate(by: CGPoint(x: 10, y: 0))
        controller.endGesture()
        XCTAssertFalse(controller.hasSelection)
        XCTAssertEqual(canvas.drawing.strokes[0].transform, .identity, "nothing was moved")
    }

    @MainActor
    func testController_duplicateAndPaste_addCopiesAndSelectThem() throws {
        let (canvas, controller) = canvas(with: [line(from: 10, to: 90, y: 50)])
        let original = canvas.drawing.strokes[0].renderBounds
        controller.select(lasso: rect(CGRect(x: 0, y: 0, width: 100, height: 100)))

        controller.duplicate()
        XCTAssertEqual(canvas.drawing.strokes.count, 2)
        let corners = try XCTUnwrap(controller.display.corners)
        XCTAssertEqual(corners[0].x, original.minX + 24, accuracy: 0.5, "the copy is the selection, nudged")
        XCTAssertEqual(Set(canvas.drawing.strokes.map(StrokeIDMap.Fingerprint.init)).count, 2, "two different strokes")

        controller.copySelection()
        XCTAssertTrue(InkSelectionController.pasteboardHasInk)
        controller.delete()
        XCTAssertEqual(canvas.drawing.strokes.count, 1)
        XCTAssertFalse(controller.hasSelection)

        controller.paste()
        XCTAssertEqual(canvas.drawing.strokes.count, 2)
        XCTAssertTrue(controller.hasSelection, "a paste is selected, since the next thing is to put it somewhere")

        canvas.undoManager?.undo()
        XCTAssertEqual(canvas.drawing.strokes.count, 1, "the paste is one undo step")
    }

    /// A pinch on selected ink resizes the ink and only the ink: the
    /// canvas's own pan and pinch are off while there is a selection, and
    /// back the moment there isn't. Both, synchronously - `isScrollEnabled`
    /// never touched the pinch, and the page zoomed under the selection.
    @MainActor
    func testController_selectionHoldsThePageStill() {
        let (canvas, controller) = canvas(with: [line(from: 10, to: 90, y: 50)])
        canvas.maximumZoomScale = 4   // so the scroll view has a pinch to gate
        let pinch = canvas.pinchGestureRecognizer
        XCTAssertTrue(canvas.panGestureRecognizer.isEnabled)

        controller.select(lasso: rect(CGRect(x: 0, y: 0, width: 100, height: 100)))
        XCTAssertFalse(canvas.panGestureRecognizer.isEnabled, "no panning the page under a selection")
        if let pinch { XCTAssertFalse(pinch.isEnabled, "and no zooming it: the pinch is the resize") }

        controller.clear()
        XCTAssertTrue(canvas.panGestureRecognizer.isEnabled)
        if let pinch { XCTAssertTrue(pinch.isEnabled) }

        // A page turn hands the old canvas its gestures back too.
        controller.select(lasso: rect(CGRect(x: 0, y: 0, width: 100, height: 100)))
        controller.canvas = PageCanvasView()
        XCTAssertTrue(canvas.panGestureRecognizer.isEnabled)
    }

    /// The lasso tool stands the canvas's inking down and hands it back;
    /// a new canvas (a page turn) drops the selection.
    @MainActor
    func testController_activityAndCanvasChanges() {
        let (canvas, controller) = canvas(with: [line(from: 10, to: 90, y: 50)])
        XCTAssertFalse(canvas.drawingGestureRecognizer.isEnabled, "the Pencil draws a loop, not ink")
        controller.select(lasso: rect(CGRect(x: 0, y: 0, width: 100, height: 100)))
        XCTAssertTrue(controller.hasSelection)

        controller.isActive = false
        XCTAssertTrue(canvas.drawingGestureRecognizer.isEnabled)
        XCTAssertFalse(controller.hasSelection, "switching tools lets go")

        controller.isActive = true
        controller.select(lasso: rect(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let next = PageCanvasView()
        controller.canvas = next
        XCTAssertTrue(canvas.drawingGestureRecognizer.isEnabled, "the old canvas inks again")
        XCTAssertFalse(next.drawingGestureRecognizer.isEnabled)
        XCTAssertFalse(controller.hasSelection, "a selection never outlives its page")
    }

    // MARK: - What PencilKit does with a scale

    /// Pins the framework behaviour the resize relies on: a scale in
    /// `PKStroke.transform` scales the ink's *width* along with its path,
    /// so a doubled selection reads as the same handwriting drawn twice as
    /// big, not as a hairline outline of it. Measured, not assumed: if
    /// PencilKit ever only moved the geometry, the inked area would grow
    /// about 2x here rather than about 4x.
    func testScaleTransform_scalesInkWidthToo() throws {
        let stroke = line(from: 40, to: 140, y: 100, width: 8)
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
        let single = try inkArea(PKDrawing(strokes: [stroke]), in: bounds)
        let doubled = InkSelection.transforming(PKDrawing(strokes: [stroke]), indices: [0],
                                                by: InkSelection.transform(scale: 2, about: CGPoint(x: 90, y: 100)))
        let area = try inkArea(doubled, in: bounds)
        XCTAssertGreaterThan(single, 200, "the probe stroke has to be visible for the ratio to mean anything")
        let ratio = Double(area) / Double(single)
        XCTAssertGreaterThan(ratio, 3.2, "width did not scale with the geometry (ratio \(ratio))")
    }
}
