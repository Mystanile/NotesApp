import XCTest
import SwiftData
@testable import Mystnotes

/// Backups are the sync folder's own layout, written by the push path -
/// so a backup restores the way any sync folder does.
@MainActor
final class BackupTests: XCTestCase {
    private var harness: SyncTestHarness!

    override func setUp() async throws {
        harness = try SyncTestHarness()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: harness.root)
    }

    func testABackup_restoresOntoAFreshDevice_withItsInk() throws {
        let ipad = try harness.makeDevice("iPad")
        let notebook = try ipad.createNotebook(title: "Thermo", pageCount: 2)
        let page = try XCTUnwrap(try ipad.pages(ofNotebook: notebook.id)?.last)
        try ipad.edit(page: page, ink: Data("the second law".utf8))

        // Never synced: the backup alone carries the library.
        try Backup.stage(container: ipad.container, localFiles: ipad.filesDirectory, into: harness.syncFolder)

        let restored = try harness.makeDevice("New iPad")
        try restored.sync()
        let pages = try XCTUnwrap(try restored.pages(ofNotebook: notebook.id), "the notebook didn't come back")
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(restored.ink(forPageID: page.id), Data("the second law".utf8), "the ink didn't come back")
    }

    func testArchive_isAZipNamedForTheWeekday_overwrittenAWeekLater() throws {
        let ipad = try harness.makeDevice("iPad")
        _ = try ipad.createNotebook(title: "Thermo", pageCount: 1)
        let destination = harness.root.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let monday = ISO8601DateFormatter().date(from: "2026-09-28T09:00:00Z")!
        let zip = try Backup.archive(container: ipad.container, localFiles: ipad.filesDirectory,
                                     to: destination, now: monday)
        XCTAssertTrue(zip.lastPathComponent.hasPrefix("Mystnotes Backup"), zip.lastPathComponent)
        XCTAssertEqual(Array(try Data(contentsOf: zip).prefix(4)), [0x50, 0x4B, 0x03, 0x04])

        let nextMonday = monday.addingTimeInterval(7 * 24 * 3600)
        let again = try Backup.archive(container: ipad.container, localFiles: ipad.filesDirectory,
                                       to: destination, now: nextMonday)
        XCTAssertEqual(again, zip, "a week later the same day's file is replaced")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).count, 1)
    }
}
