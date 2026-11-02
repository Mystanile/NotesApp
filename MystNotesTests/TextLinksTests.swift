import XCTest
@testable import Mystnotes

final class TextLinksTests: XCTestCase {
    func testFindsURLWithRange() {
        let text = "see https://example.com/a now"
        let found = TextLinks.ranges(in: text)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(String(text[found[0].0]), "https://example.com/a")
        XCTAssertEqual(found[0].1.absoluteString, "https://example.com/a")
    }

    func testNoLinksInPlainText() {
        XCTAssertTrue(TextLinks.ranges(in: "just words").isEmpty)
        XCTAssertTrue(TextLinks.ranges(in: "").isEmpty)
    }

    func testSkipsMailLinks() {
        XCTAssertTrue(TextLinks.ranges(in: "write to a@b.com").isEmpty)
    }

    func testFindsMultipleInOrder() {
        let found = TextLinks.ranges(in: "http://a.com and https://b.org")
        XCTAssertEqual(found.map { $0.1.host }, ["a.com", "b.org"])
    }

    func testAttributedCarriesLinks() {
        let attributed = TextLinks.attributed("go https://example.com ok")
        XCTAssertEqual(attributed.runs.filter { $0.link != nil }.count, 1)
    }
}
