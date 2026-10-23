import XCTest
@testable import Mystnotes

/// New text boxes and stickers land where the user is looking, and a text
/// box deleted with its button comes back whole on undo.
final class PageElementPlacementTests: XCTestCase {
    func testNewElement_goesInTheMiddleOfTheView_onThePage() {
        let origin = NotebookDetailView.elementOrigin(centeredOn: CGPoint(x: 400, y: 900), size: CGSize(width: 200, height: 44),
                                                      pageSize: CGSize(width: 612, height: 792), taken: [])
        XCTAssertEqual(origin, CGPoint(x: 300, y: 748), "centred across, and kept on the page at the bottom")
    }

    func testSecondElement_doesNotLandOnTheFirst() {
        let first = NotebookDetailView.elementOrigin(centeredOn: CGPoint(x: 300, y: 300), size: CGSize(width: 60, height: 60),
                                                     pageSize: CGSize(width: 612, height: 792), taken: [])
        let second = NotebookDetailView.elementOrigin(centeredOn: CGPoint(x: 300, y: 300), size: CGSize(width: 60, height: 60),
                                                      pageSize: CGSize(width: 612, height: 792), taken: [first])
        XCTAssertEqual(second, CGPoint(x: first.x + 24, y: first.y + 24))
    }

    @MainActor
    func testSnapshot_keepsTheBoxsFormattingAndMentions() {
        let block = TypedTextBlock(content: "Exam on Friday")
        (block.fontSize, block.textColorHex, block.fontDesign, block.isBold, block.isItalic) = (24, "#FF0000", "serif", true, true)
        let mention = UUID()
        let snapshot = TextBlockSnapshot(of: block, mentions: [mention])
        XCTAssertEqual(snapshot.content, "Exam on Friday")
        XCTAssertEqual(snapshot.fontSize, 24)
        XCTAssertEqual(snapshot.textColorHex, "#FF0000")
        XCTAssertEqual(snapshot.fontDesign, "serif")
        XCTAssertTrue(snapshot.isBold && snapshot.isItalic)
        XCTAssertEqual(snapshot.mentions, [mention])
    }
}
