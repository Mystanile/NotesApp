import XCTest
import SwiftData
@testable import Mystnotes

/// A tape's review schedule travels with its source page (`LinkDTO.reviewState`,
/// format 5) and merges per page, so two devices reviewing different tapes
/// both keep their grades. Uses the two-library harness.
@MainActor
final class TapeSyncTests: XCTestCase {
    private var harness: SyncTestHarness!

    override func setUpWithError() throws {
        harness = try SyncTestHarness()
    }

    override func tearDown() {
        harness.tearDown()
        harness = nil
    }

    private let anchor = CGRect(x: 5, y: 6, width: 100, height: 30)

    private func link(_ id: UUID, on device: SyncTestDevice) throws -> Link? {
        try device.context.fetch(FetchDescriptor<Link>()).first { $0.id == id }
    }

    private func state(_ link: Link?) -> ReviewScheduler.State? { ReviewScheduler.decode(link?.reviewState) }

    func testFormatStaysFive_andALinkWithoutReviewStateDecodes() throws {
        XCTAssertEqual(librarySnapshotFormatVersion, 5)
        let json = """
        {"id":"\(UUID().uuidString)","sourcePageID":"\(UUID().uuidString)","destinationPageID":"\(UUID().uuidString)",
         "anchorX":1,"anchorY":2,"anchorWidth":44,"anchorHeight":44,"kind":"tape"}
        """
        let dto = try JSONDecoder().decode(LinkDTO.self, from: Data(json.utf8))
        XCTAssertNil(dto.reviewState)
        XCTAssertEqual(dto.kind, "tape")
    }

    func testReviewState_andTheTape_reachTheOtherDevice() throws {
        let ipad = try harness.makeDevice("iPad")
        let mac = try harness.makeDevice("Mac")
        let notebook = try ipad.createNotebook(title: "Recall", pageCount: 1)
        let page = try XCTUnwrap(try ipad.pages(ofNotebook: notebook.id)).first!
        harness.clock.advance()
        let tape = Links.makeTape(on: page, strokeIDs: ["S1", "S2"], anchor: anchor, in: ipad.context, now: harness.clock.now)
        harness.clock.advance()
        let graded = ReviewScheduler.next(state: nil, grade: .good, now: harness.clock.now)
        Links.setReviewState(tape, graded, in: ipad.context, now: harness.clock.now)
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()

        let arrived = try XCTUnwrap(try link(tape.id, on: mac))
        XCTAssertEqual(arrived.kind, "tape")
        XCTAssertEqual(arrived.strokeIDs, ["S1", "S2"])
        XCTAssertEqual(arrived.destinationPageID, page.id)
        XCTAssertNil(arrived.title)
        XCTAssertEqual(arrived.anchorWidth, 100)
        let got = try XCTUnwrap(state(arrived))
        XCTAssertEqual(got.interval, graded.interval)
        XCTAssertEqual(got.reps, graded.reps)
        XCTAssertEqual(got.ease, graded.ease)
        XCTAssertEqual(got.due.timeIntervalSince1970, graded.due.timeIntervalSince1970, accuracy: 0.001)
    }

    /// Different pages, concurrent grades: each page's link follows its own
    /// newest edit, so both grades survive on both devices.
    func testReviewState_mergesPerLink_acrossPages() throws {
        let ipad = try harness.makeDevice("iPad")
        let mac = try harness.makeDevice("Mac")
        let notebook = try ipad.createNotebook(title: "Recall", pageCount: 2)
        let pages = try XCTUnwrap(try ipad.pages(ofNotebook: notebook.id)).sorted { $0.index < $1.index }
        harness.clock.advance()
        let tapeA = Links.makeTape(on: pages[0], strokeIDs: ["A"], anchor: anchor, in: ipad.context, now: harness.clock.now)
        let tapeB = Links.makeTape(on: pages[1], strokeIDs: ["B"], anchor: anchor, in: ipad.context, now: harness.clock.now)
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()

        harness.clock.advance()
        let iPadGrade = ReviewScheduler.next(state: nil, grade: .good, now: harness.clock.now)
        Links.setReviewState(try XCTUnwrap(try link(tapeA.id, on: ipad)), iPadGrade, in: ipad.context, now: harness.clock.now)
        harness.clock.advance()
        let macGrade = ReviewScheduler.next(state: nil, grade: .again, now: harness.clock.now)
        Links.setReviewState(try XCTUnwrap(try link(tapeB.id, on: mac)), macGrade, in: mac.context, now: harness.clock.now)

        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()
        harness.clock.advance(); try ipad.sync()

        for device in [ipad, mac] {
            XCTAssertEqual(state(try link(tapeA.id, on: device))?.reps, 1, "\(device.name): the iPad's Good on A")
            XCTAssertEqual(state(try link(tapeA.id, on: device))?.interval, iPadGrade.interval)
            XCTAssertEqual(state(try link(tapeB.id, on: device))?.lapses, 1, "\(device.name): the Mac's Again on B")
            XCTAssertEqual(state(try link(tapeB.id, on: device))?.interval, 0)
        }
    }

    /// Same page: per-page last-writer-wins, so the later grade is the one
    /// both devices end up with.
    func testReviewState_onOnePage_theLaterGradeWins() throws {
        let ipad = try harness.makeDevice("iPad")
        let mac = try harness.makeDevice("Mac")
        let notebook = try ipad.createNotebook(title: "Recall", pageCount: 1)
        let page = try XCTUnwrap(try ipad.pages(ofNotebook: notebook.id)).first!
        harness.clock.advance()
        let tape = Links.makeTape(on: page, strokeIDs: ["A"], anchor: anchor, in: ipad.context, now: harness.clock.now)
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()

        harness.clock.advance()
        Links.setReviewState(try XCTUnwrap(try link(tape.id, on: ipad)),
                             ReviewScheduler.next(state: nil, grade: .easy, now: harness.clock.now),
                             in: ipad.context, now: harness.clock.now)
        harness.clock.advance()
        Links.setReviewState(try XCTUnwrap(try link(tape.id, on: mac)),
                             ReviewScheduler.next(state: nil, grade: .hard, now: harness.clock.now),
                             in: mac.context, now: harness.clock.now)

        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()
        harness.clock.advance(); try ipad.sync()

        for device in [ipad, mac] {
            let s = try XCTUnwrap(state(try link(tape.id, on: device)))
            XCTAssertEqual(s.interval, 1, "\(device.name): Hard (the later review) won")
            XCTAssertEqual(s.ease, 2.35, accuracy: 1e-9)
        }
        XCTAssertEqual(try ipad.context.fetch(FetchDescriptor<Link>()).filter(Links.isTape).count, 1, "never duplicated")
    }

    func testRemovedTape_goesAwayOnTheOtherDevice() throws {
        let ipad = try harness.makeDevice("iPad")
        let mac = try harness.makeDevice("Mac")
        let notebook = try ipad.createNotebook(title: "Recall", pageCount: 1)
        let page = try XCTUnwrap(try ipad.pages(ofNotebook: notebook.id)).first!
        harness.clock.advance()
        let tape = Links.makeTape(on: page, strokeIDs: ["A"], anchor: anchor, in: ipad.context, now: harness.clock.now)
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()
        XCTAssertNotNil(try link(tape.id, on: mac))

        harness.clock.advance()
        Links.removeTape(try XCTUnwrap(try link(tape.id, on: ipad)), in: ipad.context, now: harness.clock.now)
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()

        XCTAssertNil(try link(tape.id, on: mac))
    }
}
