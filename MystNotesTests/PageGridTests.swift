import XCTest
@testable import Mystnotes

final class PageGridTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()

    func testToggleAddsAndRemoves() {
        var s = PageGridSelection()
        s.toggle(a)
        XCTAssertTrue(s.contains(a))
        s.toggle(a)
        XCTAssertTrue(s.isEmpty)
    }

    func testSelectAllAndClear() {
        var s = PageGridSelection()
        s.selectAll([a, b, c])
        XCTAssertEqual(s.count, 3)
        XCTAssertTrue(s.isAllSelected(of: [a, b, c]))
        s.clear()
        XCTAssertTrue(s.isEmpty)
        XCTAssertFalse(s.isAllSelected(of: [a, b, c]))
        XCTAssertFalse(s.isAllSelected(of: []))
    }

    func testCanDeleteKeepsAtLeastOnePage() {
        var s = PageGridSelection()
        XCTAssertFalse(s.canDelete(totalPages: 3), "nothing selected")
        s.toggle(a)
        XCTAssertTrue(s.canDelete(totalPages: 3))
        s.selectAll([a, b, c])
        XCTAssertFalse(s.canDelete(totalPages: 3), "selection == all pages")
        s.clear(); s.toggle(a)
        XCTAssertFalse(s.canDelete(totalPages: 1), "a one-page notebook keeps its page")
    }

    func testOrderedFollowsNotebookOrderAndDropsStaleIDs() {
        var s = PageGridSelection()
        s.toggle(c); s.toggle(a); s.toggle(UUID())
        XCTAssertEqual(s.ordered(in: [a, b, c]), [a, c])
    }

    func testDeleteTitlePluralizes() {
        XCTAssertEqual(PageGridSelection.deleteTitle(count: 1), "Delete 1 page?")
        XCTAssertEqual(PageGridSelection.deleteTitle(count: 4), "Delete 4 pages?")
    }
}
