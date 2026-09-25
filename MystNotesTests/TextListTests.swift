import XCTest
@testable import Mystnotes

/// Bullets and checklists in text boxes, kept in the text itself.
final class TextListTests: XCTestCase {

    func testToggling_addsThePrefixToEveryLine_andTakesItAwayAgain() {
        let bulleted = TextList.toggle(.bullets, in: "milk\neggs\n\nbread")
        XCTAssertEqual(bulleted, "• milk\n• eggs\n\n• bread", "blank lines stay blank")
        XCTAssertEqual(TextList.toggle(.bullets, in: bulleted), "milk\neggs\n\nbread")
        XCTAssertEqual(TextList.toggle(.checklist, in: bulleted), "☐ milk\n☐ eggs\n\n☐ bread", "one list style replaces the other")
    }

    func testReturn_continuesTheList_andAnEmptyItemEndsIt() {
        XCTAssertEqual(TextList.continuing(from: "• milk", to: "• milk\n"), "• milk\n• ")
        XCTAssertEqual(TextList.continuing(from: "☑ milk", to: "☑ milk\n"), "☑ milk\n☐ ", "a new item starts unticked")
        XCTAssertEqual(TextList.continuing(from: "• milk\n• ", to: "• milk\n• \n"), "• milk\n", "return on an empty item ends the list")
        XCTAssertNil(TextList.continuing(from: "milk", to: "milk\n"), "plain text is left alone")
        XCTAssertNil(TextList.continuing(from: "• milk", to: "• milks"), "not a return")
    }

    func testChecking_theItemAtAnOffset() {
        let text = "☐ milk\n☐ eggs"
        let secondLine = text.distance(from: text.startIndex, to: text.range(of: "eggs")!.lowerBound)
        XCTAssertEqual(TextList.toggleCheck(atOffset: secondLine, in: text), "☐ milk\n☑ eggs")
        XCTAssertEqual(TextList.toggleCheck(atOffset: secondLine, in: "☐ milk\n☑ eggs"), "☐ milk\n☐ eggs")
        XCTAssertEqual(TextList.toggleCheck(atOffset: 0, in: "plain"), "plain")
    }

    func testMarkdownExport_writesRealLists() {
        XCTAssertEqual(LibraryExport.markdownLists("• milk\n☐ eggs\n☑ bread\nplain"),
                       "- milk\n- [ ] eggs\n- [x] bread\nplain")
    }
}
