import XCTest
import SwiftData
import PencilKit
@testable import Mystnotes

/// Rotate Page: the page turns a quarter, and what's on it turns with it.
final class PageRotationTests: XCTestCase {

    private static let schema = Schema([
        Folder.self, Notebook.self, Page.self, TypedTextBlock.self,
        ImportedDocument.self, Link.self, Sticker.self
    ])

    func testQuarterTurn_mapsThePagesCornersOntoTheTurnedPagesCorners() {
        let aspect: CGFloat = 0.75
        let (width, height) = (PageGeometry.nominalHeight * aspect, PageGeometry.nominalHeight)
        let newWidth = height / aspect
        func check(_ point: CGPoint, _ expected: CGPoint, clockwise: Bool) {
            let mapped = point.applying(PageRotation.quarterTurn(aspect: aspect, clockwise: clockwise).transform)
            XCTAssertEqual(mapped.x, expected.x, accuracy: 0.001, "\(point) clockwise \(clockwise)")
            XCTAssertEqual(mapped.y, expected.y, accuracy: 0.001, "\(point) clockwise \(clockwise)")
        }
        // Clockwise: top-left goes to top-right.
        check(.zero, CGPoint(x: newWidth, y: 0), clockwise: true)
        check(CGPoint(x: width, y: 0), CGPoint(x: newWidth, y: height), clockwise: true)
        check(CGPoint(x: width, y: height), CGPoint(x: 0, y: height), clockwise: true)
        check(CGPoint(x: 0, y: height), .zero, clockwise: true)
        // Counter-clockwise: top-left goes to bottom-left.
        check(.zero, CGPoint(x: 0, y: height), clockwise: false)
        check(CGPoint(x: width, y: 0), .zero, clockwise: false)
    }

    private func strokePoints(_ drawing: PKDrawing) -> [CGPoint] {
        drawing.strokes.flatMap { stroke in stroke.path.map { $0.location.applying(stroke.transform) } }
    }

    /// Four clockwise turns, and a clockwise turn undone by a
    /// counter-clockwise one, both put everything back where it was.
    @MainActor
    func testTurningAllTheWayRound_putsEverythingBack() throws {
        let container = try ModelContainer(for: Self.schema,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let page = Page(index: 0)
        page.aspectRatio = 0.75
        context.insert(page)
        let paper = ImportedDocument(sourceType: "pdf", fileRef: "scan.pdf", pdfPageIndex: 0, page: page)
        (paper.frameX, paper.frameY, paper.frameWidth, paper.frameHeight) = (0, 0, 1, 1)
        let photo = ImportedDocument(sourceType: "image", fileRef: "p.png", pdfPageIndex: 0, page: page)
        (photo.frameX, photo.frameY, photo.frameWidth, photo.frameHeight) = (0.1, 0.2, 0.3, 0.2)
        let block = TypedTextBlock(content: "hi", page: page)
        (block.frameX, block.frameY) = (100, 150)
        let link = Link(sourcePageID: page.id, destinationPageID: UUID())
        (link.anchorX, link.anchorY) = (300, 700)
        [paper, photo].forEach(context.insert)
        context.insert(block); context.insert(link)
        page.textBlocks = [block]

        let point = { (x: CGFloat, y: CGFloat) in
            PKStrokePoint(location: CGPoint(x: x, y: y), timeOffset: 0, size: CGSize(width: 3, height: 3),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let original = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black),
            path: PKStrokePath(controlPoints: [point(50, 60), point(400, 900)], creationDate: Date()))])

        let before = (aspect: page.aspectRatio, paper: ArtworkSnapshot(paper), photo: ArtworkSnapshot(photo),
                      block: CGPoint(x: block.frameX, y: block.frameY), link: CGPoint(x: link.anchorX, y: link.anchorY),
                      ink: strokePoints(original))

        func assertBack(_ drawing: PKDrawing, _ label: String) {
            XCTAssertEqual(page.aspectRatio ?? 0, before.aspect ?? 0, accuracy: 1e-9, label)
            XCTAssertEqual((paper.rotationDegrees ?? 0).truncatingRemainder(dividingBy: 360), 0, label)
            XCTAssertEqual(photo.frameX ?? 0, before.photo.frameX ?? 0, accuracy: 1e-9, label)
            XCTAssertEqual(photo.frameY ?? 0, before.photo.frameY ?? 0, accuracy: 1e-9, label)
            XCTAssertEqual(block.frameX, before.block.x, accuracy: 1e-6, label)
            XCTAssertEqual(block.frameY, before.block.y, accuracy: 1e-6, label)
            XCTAssertEqual(link.anchorX, before.link.x, accuracy: 1e-6, label)
            XCTAssertEqual(link.anchorY, before.link.y, accuracy: 1e-6, label)
            for (a, b) in zip(strokePoints(drawing), before.ink) {
                XCTAssertEqual(a.x, b.x, accuracy: 1e-6, label)
                XCTAssertEqual(a.y, b.y, accuracy: 1e-6, label)
            }
        }

        var drawing = original
        for turn in 1...4 {
            drawing = PageRotation.rotate(page, clockwise: true, documents: [paper, photo], links: [link], drawing: drawing)
            if turn == 1 {
                XCTAssertEqual(page.aspectRatio ?? 0, 1 / 0.75, accuracy: 1e-9, "the page takes the turned shape")
                XCTAssertEqual(paper.rotationDegrees, 90)
            }
        }
        assertBack(drawing, "four turns")

        drawing = PageRotation.rotate(page, clockwise: true, documents: [paper, photo], links: [link], drawing: drawing)
        drawing = PageRotation.rotate(page, clockwise: false, documents: [paper, photo], links: [link], drawing: drawing)
        assertBack(drawing, "turn and undo")
        XCTAssertEqual(drawing.strokes.first?.path.creationDate, original.strokes.first?.path.creationDate,
                       "a stroke's creation date is half its id")
    }
}
