import XCTest
@testable import Mystnotes

final class PageMentionsTests: XCTestCase {
    func testPendingQuery() {
        XCTAssertEqual(PageMentions.pendingQuery(in: "see [[lim"), "lim")
        XCTAssertNil(PageMentions.pendingQuery(in: "[[a]] done"))
        XCTAssertNil(PageMentions.pendingQuery(in: "no brackets"))
        XCTAssertEqual(PageMentions.pendingQuery(in: "[["), "")
        XCTAssertEqual(PageMentions.pendingQuery(in: "[[a]] and [[b"), "b")
    }

    func testCompleting() {
        XCTAssertEqual(PageMentions.completing("see [[lim", with: "p. 2 · Limits"), "see [[p. 2 · Limits]]")
        XCTAssertEqual(PageMentions.completing("plain", with: "x"), "plain")
    }

    @MainActor
    func testMentionHasNoAnchor_butCountsAsLinkedFrom() throws {
        let notebook = Notebook(title: "N")
        let a = Page(index: 0, notebook: notebook), b = Page(index: 1, notebook: notebook)
        let mention = Link(sourcePageID: a.id, destinationPageID: b.id)
        mention.kind = "mention"
        mention.anchorWidth = 0
        mention.anchorHeight = 0
        let plain = Link(sourcePageID: a.id, destinationPageID: b.id)
        XCTAssertEqual(PageElements(page: a, links: [mention]).links.count, 0)
        XCTAssertEqual(PageElements(page: a, links: [mention, plain]).links.count, 1)
        XCTAssertEqual(LinkedFromStrip.sources(linkingTo: b.id, links: [mention], pages: [a, b]).map(\.id), [a.id])
    }
}
