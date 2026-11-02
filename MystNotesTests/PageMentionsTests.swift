import XCTest
import SwiftData
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

    // MARK: labels(in:)

    func testLabels_readsEveryClosedToken() {
        XCTAssertEqual(PageMentions.labels(in: "a [[p. 2 · Limits]] b [[ Other · p. 1 ]]"), ["p. 2 · Limits", "Other · p. 1"])
        XCTAssertEqual(PageMentions.labels(in: "[[a]] [[a]]"), ["a"])
        XCTAssertTrue(PageMentions.labels(in: "open [[ not closed").isEmpty)
        XCTAssertTrue(PageMentions.labels(in: "[[ ]] empty").isEmpty)
        XCTAssertTrue(PageMentions.hasTokens(in: "[[ ]]"))
        XCTAssertFalse(PageMentions.hasTokens(in: "plain"))
    }

    // MARK: pruneMentions

    private func makeContext() throws -> (ModelContainer, ModelContext) {
        let container = try ModelContainer(
            for: Folder.self, Notebook.self, Page.self, TypedTextBlock.self, Sticker.self, ImportedDocument.self, Link.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return (container, ModelContext(container))
    }

    private func mention(from page: Page, to dest: UUID, block: UUID, title: String?, in context: ModelContext) -> Link {
        let link = Link(sourcePageID: page.id, destinationPageID: dest)
        link.kind = "mention"
        link.destinationID = block.uuidString
        link.title = title
        context.insert(link)
        return link
    }

    @MainActor
    func testPrune_droppingOneOfTwoTokensLeavesExactlyOneLinkAndBumpsModifiedAt() throws {
        let (container, context) = try makeContext()
        _ = container
        let page = Page(index: 0)
        context.insert(page)
        let block = UUID()
        _ = mention(from: page, to: UUID(), block: block, title: "p. 2 · A", in: context)
        _ = mention(from: page, to: UUID(), block: block, title: "p. 3 · B", in: context)
        let other = mention(from: page, to: UUID(), block: UUID(), title: "p. 9", in: context)
        let when = Date(timeIntervalSince1970: 5_000)

        let removed = Links.pruneMentions(forBlock: block, text: "see [[p. 2 · A]] only", on: page, in: context, now: when)

        XCTAssertEqual(removed, 1)
        let left = try context.fetch(FetchDescriptor<Link>())
        XCTAssertEqual(left.filter { $0.destinationID == block.uuidString }.map(\.title), ["p. 2 · A"])
        XCTAssertTrue(left.contains { $0.id == other.id }, "another box's mention is untouched")
        XCTAssertEqual(page.modifiedAt, when)
    }

    @MainActor
    func testPrune_nothingToDrop_doesNotTouchThePage() throws {
        let (container, context) = try makeContext()
        _ = container
        let page = Page(index: 0)
        context.insert(page)
        let block = UUID()
        _ = mention(from: page, to: UUID(), block: block, title: "X", in: context)
        XCTAssertEqual(Links.pruneMentions(forBlock: block, text: "[[X]] renamed elsewhere", on: page, in: context), 0)
        XCTAssertNil(page.modifiedAt)
    }

    @MainActor
    func testPrune_renamingTheDestinationPageDropsNothing() throws {
        let (container, context) = try makeContext()
        _ = container
        let page = Page(index: 0), dest = Page(index: 1)
        context.insert(page); context.insert(dest)
        let block = UUID()
        _ = mention(from: page, to: dest.id, block: block, title: "p. 2 · Old name", in: context)
        dest.title = "New name"
        XCTAssertEqual(Links.pruneMentions(forBlock: block, text: "[[p. 2 · Old name]]", on: page, in: context), 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Link>()).count, 1)
    }

    @MainActor
    func testPrune_legacyNilTitle_goesOnlyWhenTheTextHasNoTokens() throws {
        let (container, context) = try makeContext()
        _ = container
        let page = Page(index: 0)
        context.insert(page)
        let block = UUID()
        _ = mention(from: page, to: UUID(), block: block, title: nil, in: context)
        XCTAssertEqual(Links.pruneMentions(forBlock: block, text: "still has [[something]]", on: page, in: context), 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Link>()).count, 1)
        XCTAssertEqual(Links.pruneMentions(forBlock: block, text: "no tokens now", on: page, in: context), 1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Link>()).isEmpty)
    }

    // MARK: suggestions

    @MainActor
    func testSuggestions_sameNotebookFirst_prefixBeforeContains_otherNotebooksLabelled_max6() {
        let here = Notebook(title: "Here"), there = Notebook(title: "There")
        func c(_ title: String, _ nb: Notebook, _ n: Int) -> PageMentions.Candidate {
            (UUID(), title, nb.title, nb.id, n)
        }
        let pages = [
            c("Calculus limits", there, 1),
            c("Intro to limits", here, 2),
            c("Limits", here, 5),
            c("Unrelated", here, 3),
            c("Limit laws", there, 4),
        ]
        let out = PageMentions.suggestions(query: "LIM", current: here, pages: pages)
        XCTAssertEqual(out.map(\.label), ["p. 5 · Limits", "p. 2 · Intro to limits", "There · p. 4", "There · p. 1"])

        let many = (1...10).map { c("T\($0)", here, $0) }
        XCTAssertEqual(PageMentions.suggestions(query: "", current: here, pages: many).count, 6)
        XCTAssertEqual(PageMentions.suggestions(query: "", current: here, pages: many).first?.label, "p. 1 · T1")
        XCTAssertTrue(PageMentions.suggestions(query: "zzz", current: here, pages: pages).isEmpty)
    }
}
