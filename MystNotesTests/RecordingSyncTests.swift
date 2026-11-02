import XCTest
import SwiftData
@testable import Mystnotes

/// A recording's audio file follows the same rule as ink (invariants 1 and 3,
/// "same-page concurrent edits keep both versions"): when a pull replaces or
/// deletes a local page, the losing side's audio goes to `trash/`, never away
/// and never left orphaned in the library.
@MainActor
final class RecordingSyncTests: XCTestCase {
    private var harness: SyncTestHarness!

    override func setUpWithError() throws {
        harness = try SyncTestHarness()
    }

    override func tearDown() {
        harness.tearDown()
        harness = nil
    }

    private func trashedNames(_ device: SyncTestDevice) -> [String] {
        let trash = device.filesDirectory.appendingPathComponent("trash", isDirectory: true)
        return (try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []
    }

    private func inLibraryRoot(_ device: SyncTestDevice, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: device.filesDirectory.appendingPathComponent(name).path)
    }

    /// A records audio on page P and does not sync; B edits P later and
    /// wins. A's pull must move A's audio into A's trash/.
    func testRemoteWins_trashesTheLosingDevicesAudio() throws {
        let ipad = try harness.makeDevice("iPad")
        let mac = try harness.makeDevice("Mac")
        let notebookID = try ipad.createNotebook(title: "Lecture", pageCount: 1).id
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()
        let ipadPage = try XCTUnwrap(try ipad.pages(ofNotebook: notebookID))[0]
        let macPage = try XCTUnwrap(try mac.pages(ofNotebook: notebookID))[0]

        let audio = Data("iPad's unsynced lecture audio".utf8)
        let ref = "\(UUID().uuidString).m4a"
        harness.clock.advance(); _ = try ipad.addRecording(to: ipadPage, named: ref, bytes: audio)
        harness.clock.advance(); try mac.edit(page: macPage, ink: Data("Mac's later ink".utf8))
        harness.clock.advance(); try mac.sync()

        harness.clock.advance(); try ipad.sync()

        XCTAssertTrue(try ipad.recordings(onPageID: ipadPage.id).isEmpty, "the Mac's page shows, with no recording")
        XCTAssertFalse(inLibraryRoot(ipad, ref), "the audio is out of the library root")
        let trashed = trashedNames(ipad).filter { $0.hasSuffix(".m4a") }
        XCTAssertEqual(trashed.count, 1, "and in trash/, not deleted")
        let trash = ipad.filesDirectory.appendingPathComponent("trash", isDirectory: true)
        let kept = try Data(contentsOf: trash.appendingPathComponent(try XCTUnwrap(trashed.first)))
        XCTAssertEqual(kept, audio)
    }

    /// A recording the winning remote page still names is not trashed.
    func testRemoteWins_keepsAudioTheWinningPageStillNames() throws {
        let ipad = try harness.makeDevice("iPad")
        let mac = try harness.makeDevice("Mac")
        let notebookID = try ipad.createNotebook(title: "Lecture", pageCount: 1).id
        let audio = Data("shared lecture audio".utf8)
        let ref = "\(UUID().uuidString).m4a"
        let ipadPage = try XCTUnwrap(try ipad.pages(ofNotebook: notebookID))[0]
        harness.clock.advance(); _ = try ipad.addRecording(to: ipadPage, named: ref, bytes: audio)
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()
        let macPage = try XCTUnwrap(try mac.pages(ofNotebook: notebookID))[0]
        XCTAssertEqual(try mac.recordings(onPageID: macPage.id).count, 1, "precondition")

        // Both edit; the Mac is later and keeps the recording.
        harness.clock.advance(); try ipad.edit(page: ipadPage, ink: Data("iPad ink".utf8))
        harness.clock.advance(); try mac.edit(page: macPage, ink: Data("Mac later ink".utf8))
        harness.clock.advance(); try mac.sync()
        harness.clock.advance(); try ipad.sync()

        XCTAssertEqual(try ipad.recordings(onPageID: ipadPage.id).map(\.fileRef), [ref])
        XCTAssertEqual(ipad.payload(named: ref), audio, "still in the library")
        XCTAssertTrue(trashedNames(ipad).filter { $0.hasSuffix(".m4a") }.isEmpty, "nothing trashed")
    }

    /// A page tombstone from the other device trashes the audio.
    func testPageTombstone_trashesTheAudio() throws {
        let ipad = try harness.makeDevice("iPad")
        let mac = try harness.makeDevice("Mac")
        let notebook = try ipad.createNotebook(title: "A", pageCount: 2)
        let pages = try XCTUnwrap(try ipad.pages(ofNotebook: notebook.id))
        let audio = Data("audio on a doomed page".utf8)
        let ref = "\(UUID().uuidString).m4a"
        harness.clock.advance(); _ = try ipad.addRecording(to: pages[1], named: ref, bytes: audio)
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()
        XCTAssertEqual(mac.payload(named: ref), audio, "precondition")

        harness.clock.advance(); try ipad.deletePage(pages[1])
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()

        XCTAssertFalse(inLibraryRoot(mac, ref))
        XCTAssertEqual(trashedNames(mac).filter { $0.hasSuffix(".m4a") }.count, 1, "the Mac's copy went to its trash")
    }

    /// A notebook tombstone trashes the audio of its pages.
    func testNotebookTombstone_trashesTheAudio() throws {
        let ipad = try harness.makeDevice("iPad")
        let mac = try harness.makeDevice("Mac")
        let notebook = try ipad.createNotebook(title: "A", pageCount: 1)
        let page = try XCTUnwrap(try ipad.pages(ofNotebook: notebook.id))[0]
        let ref = "\(UUID().uuidString).m4a"
        harness.clock.advance(); _ = try ipad.addRecording(to: page, named: ref, bytes: Data("nb audio".utf8))
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()
        XCTAssertNotNil(mac.payload(named: ref), "precondition")

        harness.clock.advance(); try ipad.deleteNotebook(notebook)
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()

        XCTAssertFalse(inLibraryRoot(mac, ref))
        XCTAssertEqual(trashedNames(mac).filter { $0.hasSuffix(".m4a") }.count, 1)
    }
}
