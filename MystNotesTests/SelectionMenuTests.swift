import XCTest
import PencilKit
@testable import Mystnotes

/// The lasso's edit menu (Nov 2, 2026), which replaced the floating
/// toolbar. The menu itself is UIKit's and needs a screen; what is pinned
/// here is what it offers, and the controller calls behind its items.
///
/// Cannot show without the iPad: the menu appearing at the selection after
/// a loop and after a drag, the "..." button, right-click on a Mac, and the
/// keyboard shortcuts.
final class SelectionMenuTests: XCTestCase {

    // MARK: Contents

    func testMenu_withASelection_offersTheStandardActionsThenTheCustomOnes() {
        XCTAssertEqual(SelectionMenu.items(hasSelection: true, pasteboardHasInk: true, isPaged: true),
                       [.cut, .copy, .paste, .duplicate, .delete, .colour, .copyAsImage, .convertToText, .linkTo, .makeNode])
    }

    func testMenu_leavesPasteOut_whenThePasteboardHasNoInk() {
        let items = SelectionMenu.items(hasSelection: true, pasteboardHasInk: false, isPaged: true)
        XCTAssertFalse(items.contains(.paste))
        XCTAssertTrue(items.contains(.cut) && items.contains(.copy) && items.contains(.duplicate) && items.contains(.delete))
    }

    func testMenu_onTheWhiteboard_hasNoLinkOrNode() {
        let items = SelectionMenu.items(hasSelection: true, pasteboardHasInk: true, isPaged: false)
        XCTAssertFalse(items.contains(.linkTo))
        XCTAssertFalse(items.contains(.makeNode))
        XCTAssertTrue(items.contains(.colour))
    }

    func testMenu_withoutASelection_isPasteAlone_orNothing() {
        XCTAssertEqual(SelectionMenu.items(hasSelection: false, pasteboardHasInk: true, isPaged: true), [.paste])
        XCTAssertEqual(SelectionMenu.items(hasSelection: false, pasteboardHasInk: false, isPaged: true), [])
    }

    func testMenu_tapeAppearsOnlyOnceItIsWiredUp() {
        XCTAssertFalse(SelectionMenu.items(hasSelection: true, pasteboardHasInk: false, isPaged: true).contains(.tape))
        XCTAssertEqual(SelectionMenu.items(hasSelection: true, pasteboardHasInk: false, isPaged: true, hasTape: true).last, .tape)
    }

    func testEveryItem_hasATitleAndAnImage() {
        for item in SelectionMenu.items(hasSelection: true, pasteboardHasInk: true, isPaged: true, hasTape: true) {
            XCTAssertFalse(item.title.isEmpty)
            XCTAssertNotNil(UIImage(systemName: item.systemImage), "\(item) has no such SF Symbol: \(item.systemImage)")
        }
    }

    // MARK: Controller calls behind the items

    private func line(y: CGFloat, index: Int, color: UIColor = .black) -> PKStroke {
        let points = stride(from: CGFloat(0), through: 100, by: 5).map { x in
            PKStrokePoint(location: CGPoint(x: x, y: y), timeOffset: TimeInterval(x) * 0.01,
                          size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let path = PKStrokePath(controlPoints: points,
                                creationDate: Date(timeIntervalSinceReferenceDate: 730_000_000 + Double(index)))
        return PKStroke(ink: PKInk(.pen, color: color), path: path, randomSeed: UInt32(7_000 + index))
    }

    /// Three lines at y 20, 60, 100; the first two are inside the loop.
    private func selected() -> (PKCanvasView, InkSelectionController) {
        let canvas = PKCanvasView()
        canvas.drawing = PKDrawing(strokes: [line(y: 20, index: 0), line(y: 60, index: 1), line(y: 100, index: 2)])
        let selection = InkSelectionController()
        selection.canvas = canvas
        selection.isActive = true
        selection.select(lasso: InkSelection.corners(of: CGRect(x: -10, y: 0, width: 130, height: 80)))
        return (canvas, selection)
    }

    func testCopyThenPaste_roundTripsTheInk_asNewSelectedStrokes() throws {
        UIPasteboard.general.items = []
        defer { UIPasteboard.general.items = [] }
        let (canvas, selection) = selected()
        XCTAssertEqual(selection.selectedStrokes?.strokes.count, 2)
        XCTAssertFalse(InkSelectionController.pasteboardHasInk)

        selection.copySelection()
        XCTAssertTrue(InkSelectionController.pasteboardHasInk)
        XCTAssertEqual(canvas.drawing.strokes.count, 3, "copy leaves the page alone")

        selection.paste()
        XCTAssertEqual(canvas.drawing.strokes.count, 5)
        let originals = Set(canvas.drawing.strokes.prefix(3).map { StrokeIDMap.Fingerprint($0) })
        let pasted = canvas.drawing.strokes.suffix(2).map { StrokeIDMap.Fingerprint($0) }
        XCTAssertTrue(pasted.allSatisfy { !originals.contains($0) }, "a paste gets identities of its own (invariant 6)")
        XCTAssertEqual(selection.selectedStrokes?.strokes.count, 2, "the paste is what's selected")
        XCTAssertEqual(canvas.drawing.strokes[3].path.count, canvas.drawing.strokes[0].path.count)
    }

    func testCut_copiesThenRemoves_andPasteBringsItBack() {
        UIPasteboard.general.items = []
        defer { UIPasteboard.general.items = [] }
        let (canvas, selection) = selected()
        selection.cutSelection()
        XCTAssertEqual(canvas.drawing.strokes.count, 1)
        XCTAssertFalse(selection.hasSelection)
        XCTAssertTrue(InkSelectionController.pasteboardHasInk, "what was cut is on the pasteboard")
        selection.paste()
        XCTAssertEqual(canvas.drawing.strokes.count, 3)
    }

    func testRecolour_changesOnlySelectedStrokes_andKeepsTheRestIdentical() throws {
        let (canvas, selection) = selected()
        let before = canvas.drawing.strokes
        selection.recolor(.red)
        let after = canvas.drawing.strokes
        XCTAssertEqual(after.count, before.count)

        func rgb(_ stroke: PKStroke) -> [Int] {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            stroke.ink.color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return [r, g, b].map { Int(($0 * 255).rounded()) }
        }
        XCTAssertEqual(rgb(after[0]), [255, 0, 0])
        XCTAssertEqual(rgb(after[1]), [255, 0, 0])
        XCTAssertEqual(rgb(after[2]), [0, 0, 0], "the stroke outside the loop keeps its colour")
        // Everything but the ink is identical: path, transform, seed, mask.
        for index in before.indices {
            XCTAssertEqual(StrokeIDMap.Fingerprint(after[index]), StrokeIDMap.Fingerprint(before[index]))
            XCTAssertEqual(after[index].transform, before[index].transform)
            XCTAssertEqual(after[index].randomSeed, before[index].randomSeed)
            XCTAssertEqual(after[index].path.count, before[index].path.count)
            XCTAssertEqual(after[index].ink.inkType, before[index].ink.inkType)
        }
        XCTAssertEqual(selection.selectedStrokes?.strokes.count, 2, "the selection survives a recolour")
        XCTAssertNotNil(selection.display.corners)
    }

    func testRecolour_toTheColourAlreadyThere_changesNothing() {
        let drawing = PKDrawing(strokes: [line(y: 20, index: 0, color: .red)])
        XCTAssertNil(InkSelection.recoloringIfChanged(drawing, indices: [0], to: .red))
    }
}
