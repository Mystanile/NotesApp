import XCTest
import SwiftData
import UIKit
@testable import Mystnotes

/// Tape and Review (M4 seed): the scheduler's maths, the due queue, the model
/// helpers, what a tape does and does not draw, and the strip thumbnail's
/// transclusion list. Sync is in `TapeSyncTests`.
@MainActor
final class TapeReviewTests: XCTestCase {
    private static var container: ModelContainer?

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Folder.self, Notebook.self, Page.self, TypedTextBlock.self, Sticker.self, ImportedDocument.self, Link.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        Self.container = container
        return container.mainContext
    }

    private func notebook(_ title: String, pages count: Int, in context: ModelContext) -> (Notebook, [Page]) {
        let book = Notebook(title: title)
        context.insert(book)
        var pages: [Page] = []
        for index in 0..<count {
            let page = Page(index: index, notebook: book)
            context.insert(page)
            pages.append(page)
        }
        book.pages = pages
        return (book, pages)
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let anchor = CGRect(x: 10, y: 20, width: 120, height: 40)

    // MARK: Scheduler

    func testAgain_dueInTenMinutes_countsALapse_dropsEase() {
        let s = ReviewScheduler.next(state: nil, grade: .again, now: t0)
        XCTAssertEqual(s.interval, 0)
        XCTAssertEqual(s.due, t0.addingTimeInterval(600))
        XCTAssertEqual(s.lapses, 1)
        XCTAssertEqual(s.reps, 0)
        XCTAssertEqual(s.ease, 2.3, accuracy: 1e-9)
    }

    func testEase_neverFallsBelowItsFloor() {
        var s = ReviewScheduler.State(due: t0, interval: 5, ease: 1.4, reps: 4, lapses: 0)
        s = ReviewScheduler.next(state: s, grade: .again, now: t0)
        XCTAssertEqual(s.ease, 1.3, accuracy: 1e-9)
        s = ReviewScheduler.next(state: s, grade: .hard, now: t0)
        XCTAssertEqual(s.ease, 1.3, accuracy: 1e-9)
    }

    func testHard_growsByOnePointTwo_atLeastADay_andLowersEase() {
        let from = ReviewScheduler.State(due: t0, interval: 10, ease: 2.5, reps: 3, lapses: 0)
        let s = ReviewScheduler.next(state: from, grade: .hard, now: t0)
        XCTAssertEqual(s.interval, 12, accuracy: 1e-9)
        XCTAssertEqual(s.ease, 2.35, accuracy: 1e-9)
        XCTAssertEqual(s.due, t0.addingTimeInterval(12 * 86_400))
        XCTAssertEqual(s.reps, 4)
        XCTAssertEqual(ReviewScheduler.next(state: nil, grade: .hard, now: t0).interval, 1, "a floor of one day")
    }

    func testGood_isOneDay_thenThree_thenIntervalTimesEase() {
        let first = ReviewScheduler.next(state: nil, grade: .good, now: t0)
        XCTAssertEqual(first.interval, 1)
        XCTAssertEqual(first.reps, 1)
        XCTAssertEqual(first.due, t0.addingTimeInterval(86_400))
        let second = ReviewScheduler.next(state: first, grade: .good, now: t0)
        XCTAssertEqual(second.interval, 3)
        let third = ReviewScheduler.next(state: second, grade: .good, now: t0)
        XCTAssertEqual(third.interval, 7.5, accuracy: 1e-9)
        XCTAssertEqual(third.ease, 2.5, accuracy: 1e-9, "Good leaves ease alone")
    }

    func testEasy_isGoodTimesOnePointThree_andRaisesEase() {
        let first = ReviewScheduler.next(state: nil, grade: .easy, now: t0)
        XCTAssertEqual(first.interval, 1.3, accuracy: 1e-9)
        XCTAssertEqual(first.ease, 2.65, accuracy: 1e-9)
        let from = ReviewScheduler.State(due: t0, interval: 3, ease: 2.5, reps: 2, lapses: 1)
        XCTAssertEqual(ReviewScheduler.next(state: from, grade: .easy, now: t0).interval, 9.75, accuracy: 1e-9)
    }

    func testAfterALapse_goodStartsAgainAtOneDay() {
        let lapsed = ReviewScheduler.next(state: ReviewScheduler.State(due: t0, interval: 20, ease: 2.5, reps: 6, lapses: 0),
                                          grade: .again, now: t0)
        XCTAssertEqual(ReviewScheduler.next(state: lapsed, grade: .good, now: t0).interval, 1)
    }

    func testReviewState_roundTripsThroughItsJSON() throws {
        let s = ReviewScheduler.State(due: t0.addingTimeInterval(0.25), interval: 7.5, ease: 2.35, reps: 3, lapses: 2)
        let json = ReviewScheduler.encode(s)
        let back = try XCTUnwrap(ReviewScheduler.decode(json))
        XCTAssertEqual(back.due.timeIntervalSince1970, s.due.timeIntervalSince1970, accuracy: 0.001, "milliseconds survive")
        XCTAssertEqual([back.interval, back.ease], [7.5, 2.35])
        XCTAssertEqual([back.reps, back.lapses], [3, 2])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["due", "interval", "ease", "reps", "lapses"])
        XCTAssertTrue(object["due"] is String)
        XCTAssertNil(ReviewScheduler.decode(nil))
        XCTAssertNil(ReviewScheduler.decode("not json"))
        XCTAssertNil(ReviewScheduler.decode(#"{"due":"yesterday","interval":1,"ease":2,"reps":1,"lapses":0}"#))
    }

    func testIsDue_neverReviewedIsDue() {
        XCTAssertTrue(ReviewScheduler.isDue(nil, now: t0))
        let later = ReviewScheduler.State(due: t0.addingTimeInterval(1), interval: 1, ease: 2.5, reps: 1, lapses: 0)
        XCTAssertFalse(ReviewScheduler.isDue(later, now: t0))
        XCTAssertTrue(ReviewScheduler.isDue(later, now: t0.addingTimeInterval(1)))
    }

    // MARK: makeTape and the model helpers

    func testMakeTape_setsItsFields_andMarksThePage() throws {
        let context = try makeContext()
        let (book, pages) = notebook("Bio", pages: 1, in: context)
        let page = pages[0]
        let now = Date(timeIntervalSince1970: 1_800_000_500)

        let tape = Links.makeTape(on: page, strokeIDs: ["A", "B"], anchor: anchor, in: context, now: now)

        XCTAssertEqual(tape.kind, "tape")
        XCTAssertTrue(Links.isTape(tape))
        XCTAssertEqual(tape.sourcePageID, page.id)
        XCTAssertEqual(tape.destinationPageID, page.id, "a self-link")
        XCTAssertEqual(tape.destinationKind, "region")
        XCTAssertNil(tape.title)
        XCTAssertNil(tape.reviewState)
        XCTAssertEqual(tape.strokeIDs, ["A", "B"])
        XCTAssertEqual(CGRect(x: tape.anchorX, y: tape.anchorY, width: tape.anchorWidth, height: tape.anchorHeight), anchor)
        XCTAssertEqual(page.modifiedAt, now)
        XCTAssertEqual(book.modifiedAt, now, "the notebook's date is lifted")
        XCTAssertFalse(Links.isUnfinished(tape), "removeUnfinishedLinks must not take a tape")
    }

    func testSetReviewState_marksTheSourcePage_andIsTheOnlyWriter() throws {
        let context = try makeContext()
        let (_, pages) = notebook("Bio", pages: 2, in: context)
        let tape = Links.makeTape(on: pages[0], strokeIDs: ["A"], anchor: anchor, in: context, now: t0)
        let later = t0.addingTimeInterval(500)
        let state = ReviewScheduler.next(state: nil, grade: .good, now: later)

        Links.setReviewState(tape, state, in: context, now: later)

        XCTAssertEqual(ReviewScheduler.decode(tape.reviewState), state)
        XCTAssertEqual(pages[0].modifiedAt, later)
        XCTAssertNil(pages[1].modifiedAt, "only the source page")
    }

    func testRemoveTape_marksThePage_andUndoRestoresIdentityAndSchedule() throws {
        let context = try makeContext()
        let (_, pages) = notebook("Bio", pages: 1, in: context)
        let page = pages[0]
        let tape = Links.makeTape(on: page, strokeIDs: ["A"], anchor: anchor, in: context, now: t0)
        let state = ReviewScheduler.next(state: nil, grade: .good, now: t0)
        Links.setReviewState(tape, state, in: context, now: t0)

        let snapshot = Links.tapeSnapshot(of: tape)
        let before = page.modifiedAt
        NotebookDetailView.applyTape(snapshot, present: false, on: page, in: context)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Link>()).isEmpty)
        XCTAssertNotEqual(page.modifiedAt, before, "removing a tape marks its page")

        NotebookDetailView.applyTape(snapshot, present: true, on: page, in: context)
        let back = try XCTUnwrap(try context.fetch(FetchDescriptor<Link>()).first)
        XCTAssertEqual(back.id, snapshot.id)
        XCTAssertEqual(ReviewScheduler.decode(back.reviewState), state)
        XCTAssertEqual(back.strokeIDs, ["A"])

        // Redo of an already-restored tape adds nothing.
        NotebookDetailView.applyTape(snapshot, present: true, on: page, in: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Link>()).count, 1)
    }

    // MARK: The due queue

    func testDueTapes_filtersAndOrders() throws {
        let context = try makeContext()
        let (_, pages) = notebook("Bio", pages: 2, in: context)
        let now = t0.addingTimeInterval(100_000)
        func tape(_ page: Page, y: Double, due: Date?) -> Link {
            let link = Links.makeTape(on: page, strokeIDs: ["S\(y)"], anchor: CGRect(x: 0, y: y, width: 50, height: 20),
                                      in: context, now: t0)
            if let due {
                link.reviewState = ReviewScheduler.encode(.init(due: due, interval: 1, ease: 2.5, reps: 1, lapses: 0))
            }
            return link
        }
        let never = tape(pages[0], y: 300, due: nil)
        let old = tape(pages[0], y: 10, due: now.addingTimeInterval(-5000))
        let recent = tape(pages[1], y: 10, due: now.addingTimeInterval(-60))
        let exactly = tape(pages[1], y: 50, due: now)
        _ = tape(pages[0], y: 99, due: now.addingTimeInterval(60))             // not yet
        let gone = tape(pages[0], y: 120, due: nil)                               // ink erased
        Links.makeNode(on: pages[0], strokeIDs: ["N"], title: "n", anchor: anchor, in: context, now: t0)

        let links = try context.fetch(FetchDescriptor<Link>())
        let queue = Links.dueTapes(in: links, pageIDs: Set(pages.map(\.id)), now: now, excluding: [gone.id])

        XCTAssertEqual(queue.map(\.id), [never.id, old.id, recent.id, exactly.id],
                       "never reviewed first, then by due date; future, gone and non-tape left out")

        let onlyFirstPage = Links.dueTapes(in: links, pageIDs: [pages[0].id], now: now, excluding: [gone.id])
        XCTAssertEqual(onlyFirstPage.map(\.id), [never.id, old.id])
    }

    func testDueCounts_perNotebook_fromOnePass() throws {
        let context = try makeContext()
        let (a, aPages) = notebook("A", pages: 1, in: context)
        let (b, bPages) = notebook("B", pages: 1, in: context)
        _ = notebook("C", pages: 1, in: context)
        let now = t0.addingTimeInterval(1000)
        Links.makeTape(on: aPages[0], strokeIDs: ["1"], anchor: anchor, in: context, now: t0)
        Links.makeTape(on: aPages[0], strokeIDs: ["2"], anchor: anchor, in: context, now: t0)
        let future = Links.makeTape(on: bPages[0], strokeIDs: ["3"], anchor: anchor, in: context, now: t0)
        future.reviewState = ReviewScheduler.encode(.init(due: now.addingTimeInterval(9), interval: 1, ease: 2.5, reps: 1, lapses: 0))

        var byPage: [UUID: UUID] = [:]
        for book in [a, b] { for page in book.pages ?? [] { byPage[page.id] = book.id } }
        let counts = Links.dueCounts(links: try context.fetch(FetchDescriptor<Link>()), notebookByPage: byPage, now: now)

        XCTAssertEqual(counts[a.id], 2)
        XCTAssertNil(counts[b.id], "nothing due is no badge")
    }

    // MARK: Exports

    func testTape_isNotInExportElements_orThePageThumbnailRequest() throws {
        let context = try makeContext()
        let (_, pages) = notebook("Bio", pages: 1, in: context)
        let page = pages[0]
        let plain = Link(sourcePageID: page.id, destinationPageID: UUID())
        context.insert(plain)
        Links.makeTape(on: page, strokeIDs: ["A"], anchor: anchor, in: context, now: t0)

        let elements = PageElements(page: page)

        XCTAssertEqual(elements.links.count, 1, "the plain anchor only")
        XCTAssertTrue(elements.transclusions.isEmpty)
        let withTape = PageThumbnailView(page: page).thumbnailRequest
        for link in try context.fetch(FetchDescriptor<Link>()) where Links.isTape(link) { context.delete(link) }
        XCTAssertEqual(PageThumbnailView(page: page).thumbnailRequest.elements, withTape.elements,
                       "a tape changes nothing a thumbnail draws")
    }

    // MARK: Review card geometry

    func testReviewRegion_isTheTapePlusContext_keptOnThePage() {
        let item = ReviewItem(linkID: UUID(), pageID: UUID(), pageNumber: 1,
                              anchor: CGRect(x: 10, y: 20, width: 100, height: 50), pageSize: CGSize(width: 600, height: 800))
        XCTAssertEqual(ReviewRegion.rect(for: item), CGRect(x: 0, y: 0, width: 150, height: 110))
        var inside = item
        inside.anchor = CGRect(x: 200, y: 300, width: 100, height: 50)
        XCTAssertEqual(ReviewRegion.rect(for: inside), CGRect(x: 160, y: 260, width: 180, height: 130))
    }

    // MARK: The strip's thumbnails

    func testStripTransclusions_areBuiltOnceFromTheParent_forHostPagesOnly() throws {
        let context = try makeContext()
        let (source, sourcePages) = notebook("Source", pages: 1, in: context)
        let (hostBook, hostPages) = notebook("Host", pages: 3, in: context)
        let node = Links.makeNode(on: sourcePages[0], strokeIDs: ["B", "A"], title: "Chain rule", anchor: anchor,
                                  in: context, now: t0)
        let frame = CGRect(x: 40, y: 50, width: 200, height: 100)
        Links.addTransclusion(of: node, onto: hostPages[1], frame: frame, in: context, now: t0)
        Links.makeTape(on: hostPages[2], strokeIDs: ["Z"], anchor: anchor, in: context, now: t0)
        let links = try context.fetch(FetchDescriptor<Link>())

        let byPage = NotebookDetailView.thumbnailTransclusions(hosts: hostPages, links: links, notebooks: [source, hostBook])

        XCTAssertEqual(Set(byPage.keys), [hostPages[1].id], "only a page that hosts one; a tape is not one")
        let resolved = try XCTUnwrap(byPage[hostPages[1].id])
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[0].frame, frame)
        XCTAssertEqual(resolved[0].ownerPageID, sourcePages[0].id)
        XCTAssertEqual(resolved[0].strokeIDs, ["A", "B"])
        XCTAssertEqual(resolved[0].title, "Chain rule")
        XCTAssertEqual(resolved[0].ownerStamp, PageElements.ownerStamp(of: sourcePages[0]))

        // And it reaches the cell's request: editing the owner changes the key.
        let before = PageThumbnailView(page: hostPages[1], transclusions: resolved).thumbnailRequest
        XCTAssertNotEqual(before, PageThumbnailView(page: hostPages[1]).thumbnailRequest)
        sourcePages[0].markModified(at: t0.addingTimeInterval(900))
        let rebuilt = NotebookDetailView.thumbnailTransclusions(hosts: hostPages, links: links, notebooks: [source, hostBook])
        XCTAssertNotEqual(before, PageThumbnailView(page: hostPages[1], transclusions: rebuilt[hostPages[1].id] ?? []).thumbnailRequest)
    }

    func testStripTransclusions_nothingHosted_isEmpty() throws {
        let context = try makeContext()
        let (book, pages) = notebook("Plain", pages: 2, in: context)
        XCTAssertTrue(NotebookDetailView.thumbnailTransclusions(hosts: pages, links: [], notebooks: [book]).isEmpty)
    }
}
