import XCTest
import SwiftData
@testable import Mystnotes

/// M2 task 5: the kind filter rule and the `Links` helpers.
@MainActor
final class LinksTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Folder.self, Notebook.self, Page.self, TypedTextBlock.self, Sticker.self, ImportedDocument.self, Link.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func makePage(_ context: ModelContext, index: Int = 0) -> Page {
        let page = Page(index: index)
        context.insert(page)
        return page
    }

    func testRemoveUnfinished_keepsANodeSelfLink() throws {
        let context = try makeContext()
        let page = makePage(context)
        let node = Links.makeNode(on: page, strokeIDs: ["A"], title: "N", anchor: .init(x: 0, y: 0, width: 10, height: 10), in: context)
        let unfinished = Link(sourcePageID: page.id, destinationPageID: page.id)
        let picked = Link(sourcePageID: page.id, destinationPageID: UUID())
        let toNode = Link(sourcePageID: page.id, destinationPageID: page.id)
        toNode.destinationKind = "region"
        toNode.destinationID = node.id.uuidString
        let mention = Link(sourcePageID: page.id, destinationPageID: page.id)
        mention.kind = "mention"

        XCTAssertFalse(Links.isUnfinished(node))
        XCTAssertTrue(Links.isUnfinished(unfinished))
        XCTAssertFalse(Links.isUnfinished(picked))
        XCTAssertFalse(Links.isUnfinished(toNode))
        XCTAssertFalse(Links.isUnfinished(mention))
    }

    func testPageElements_hasNoAnchorForANode() throws {
        let context = try makeContext()
        let page = makePage(context)
        let other = makePage(context, index: 1)
        Links.makeNode(on: page, strokeIDs: ["A"], title: "N", anchor: .init(x: 0, y: 0, width: 10, height: 10), in: context)
        let plain = Link(sourcePageID: page.id, destinationPageID: other.id)
        context.insert(plain)
        let transclusion = Link(sourcePageID: page.id, destinationPageID: other.id)
        transclusion.kind = "transclusion"
        context.insert(transclusion)
        try context.save()

        let elements = PageElements(page: page)
        XCTAssertEqual(elements.links.count, 1, "only kind == nil draws a plain anchor")
        XCTAssertEqual(elements.links.first?.destinationPageID, other.id)
    }

    func testNodeTitle_neverEmpty_andTruncates() {
        XCTAssertEqual(Links.nodeTitle(recognized: nil, pageNumber: 3), "Node, p. 3")
        XCTAssertEqual(Links.nodeTitle(recognized: "  \n \n", pageNumber: 4), "Node, p. 4")
        XCTAssertEqual(Links.nodeTitle(recognized: "\n  Chain rule  \nsecond", pageNumber: 1), "Chain rule")
        let long = String(repeating: "x", count: 100)
        XCTAssertEqual(Links.nodeTitle(recognized: long, pageNumber: 1).count, 60)
    }

    func testSetTitle_rejectsEmpty_andMarksThePage() throws {
        let context = try makeContext()
        let page = makePage(context)
        let node = Links.makeNode(on: page, strokeIDs: [], title: "Keep", anchor: .zero, in: context,
                                  now: Date(timeIntervalSince1970: 100))
        XCTAssertFalse(Links.setTitle(node, "  \n", in: context))
        XCTAssertEqual(node.title, "Keep")
        XCTAssertTrue(Links.setTitle(node, " Renamed ", in: context, now: Date(timeIntervalSince1970: 200)))
        XCTAssertEqual(node.title, "Renamed")
        XCTAssertEqual(page.modifiedAt, Date(timeIntervalSince1970: 200))
    }

    func testMakeNode_blankTitleFallsBack_andSetDestinationToNode() throws {
        let context = try makeContext()
        let a = makePage(context), b = makePage(context, index: 1)
        let node = Links.makeNode(on: b, strokeIDs: ["S"], title: "  ", anchor: .zero, in: context)
        XCTAssertEqual(node.title, "Node, p. 2")
        XCTAssertTrue(Links.isNode(node))
        let link = Link(sourcePageID: a.id, destinationPageID: a.id)
        context.insert(link)
        Links.setDestination(link, toNode: node, in: context, now: Date(timeIntervalSince1970: 300))
        XCTAssertEqual(link.destinationPageID, b.id)
        XCTAssertEqual(link.destinationID, node.id.uuidString)
        XCTAssertEqual(link.destinationKind, "region")
        XCTAssertTrue(Links.isPlainLink(link))
        XCTAssertEqual(a.modifiedAt, Date(timeIntervalSince1970: 300))
    }
}
