import XCTest
import SwiftData
@testable import Mystnotes

/// Two-library sync tests: independent devices sharing one sync folder,
/// driving the real `SyncRunner`. See `SyncTestHarness`.
@MainActor
final class SyncTests: XCTestCase {
    private var harness: SyncTestHarness!

    override func setUpWithError() throws {
        harness = try SyncTestHarness()
    }

    override func tearDown() {
        harness.tearDown()
        harness = nil
    }

    // MARK: Harness control

    /// Not a merge test - this proves the harness is wired through the real
    /// engine and the real folder. If this fails, nothing else here means
    /// anything.
    func testHarness_notebookPushedByOneDeviceIsPulledByAnother() throws {
        let ipad = try harness.makeDevice("iPad")
        let mac = try harness.makeDevice("Mac")

        let notebook = try ipad.createNotebook(title: "Physics", pageCount: 8)
        let notebookID = notebook.id
        let pageIDs = try XCTUnwrap(ipad.pages(ofNotebook: notebookID)).map(\.id)

        harness.clock.advance()
        try ipad.sync()
        harness.clock.advance()
        try mac.sync()

        let macPages = try XCTUnwrap(try mac.pages(ofNotebook: notebookID), "Mac never received the notebook")
        XCTAssertEqual(macPages.map(\.id), pageIDs, "page identities must survive the trip")
        for pageID in pageIDs {
            XCTAssertEqual(mac.ink(forPageID: pageID), ipad.ink(forPageID: pageID),
                           "Mac's ink for page \(pageID) differs from the iPad's")
        }

        // The two devices are genuinely separate libraries.
        XCTAssertNotEqual(ipad.filesDirectory, mac.filesDirectory)
        XCTAssertNotEqual(try ipad.context.fetchCount(FetchDescriptor<Page>()), 0)
    }

    // MARK: Page.modifiedAt (M0 task 4)

    func testMarkModified_datesPageAndLiftsNotebookButNeverLowersIt() throws {
        let ipad = try harness.makeDevice("iPad")
        let notebook = try ipad.createNotebook(title: "Physics", pageCount: 2)
        let pages = try XCTUnwrap(try ipad.pages(ofNotebook: notebook.id))
        let start = harness.clock.now

        let later = harness.clock.advance()
        pages[0].markModified(at: later)
        XCTAssertEqual(pages[0].modifiedAt, later)
        XCTAssertEqual(notebook.modifiedAt, later, "an edited page lifts its notebook")
        XCTAssertEqual(pages[1].modifiedAt, start, "the other page is untouched")

        // A backdated edit (clock skew, a replayed change) must not pull
        // the notebook back below its most recent page.
        let earlier = start.addingTimeInterval(-3600)
        pages[1].markModified(at: earlier)
        XCTAssertEqual(pages[1].modifiedAt, earlier)
        XCTAssertEqual(notebook.modifiedAt, later, "notebook.modifiedAt never goes backwards")
    }

    func testPageModifiedAt_reachesTheOtherDevice() throws {
        let ipad = try harness.makeDevice("iPad")
        let mac = try harness.makeDevice("Mac")
        let notebookID = try ipad.createNotebook(title: "Physics", pageCount: 3).id
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()

        let ipadPages = try XCTUnwrap(try ipad.pages(ofNotebook: notebookID))
        let editedAt = harness.clock.advance()
        try ipad.edit(page: ipadPages[1], ink: Data("edit".utf8))
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()

        let macPages = try XCTUnwrap(try mac.pages(ofNotebook: notebookID))
        XCTAssertEqual(macPages[1].modifiedAt, editedAt, "the page's own date must travel with it")
        XCTAssertNotEqual(macPages[0].modifiedAt, editedAt, "an unedited page keeps its date")
    }

    // MARK: PROJECT_PLAN §1.2 - the blocker

    /// Offline, the iPad writes on page 3 and the Mac writes on page 7 of the
    /// same notebook. After syncing, both edits must exist on both devices.
    ///
    /// Order follows §1.2: the Mac's `modifiedAt` is the newer one and it
    /// reaches the iPad, so the Mac pushes first. A final round on each side
    /// gives the engine every chance to converge before we look.
    func testEditsToDifferentPagesOnTwoDevicesBothSurvive() throws {
        let ipad = try harness.makeDevice("iPad")
        let mac = try harness.makeDevice("Mac")

        // Common starting point: one notebook, 8 pages, on both devices.
        let notebookID = try ipad.createNotebook(title: "Physics", pageCount: 8).id
        harness.clock.advance()
        try ipad.sync()
        harness.clock.advance()
        try mac.sync()

        let ipadPages = try XCTUnwrap(try ipad.pages(ofNotebook: notebookID))
        let macPages = try XCTUnwrap(try mac.pages(ofNotebook: notebookID))
        XCTAssertEqual(ipadPages.map(\.id), macPages.map(\.id), "precondition: both devices hold the same pages")
        let page3ID = ipadPages[2].id
        let page7ID = ipadPages[6].id

        // Offline edits, iPad first, Mac slightly later.
        let ipadInk = Data("iPad wrote on page 3".utf8)
        let macInk = Data("Mac wrote on page 7".utf8)
        harness.clock.advance()
        try ipad.edit(page: ipadPages[2], ink: ipadInk)
        harness.clock.advance()
        try mac.edit(page: macPages[6], ink: macInk)

        // Back online. Mac syncs first, then iPad, then one more round each.
        harness.clock.advance(); try mac.sync()
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()
        harness.clock.advance(); try ipad.sync()

        // Both devices still have all 8 pages...
        let ipadAfter = try XCTUnwrap(try ipad.pages(ofNotebook: notebookID), "iPad lost the notebook")
        let macAfter = try XCTUnwrap(try mac.pages(ofNotebook: notebookID), "Mac lost the notebook")
        XCTAssertEqual(ipadAfter.count, 8, "iPad lost pages")
        XCTAssertEqual(macAfter.count, 8, "Mac lost pages")
        XCTAssertTrue(ipadAfter.contains { $0.id == page3ID }, "iPad's page 3 vanished from the model")
        XCTAssertTrue(macAfter.contains { $0.id == page7ID }, "Mac's page 7 vanished from the model")

        // ...and both edits survived, everywhere.
        XCTAssertEqual(ipad.ink(forPageID: page3ID), ipadInk, "iPad lost its own page-3 edit")
        XCTAssertEqual(ipad.ink(forPageID: page7ID), macInk, "iPad never received the Mac's page-7 edit")
        XCTAssertEqual(mac.ink(forPageID: page7ID), macInk, "Mac lost its own page-7 edit")
        XCTAssertEqual(mac.ink(forPageID: page3ID), ipadInk, "Mac never received the iPad's page-3 edit")
        XCTAssertEqual(harness.inkInFolder(forPageID: page3ID), ipadInk, "sync folder holds a stale page 3")
        XCTAssertEqual(harness.inkInFolder(forPageID: page7ID), macInk, "sync folder holds a stale page 7")
    }
}
