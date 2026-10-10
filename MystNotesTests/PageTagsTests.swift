import XCTest
@testable import Mystnotes

final class PageTagsTests: XCTestCase {
    func testNormalized_trimsDropsEmptiesAndDuplicates_keepingTheFirstSpelling_sorted() {
        XCTAssertEqual(PageTags.normalized([" Exam", "derivatives", "", "EXAM", "  "]), ["derivatives", "Exam"])
        XCTAssertEqual(PageTags.normalized(["#Exam"]), ["Exam"], "a leading # is how people type tags")
    }

    func testAllTags_countPagesPerTag_caseInsensitively() {
        let notebook = Notebook(title: "N")
        let a = Page(index: 0, notebook: notebook); a.tags = ["Exam", "Limits"]
        let b = Page(index: 1, notebook: notebook); b.tags = ["exam"]
        let c = Page(index: 2, notebook: notebook)
        let counts = PageTags.counts(in: [a, b, c])
        XCTAssertEqual(counts.map(\.name), ["Exam", "Limits"])
        XCTAssertEqual(counts.map(\.pages.count), [2, 1])
    }

    func testSetTags_marksThePageModified_onlyWhenTheyChange() {
        let page = Page(index: 0, notebook: Notebook(title: "N"))
        let t0 = Date(timeIntervalSince1970: 1000)
        page.setTags(["Exam"], at: t0)
        XCTAssertEqual(page.modifiedAt, t0)
        page.setTags([" exam "], at: t0.addingTimeInterval(60))
        XCTAssertEqual(page.modifiedAt, t0, "same tags: not an edit")
    }
}
