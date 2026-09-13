import XCTest
import SwiftData
import PencilKit
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

    // MARK: What the first real two-device run found (Sept 12, 2026)

    /// `Date()` has microseconds; the file has milliseconds. The content
    /// signature must be computed from what the file says, or every
    /// notebook file "doesn't match its index entry" after one round trip
    /// and stays pending on every device forever - which is exactly what
    /// happened on the iPad and the Mac.
    func testSubMillisecondDates_doNotLeaveNotebooksPendingForever() throws {
        let ipad = try harness.makeDevice("iPad")
        let mac = try harness.makeDevice("Mac")
        let notebook = try ipad.createNotebook(title: "Spike", pageCount: 2)
        let pages = try XCTUnwrap(try ipad.pages(ofNotebook: notebook.id))

        // A real-clock edit: 0.4567 ms past the second.
        let realClock = harness.clock.advance().addingTimeInterval(0.0004567)
        try ipad.edit(page: pages[0], ink: Data("1".utf8))
        pages[0].markModified(at: realClock)
        try XCTUnwrap(try ipad.notebook(id: notebook.id)).markSettingsModified(at: realClock)
        try ipad.context.save()

        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()
        XCTAssertNotNil(mac.state.lastAppliedRemoteSignature, "the Mac's pull must be complete, not pending")

        // And the Mac can now publish its own edit - the part that never
        // happened on the real devices.
        let macPages = try XCTUnwrap(try mac.pages(ofNotebook: notebook.id))
        let macInk = Data("M".utf8)
        harness.clock.advance(); try mac.edit(page: macPages[1], ink: macInk)
        harness.clock.advance(); try mac.sync()
        harness.clock.advance(); try ipad.sync()
        XCTAssertEqual(ipad.ink(forPageID: pages[1].id), macInk, "the Mac's edit reached the iPad")
        XCTAssertEqual(harness.pageInFolder(pages[1].id)?.drawingHash, PayloadHash.sha256(of: macInk))
    }

    /// iCloud delivers files in its own time. An index another device wrote
    /// *before* our last push can land *after* it. It must still be read:
    /// "already applied" is a matter of content, not of timestamps.
    func testIndexArrivingOutOfOrder_isStillApplied() throws {
        let ipad = try harness.makeDevice("iPad")
        let mac = try harness.makeDevice("Mac")
        let notebook = try ipad.createNotebook(title: "A", pageCount: 2)
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()
        let ipadPages = try XCTUnwrap(try ipad.pages(ofNotebook: notebook.id))
        let macPages = try XCTUnwrap(try mac.pages(ofNotebook: notebook.id))

        // Mac edits page 2 and pushes - but its index is "in transit".
        let macInk = Data("Mac page 2".utf8)
        harness.clock.advance(); try mac.edit(page: macPages[1], ink: macInk)
        harness.clock.advance(); try mac.sync()
        let inTransit = try Data(contentsOf: harness.folderFile("index.json"))

        // iPad edits page 1 and pushes later; its index is now the file.
        harness.clock.advance(); try ipad.edit(page: ipadPages[0], ink: Data("iPad page 1".utf8))
        harness.clock.advance(); try ipad.sync()

        // Now the Mac's older index lands over it.
        try inTransit.write(to: harness.folderFile("index.json"))
        harness.clock.advance(); try ipad.sync()

        XCTAssertEqual(ipad.ink(forPageID: macPages[1].id), macInk, "the older-but-newly-arrived index must be applied")
        XCTAssertEqual(try ipad.pages(ofNotebook: notebook.id)?.count, 2)
    }

    /// The index's entries were written by a build that hashed differently
    /// (or the index and the notebook file came from different pushes). The
    /// file is here and readable, so it's applied *and* the notebook is
    /// republished with a current entry - otherwise no device could ever
    /// replace the stale one and every notebook would be pending forever.
    /// Exactly what the first real run hit after the signature fix shipped.
    func testStaleIndexEntry_isAppliedAndRepublished_notPendingForever() throws {
        let ipad = try harness.makeDevice("iPad")
        let mac = try harness.makeDevice("Mac")
        let notebook = try ipad.createNotebook(title: "A", pageCount: 2)
        harness.clock.advance(); try ipad.sync()

        // Rewrite the entry's signature the way an old build would have.
        var index = try harness.readIndex()
        index.notebooks = index.notebooks.map { e in var e = e; e.contentSignature = "old-format-" + e.contentSignature.prefix(8); return e }
        try harness.writeJSON(index, to: "index.json")

        harness.clock.advance(); try mac.sync()
        XCTAssertEqual(try mac.pages(ofNotebook: notebook.id)?.count, 2, "the file is applied despite the stale entry")
        let entry = try XCTUnwrap(try harness.readIndex().notebooks.first { $0.id == notebook.id })
        XCTAssertFalse(entry.contentSignature.hasPrefix("old-format"), "the Mac republished a current entry")
        XCTAssertEqual(try harness.readIndex().deviceName, "Mac")

        harness.clock.advance(); try mac.sync()
        XCTAssertNotNil(mac.state.lastAppliedRemoteSignature, "with a matching entry the pull completes")
    }

    /// A notebook that was pending at push time was published with the
    /// folder's own entry. Once its file is here, the next push must
    /// publish this library's version even though nothing changed
    /// locally in between. (It didn't: the push had recorded the local
    /// signature as "last pushed", so it thought it was done.)
    func testNotebookPendingAtPushTime_isPublishedByTheNextPush_withoutALocalChange() throws {
        let ipad = try harness.makeDevice("iPad")
        let mac = try harness.makeDevice("Mac")
        let a = try ipad.createNotebook(title: "A", pageCount: 1)
        let b = try ipad.createNotebook(title: "B", pageCount: 2)
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()
        let macB = try XCTUnwrap(try mac.pages(ofNotebook: b.id))
        let macInk = Data("Mac on B".utf8)
        harness.clock.advance(); try mac.edit(page: macB[0], ink: macInk)

        // B's file goes missing (still downloading) for the Mac's push.
        let bFile = harness.folderFile("notebooks/\(b.id.uuidString).json")
        let parked = bFile.appendingPathExtension("notyet")
        try FileManager.default.moveItem(at: bFile, to: parked)
        harness.clock.advance(); try mac.sync()
        XCTAssertNotEqual(harness.pageInFolder(macB[0].id)?.drawingHash, PayloadHash.sha256(of: macInk), "B was pending: not published")
        try FileManager.default.moveItem(at: parked, to: bFile)

        // Nothing changes on the Mac. The next sync must still publish B.
        harness.clock.advance(); try mac.sync()
        XCTAssertEqual(harness.pageInFolder(macB[0].id)?.drawingHash, PayloadHash.sha256(of: macInk), "B published once its file was back")
        _ = a
    }

    /// The folder holds something other than this library, but the device's
    /// stored "last pushed" marker happens to equal its own state (a
    /// leftover from a push that had to substitute the folder's entry).
    /// The marker must not decide; the folder must.
    func testStaleLastPushMarker_doesNotStopAPush() throws {
        let ipad = try harness.makeDevice("iPad")
        let mac = try harness.makeDevice("Mac")
        let notebook = try ipad.createNotebook(title: "A", pageCount: 2)
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()
        let macPages = try XCTUnwrap(try mac.pages(ofNotebook: notebook.id))
        let macInk = Data("Mac's edit".utf8)
        harness.clock.advance(); try mac.edit(page: macPages[0], ink: macInk)
        harness.clock.advance(); try mac.sync()
        XCTAssertEqual(harness.pageInFolder(macPages[0].id)?.drawingHash, PayloadHash.sha256(of: macInk), "precondition: published")

        // The folder loses the Mac's write (an older index lands over it)
        // while the Mac's marker still says "I pushed exactly this".
        let older = harness.historyFileNames().first!
        try Data(contentsOf: harness.folderFile("index-history/\(older)")).write(to: harness.folderFile("index.json"))
        mac.state.lastAppliedRemoteSignature = nil
        harness.clock.advance(); try mac.sync()
        XCTAssertEqual(harness.pageInFolder(macPages[0].id)?.drawingHash, PayloadHash.sha256(of: macInk), "the Mac must publish again because the folder differs")
        XCTAssertEqual(try harness.readIndex().deviceName, "Mac")
    }

    // MARK: Conflict versions (M0 task 8)

    /// Both devices pushed while offline; iCloud kept the loser's index as
    /// an unresolved conflict version. Reading it as a second snapshot
    /// brings the loser's page edit in, and the conflict is marked
    /// resolved only once everything merged.
    func testConflictVersionOfTheIndex_isMergedAndResolved() throws {
        let ipad = try harness.makeDevice("iPad")
        let mac = try harness.makeDevice("Mac")
        let notebook = try ipad.createNotebook(title: "Spike", pageCount: 4)
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()
        let ipadPages = try XCTUnwrap(try ipad.pages(ofNotebook: notebook.id))
        let macPages = try XCTUnwrap(try mac.pages(ofNotebook: notebook.id))
        let iInk = Data("I".utf8), mInk = Data("M".utf8)

        // Offline: iPad draws on page 1, Mac on page 2. iPad "wins" the
        // folder; the Mac's write becomes a conflict version.
        harness.clock.advance(); try ipad.edit(page: ipadPages[0], ink: iInk)
        harness.clock.advance(); try mac.edit(page: macPages[1], ink: mInk)
        harness.clock.advance(); try mac.sync()           // Mac's index + notebook file land first...
        let macIndex = try Data(contentsOf: harness.folderFile("index.json"))
        let macNotebook = try Data(contentsOf: harness.folderFile("notebooks/\(notebook.id.uuidString).json"))
        // ...then iCloud replaces them with the iPad's (ignoring the Mac's), keeping the Mac's as conflicts.
        ipad.state.lastAppliedRemoteSignature = nil
        ipad.state.lastPushSignature = ""
        try harness.writeJSON(try harness.readIndex(), to: "index.json")  // no-op; iPad must not see Mac's yet
        harness.clock.advance()
        // Force the iPad to push without merging the Mac's write: park the Mac's files, push, then plant them as conflicts.
        let parkedIndex = harness.folderFile("index.json.mac"), parkedNotebook = harness.folderFile("notebooks/\(notebook.id.uuidString).json.mac")
        try macIndex.write(to: parkedIndex); try macNotebook.write(to: parkedNotebook)
        try Data(contentsOf: harness.folderFile("index-history/\(harness.historyFileNames().first!)")).write(to: harness.folderFile("index.json"))
        try ipad.sync()
        XCTAssertEqual(try harness.readIndex().deviceName, "iPad", "the iPad's index is current")
        for device in [ipad, mac] {
            device.plantedConflicts[harness.folderFile("index.json").standardizedFileURL] = [parkedIndex]
            device.plantedConflicts[harness.folderFile("notebooks/\(notebook.id.uuidString).json").standardizedFileURL] = [parkedNotebook]
        }

        harness.clock.advance(); try ipad.sync()
        XCTAssertEqual(ipad.ink(forPageID: macPages[1].id), mInk, "the Mac's edit came in through the conflict version")
        XCTAssertEqual(ipad.ink(forPageID: ipadPages[0].id), iInk, "the iPad kept its own")
        XCTAssertFalse(ipad.resolvedConflicts.isEmpty, "the conflict was marked resolved after a complete merge")

        harness.clock.advance(); try mac.sync()
        XCTAssertEqual(mac.ink(forPageID: ipadPages[0].id), iInk)
        XCTAssertEqual(mac.ink(forPageID: macPages[1].id), mInk)
        let final = try XCTUnwrap(harness.pageInFolder(macPages[1].id))
        XCTAssertEqual(final.drawingHash, PayloadHash.sha256(of: mInk), "the folder now carries the union")
    }

    // MARK: Folder layout (M0 task 6)

    func testPush_writesIndexAndOneFilePerNotebook_neverLibraryJSON() throws {
        let ipad = try harness.makeDevice("iPad")
        let a = try ipad.createNotebook(title: "A", pageCount: 2)
        let b = try ipad.createNotebook(title: "B", pageCount: 1)
        harness.clock.advance(); try ipad.sync()

        XCTAssertTrue(harness.folderFileExists("index.json"))
        XCTAssertTrue(harness.folderFileExists("notebooks/\(a.id.uuidString).json"))
        XCTAssertTrue(harness.folderFileExists("notebooks/\(b.id.uuidString).json"))
        XCTAssertFalse(harness.folderFileExists("library.json"), "format 1 must never be written again")

        let index = try harness.readIndex()
        XCTAssertEqual(index.formatVersion, 2)
        XCTAssertEqual(Set(index.notebooks.map(\.id)), [a.id, b.id])
    }

    func testPush_rewritesOnlyTheNotebookThatChanged() throws {
        let ipad = try harness.makeDevice("iPad")
        let a = try ipad.createNotebook(title: "A", pageCount: 2)
        let b = try ipad.createNotebook(title: "B", pageCount: 2)
        harness.clock.advance(); try ipad.sync()
        let aBefore = try Data(contentsOf: harness.folderFile("notebooks/\(a.id.uuidString).json"))
        let bBefore = try Data(contentsOf: harness.folderFile("notebooks/\(b.id.uuidString).json"))

        let aPages = try XCTUnwrap(try ipad.pages(ofNotebook: a.id))
        harness.clock.advance(); try ipad.edit(page: aPages[0], ink: Data("edit".utf8))
        harness.clock.advance(); try ipad.sync()

        XCTAssertNotEqual(try Data(contentsOf: harness.folderFile("notebooks/\(a.id.uuidString).json")), aBefore, "A changed and must be rewritten")
        XCTAssertEqual(try Data(contentsOf: harness.folderFile("notebooks/\(b.id.uuidString).json")), bBefore, "B did not change and must not be touched")
    }

    /// iCloud delivers files in no particular order. If the index lands
    /// before a notebook file it points at, the pull applies what is there,
    /// leaves the "pulled" marker alone, and finishes on a later pull.
    func testPull_indexBeforeNotebookFile_appliesTheRestAndCompletesLater() throws {
        let ipad = try harness.makeDevice("iPad")
        let mac = try harness.makeDevice("Mac")
        let a = try ipad.createNotebook(title: "A", pageCount: 2)
        let b = try ipad.createNotebook(title: "B", pageCount: 2)
        harness.clock.advance(); try ipad.sync()

        // B's file hasn't "arrived" yet.
        let bFile = harness.folderFile("notebooks/\(b.id.uuidString).json")
        let parked = bFile.appendingPathExtension("notyet")
        try FileManager.default.moveItem(at: bFile, to: parked)

        harness.clock.advance(); try mac.sync()
        XCTAssertNotNil(try mac.notebook(id: a.id), "A arrived and must be applied")
        XCTAssertEqual(try mac.pages(ofNotebook: a.id)?.count, 2)
        XCTAssertNotNil(try mac.notebook(id: b.id), "B's settings are in the index; the notebook should exist")
        XCTAssertEqual(try mac.pages(ofNotebook: b.id)?.count, 0, "B's pages can't exist yet")
        XCTAssertNil(mac.state.lastAppliedRemoteSignature, "an incomplete pull must not be marked done")

        try FileManager.default.moveItem(at: parked, to: bFile)
        harness.clock.advance(); try mac.sync()
        XCTAssertEqual(try mac.pages(ofNotebook: b.id)?.count, 2, "B's pages must land once the file is here")
        XCTAssertNotNil(mac.state.lastAppliedRemoteSignature)
    }

    /// A folder written by the format-1 engine (one `library.json`) is read
    /// on the first sync, migrated on the first push, and left in place.
    func testLegacyLibraryJSON_isReadOnceAndLeftInPlace() throws {
        let pageID = UUID(), notebookID = UUID()
        let ink = Data("legacy ink".utf8)
        try FileManager.default.createDirectory(at: harness.folderFile("files"), withIntermediateDirectories: true)
        try ink.write(to: harness.folderFile("files/\(pageID.uuidString).drawing"))
        let legacy = LibrarySnapshot(
            formatVersion: 1,
            exportedAt: harness.clock.now,
            deviceName: "OldBuild",
            folders: [],
            notebooks: [NotebookDTO(
                formatVersion: nil, id: notebookID, title: "From the old format", coverStyle: "default",
                createdAt: harness.clock.now, modifiedAt: harness.clock.now, settingsModifiedAt: nil, folderID: nil,
                pages: [PageDTO(id: pageID, index: 0, type: "paged", template: "blank",
                                drawingFileRef: "\(pageID.uuidString).drawing", backgroundRef: nil,
                                recognizedTextCache: nil, ocrUpdatedAt: nil, modifiedAt: nil, aspectRatio: nil,
                                textBlocks: [], stickers: [], importedDocuments: [])],
                links: [])],
            notebookIndex: nil,
            tombstones: []
        )
        try harness.writeJSON(legacy, to: "library.json")
        let legacyBytes = try Data(contentsOf: harness.folderFile("library.json"))

        let mac = try harness.makeDevice("Mac")
        harness.clock.advance(); try mac.sync()

        XCTAssertEqual(try mac.notebook(id: notebookID)?.title, "From the old format")
        XCTAssertEqual(mac.ink(forPageID: pageID), ink)
        XCTAssertTrue(harness.folderFileExists("index.json"), "the push should have written the new layout")
        XCTAssertTrue(harness.folderFileExists("notebooks/\(notebookID.uuidString).json"))
        XCTAssertEqual(try Data(contentsOf: harness.folderFile("library.json")), legacyBytes, "library.json is never rewritten or removed")
    }

    /// A folder from a newer build is refused, and nothing local changes.
    func testNewerFormat_isRefusedAndTouchesNothing() throws {
        let ipad = try harness.makeDevice("iPad")
        let notebook = try ipad.createNotebook(title: "Mine", pageCount: 1)
        try FileManager.default.createDirectory(at: harness.workingDirectory, withIntermediateDirectories: true)
        try Data("""
        {"formatVersion": 99, "exportedAt": "2030-01-01T00:00:00.000Z", "deviceName": "Future",
         "folders": [], "notebooks": [], "tombstones": [], "somethingNew": true}
        """.utf8).write(to: harness.folderFile("index.json"))

        XCTAssertThrowsError(try ipad.sync()) { error in
            XCTAssertTrue(error is SyncRunner.SyncFormatError, "expected the format gate, got \(error)")
        }
        XCTAssertEqual(try ipad.notebook(id: notebook.id)?.title, "Mine")
        XCTAssertEqual(try ipad.pages(ofNotebook: notebook.id)?.count, 1)
        XCTAssertFalse(harness.folderFileExists("notebooks/\(notebook.id.uuidString).json"), "must not write into a newer folder")
        XCTAssertNil(ipad.state.lastAppliedRemoteSignature)
    }

    /// Notebook settings merge on their own clock: a rename here survives a
    /// later page edit there.
    func testRenameOnOneDevice_survivesLaterPageEditOnTheOther() throws {
        let ipad = try harness.makeDevice("iPad")
        let mac = try harness.makeDevice("Mac")
        let notebookID = try ipad.createNotebook(title: "Physics", pageCount: 2).id
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()

        harness.clock.advance(); try ipad.rename(try XCTUnwrap(try ipad.notebook(id: notebookID)), to: "Physics 101")
        let macPages = try XCTUnwrap(try mac.pages(ofNotebook: notebookID))
        let macInk = Data("Mac wrote later".utf8)
        harness.clock.advance(); try mac.edit(page: macPages[0], ink: macInk)

        harness.clock.advance(); try mac.sync()
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()
        harness.clock.advance(); try ipad.sync()

        for device in [ipad, mac] {
            XCTAssertEqual(try device.notebook(id: notebookID)?.title, "Physics 101", "\(device.name) lost the rename")
            XCTAssertEqual(device.ink(forPageID: macPages[0].id), macInk, "\(device.name) lost the page edit")
        }
    }

    // MARK: The index is rebuildable from the folder (M0 task 19)

    /// Invariant 4. Build a library with folders, notebooks, pages, ink, a
    /// text block and a link; sync it; wipe the index; rebuild. Everything
    /// the index said before, it says again.
    func testRebuild_reconstructsTheIndexFromTheFolder() throws {
        let ipad = try harness.makeDevice("iPad")
        let school = try ipad.createFolder(name: "School")
        let physics = try ipad.createFolder(name: "Physics", parent: school)
        let mechanics = try ipad.createNotebook(title: "Mechanics", pageCount: 3)
        mechanics.folder = physics
        let loose = try ipad.createNotebook(title: "Loose notes", pageCount: 2)
        let mPages = try XCTUnwrap(try ipad.pages(ofNotebook: mechanics.id))
        let lPages = try XCTUnwrap(try ipad.pages(ofNotebook: loose.id))
        harness.clock.advance(); try ipad.addTextBlock(to: mPages[0], content: "F = ma")
        harness.clock.advance(); _ = try ipad.addLink(from: mPages[1], to: lPages[0])
        let store = DrawingStore.inDirectory(ipad.filesDirectory)
        harness.clock.advance()
        mPages[2].drawingFileRef = try store.save(InkFixtures.drawing(inkType: .pencil, strokes: 2), pageID: mPages[2].id)
        mPages[2].markModified(at: harness.clock.now)
        try ipad.context.save()
        harness.clock.advance(); try ipad.sync()

        let before = try ipad.shape()
        let inkBefore = try XCTUnwrap(store.load(pageID: mPages[2].id))
        XCTAssertEqual(before.notebooks.count, 2, "precondition")

        try LibraryRebuild.rebuild(container: ipad.container, environment: ipad.environment)

        XCTAssertEqual(try ipad.shape(), before, "the rebuilt index must say exactly what the original did")
        let rebuiltStore = DrawingStore.inDirectory(ipad.filesDirectory)
        assertStrokesEqual(try XCTUnwrap(rebuiltStore.load(pageID: mPages[2].id)), inkBefore, "ink after rebuild")
        for page in lPages { XCTAssertNotNil(ipad.ink(forPageID: page.id), "raw ink for \(page.index) survived") }
        XCTAssertNotNil(ipad.state.lastAppliedRemoteSignature, "the rebuild is a complete pull")
    }

    /// No sync folder was ever chosen. The local mirror is enough to
    /// rebuild from, and it copies no payloads - the ink is already here.
    func testRebuild_fromTheLocalMirror_whenNoSyncFolderExists() throws {
        let ipad = try harness.makeDevice("iPad")
        let school = try ipad.createFolder(name: "School")
        let notebook = try ipad.createNotebook(title: "Mechanics", pageCount: 3)
        notebook.folder = school
        let pages = try XCTUnwrap(try ipad.pages(ofNotebook: notebook.id))
        harness.clock.advance(); try ipad.addTextBlock(to: pages[0], content: "F = ma")
        let store = DrawingStore.inDirectory(ipad.filesDirectory)
        harness.clock.advance()
        pages[1].drawingFileRef = try store.save(InkFixtures.drawing(inkType: .pen, strokes: 2), pageID: pages[1].id)
        pages[1].markModified(at: harness.clock.now)
        try ipad.context.save()

        harness.clock.advance(); try ipad.writeMirror()
        let before = try ipad.shape()
        let mirrorFiles = ipad.mirrorDirectory.appendingPathComponent("Mystnotes/files")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ipad.mirrorDirectory.appendingPathComponent("Mystnotes/index.json").path))
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: mirrorFiles.path)) ?? []).isEmpty,
                      "the mirror is metadata only; payloads are not duplicated")

        try LibraryRebuild.rebuild(container: ipad.container, environment: ipad.mirrorEnvironment)

        XCTAssertEqual(try ipad.shape(), before)
        XCTAssertEqual(DrawingStore.inDirectory(ipad.filesDirectory).load(pageID: pages[1].id)?.strokes.count, 2, "ink in place, untouched")
        XCTAssertNotNil(ipad.ink(forPageID: pages[0].id))
    }

    /// A page deleted after the mirror was last written must not come back
    /// from it: the mirror shares the device's tombstones.
    func testRebuild_fromTheMirror_doesNotResurrectADeletedPage() throws {
        let ipad = try harness.makeDevice("iPad")
        let notebook = try ipad.createNotebook(title: "A", pageCount: 3)
        let pages = try XCTUnwrap(try ipad.pages(ofNotebook: notebook.id))
        harness.clock.advance(); try ipad.writeMirror()

        harness.clock.advance(); try ipad.deletePage(pages[1])
        harness.clock.advance(); try ipad.writeMirror()   // the app writes it after every change
        try LibraryRebuild.rebuild(container: ipad.container, environment: ipad.mirrorEnvironment)
        XCTAssertEqual(try ipad.pages(ofNotebook: notebook.id)?.map(\.id), [pages[0].id, pages[2].id])

        // Even a mirror written *before* the deletion can't bring it back.
        try FileManager.default.removeItem(at: ipad.mirrorDirectory)
        // (Simulate: the older mirror is what's on disk, the tombstone is in state.)
        ipad.mirrorState.lastPushSignature = ""
        ipad.mirrorState.lastAppliedRemoteSignature = nil
        harness.clock.advance(); try ipad.writeMirror()
        try LibraryRebuild.rebuild(container: ipad.container, environment: ipad.mirrorEnvironment)
        XCTAssertFalse(try XCTUnwrap(try ipad.pages(ofNotebook: notebook.id)).contains { $0.id == pages[1].id })
    }

    /// A rebuild is a repair, not a merge: it must not push anything, and
    /// an edit that never reached the folder ends up in trash, not gone.
    func testRebuild_neverPushes_andKeepsUnpushedInkInTrash() throws {
        let ipad = try harness.makeDevice("iPad")
        let notebook = try ipad.createNotebook(title: "A", pageCount: 1)
        let page = try XCTUnwrap(try ipad.pages(ofNotebook: notebook.id)?.first)
        harness.clock.advance(); try ipad.sync()
        let indexBefore = try Data(contentsOf: harness.folderFile("index.json"))

        let unpushed = Data("edited after the last push".utf8)
        harness.clock.advance(); try ipad.edit(page: page, ink: unpushed)

        try LibraryRebuild.rebuild(container: ipad.container, environment: ipad.environment)

        XCTAssertEqual(try Data(contentsOf: harness.folderFile("index.json")), indexBefore, "a rebuild reads; it never writes the folder")
        XCTAssertNotEqual(ipad.ink(forPageID: page.id), unpushed, "the folder's version is what the index now describes")
        XCTAssertTrue(ipad.trashedInk().contains(unpushed), "the unpushed edit is in trash, not lost")
    }

    // MARK: Ink travels as the neutral record (M0 task 16b)

    /// A real drawing saved through DrawingStore on one device loads through
    /// DrawingStore on the other with the same strokes and the same ids.
    func testNeutralInk_roundTripsBetweenDevices_withStableIDs() throws {
        let ipad = try harness.makeDevice("iPad")
        let mac = try harness.makeDevice("Mac")
        let notebook = try ipad.createNotebook(title: "Ink", pageCount: 1)
        let page = try XCTUnwrap(try ipad.pages(ofNotebook: notebook.id)?.first)

        let ipadStore = DrawingStore.inDirectory(ipad.filesDirectory)
        let drawing = InkFixtures.drawing(inkType: .pen, strokes: 3)
        harness.clock.advance()
        page.drawingFileRef = try ipadStore.save(drawing, pageID: page.id)
        page.markModified(at: harness.clock.now)
        try ipad.context.save()
        XCTAssertEqual(page.drawingFileRef, "\(page.id.uuidString).strokes")
        let ids = drawing.strokes.map { ipadStore.ids.map(for: page.id).existingID(for: $0)! }

        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()

        let macStore = DrawingStore.inDirectory(mac.filesDirectory)
        let loaded = try XCTUnwrap(macStore.load(pageID: page.id), "the record did not arrive")
        assertStrokesEqual(loaded, drawing, "across devices")
        XCTAssertEqual(loaded.strokes.map { macStore.ids.map(for: page.id).existingID(for: $0)! }, ids,
                       "stroke ids are the same on both devices")
        XCTAssertTrue(harness.folderPayloadNames().allSatisfy { $0.hasSuffix(".strokes") },
                      "only the neutral record is synced, never the PKDrawing cache: \(harness.folderPayloadNames())")
    }

    // MARK: Evicted files (M0 task 14)

    /// An evicted `index.json` is a dotted placeholder. That's "wait", not
    /// "no library here": nothing may be written over an index we couldn't
    /// read, and nothing local changes.
    func testEvictedIndex_isWaiting_notAnEmptyFolder() throws {
        let ipad = try harness.makeDevice("iPad")
        let notebook = try ipad.createNotebook(title: "Mine", pageCount: 1)
        try FileManager.default.createDirectory(at: harness.workingDirectory, withIntermediateDirectories: true)
        try Data().write(to: harness.folderFile(".index.json.icloud"))

        XCTAssertThrowsError(try ipad.sync()) { error in
            XCTAssertTrue(error is SyncRunner.Waiting, "expected Waiting, got \(error)")
        }
        XCTAssertFalse(harness.folderFileExists("index.json"), "must not write an index over one it couldn't read")
        XCTAssertFalse(harness.folderFileExists("notebooks/\(notebook.id.uuidString).json"))
        XCTAssertEqual(try ipad.pages(ofNotebook: notebook.id)?.count, 1)
    }

    /// An evicted payload defers its page the same way a partial download
    /// does, and the sync itself completes without waiting.
    func testEvictedPayload_defersThePage_withoutBlocking() throws {
        let ipad = try harness.makeDevice("iPad")
        let mac = try harness.makeDevice("Mac")
        let notebook = try ipad.createNotebook(title: "A", pageCount: 2)
        let pages = try XCTUnwrap(try ipad.pages(ofNotebook: notebook.id))
        let ink = Data("evicted on the Mac".utf8)
        harness.clock.advance(); try ipad.edit(page: pages[1], ink: ink)
        harness.clock.advance(); try ipad.sync()

        // iCloud evicted the payload on the Mac's side: placeholder only.
        let name = "\(PayloadHash.sha256(of: ink)).drawing"
        let payload = harness.folderFile("files/\(name)")
        try FileManager.default.moveItem(at: payload, to: harness.folderFile("files/.\(name).icloud"))

        let started = Date()
        harness.clock.advance(); try mac.sync()
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "a missing download must not be waited for")
        XCTAssertEqual(try mac.pages(ofNotebook: notebook.id)?.count, 1)
        XCTAssertNil(mac.state.lastAppliedRemoteSignature)

        // It downloads.
        try FileManager.default.moveItem(at: harness.folderFile("files/.\(name).icloud"), to: payload)
        harness.clock.advance(); try mac.sync()
        XCTAssertEqual(mac.ink(forPageID: pages[1].id), ink)
    }

    // MARK: Nothing is ever deleted (M0 task 11)

    func testDeletePage_movesInkToLocalTrash() throws {
        let ipad = try harness.makeDevice("iPad")
        let notebook = try ipad.createNotebook(title: "A", pageCount: 2)
        let pages = try XCTUnwrap(try ipad.pages(ofNotebook: notebook.id))
        let ink = Data("ink on the page about to go".utf8)
        harness.clock.advance(); try ipad.edit(page: pages[1], ink: ink)

        harness.clock.advance(); try ipad.deletePage(pages[1])

        XCTAssertNil(ipad.ink(forPageID: pages[1].id), "the live file is gone")
        XCTAssertTrue(ipad.trashedInk().contains(ink), "the ink is in trash, not destroyed")
    }

    /// Deleting a page on one device moves its ink to trash on the other
    /// as well - the tombstone never destroys anything.
    func testPageTombstone_trashesInkOnTheOtherDevice() throws {
        let ipad = try harness.makeDevice("iPad")
        let mac = try harness.makeDevice("Mac")
        let notebook = try ipad.createNotebook(title: "A", pageCount: 2)
        let pages = try XCTUnwrap(try ipad.pages(ofNotebook: notebook.id))
        let ink = Data("Mac will have this".utf8)
        harness.clock.advance(); try ipad.edit(page: pages[1], ink: ink)
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()
        XCTAssertEqual(mac.ink(forPageID: pages[1].id), ink, "precondition")

        harness.clock.advance(); try ipad.deletePage(pages[1])
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()

        XCTAssertNil(mac.ink(forPageID: pages[1].id))
        XCTAssertTrue(mac.trashedInk().contains(ink), "the Mac's copy went to its trash")
    }

    /// A payload nothing references any more is moved to the folder's
    /// trash - but only after the grace period, so a notebook file that
    /// hasn't arrived can't lose its ink.
    func testPush_movesOrphanedPayloadsToFolderTrash_onlyAfterGracePeriod() throws {
        let ipad = try harness.makeDevice("iPad")
        ipad.orphanGracePeriod = 3600
        let notebook = try ipad.createNotebook(title: "A", pageCount: 1)
        let page = try XCTUnwrap(try ipad.pages(ofNotebook: notebook.id)?.first)
        let oldInk = Data("first version".utf8), newInk = Data("second version".utf8)
        harness.clock.advance(); try ipad.edit(page: page, ink: oldInk)
        harness.clock.advance(); try ipad.sync()
        let oldName = "\(PayloadHash.sha256(of: oldInk)).drawing"
        let newName = "\(PayloadHash.sha256(of: newInk)).drawing"

        // Supersede it. The old payload is now unreferenced but fresh.
        harness.clock.advance(); try ipad.edit(page: page, ink: newInk)
        harness.clock.advance(); try ipad.sync()
        XCTAssertEqual(harness.folderPayloadNames(), [oldName, newName], "a fresh orphan is kept")
        XCTAssertTrue(harness.folderTrashNames().isEmpty)

        // Age it past the grace period (file mtime is what pruning reads;
        // the harness clock is what "now" is).
        try FileManager.default.setAttributes([.modificationDate: harness.clock.now.addingTimeInterval(-7200)],
                                              ofItemAtPath: harness.folderFile("files/\(oldName)").path)
        harness.clock.advance(); try ipad.edit(page: page, ink: Data("third".utf8))
        harness.clock.advance(); try ipad.sync()

        XCTAssertFalse(harness.folderPayloadNames().contains(oldName), "the aged orphan left files/")
        XCTAssertTrue(harness.folderTrashNames().contains { $0.hasPrefix(String(oldName.prefix(20))) }, "…and is in trash, not gone")
        XCTAssertTrue(harness.folderPayloadNames().contains(newName), "a fresh orphan is still kept")
    }

    func testPush_movesTombstonedNotebookFileToFolderTrash() throws {
        let ipad = try harness.makeDevice("iPad")
        let notebook = try ipad.createNotebook(title: "Gone", pageCount: 1)
        harness.clock.advance(); try ipad.sync()
        let file = "notebooks/\(notebook.id.uuidString).json"
        XCTAssertTrue(harness.folderFileExists(file), "precondition")

        harness.clock.advance(); try ipad.deleteNotebook(try XCTUnwrap(try ipad.notebook(id: notebook.id)))
        harness.clock.advance(); try ipad.sync()

        XCTAssertFalse(harness.folderFileExists(file))
        XCTAssertTrue(harness.folderTrashNames().contains { $0.hasPrefix(notebook.id.uuidString) })
    }

    // MARK: Payload hashes are remembered between runs

    func testPayloadHashes_arePersisted_validatedByStat_andPrunedForMissingFiles() throws {
        let ipad = try harness.makeDevice("iPad")
        let notebook = try ipad.createNotebook(title: "A", pageCount: 3)
        let pages = try XCTUnwrap(try ipad.pages(ofNotebook: notebook.id))
        harness.clock.advance(); try ipad.sync()

        let cacheURL = ipad.filesDirectory.appendingPathComponent(SyncRunner.PayloadHashCache.fileName)
        let first = try JSONDecoder().decode([String: SyncRunner.PayloadHashCache.Entry].self, from: Data(contentsOf: cacheURL))
        XCTAssertEqual(first.count, 3, "one entry per payload after the first push")

        // A rewritten payload is rehashed; the untouched ones are not.
        let newInk = Data("rewritten".utf8)
        harness.clock.advance(); try ipad.edit(page: pages[0], ink: newInk)
        harness.clock.advance(); try ipad.sync()
        let second = try JSONDecoder().decode([String: SyncRunner.PayloadHashCache.Entry].self, from: Data(contentsOf: cacheURL))
        let name0 = try XCTUnwrap(pages[0].drawingFileRef), name1 = try XCTUnwrap(pages[1].drawingFileRef)
        XCTAssertEqual(second[name0]?.hash, PayloadHash.sha256(of: newInk))
        XCTAssertNotEqual(second[name0], first[name0])
        XCTAssertEqual(second[name1], first[name1], "an untouched payload keeps its entry")
        XCTAssertEqual(try XCTUnwrap(harness.pageInFolder(pages[0].id)).drawingHash, PayloadHash.sha256(of: newInk),
                       "the folder sees the new hash, so the cache was not trusted blindly")

        // A payload that disappears is dropped from the cache.
        harness.clock.advance(); try ipad.deletePage(pages[2])
        harness.clock.advance(); try ipad.sync()
        let third = try JSONDecoder().decode([String: SyncRunner.PayloadHashCache.Entry].self, from: Data(contentsOf: cacheURL))
        XCTAssertNil(third[try XCTUnwrap(pages[2].drawingFileRef)])
    }

    // MARK: Content-addressed payloads (M0 task 10)

    func testPayloads_areNamedByContentHash_andIdenticalInkIsStoredOnce() throws {
        let ipad = try harness.makeDevice("iPad")
        let notebook = try ipad.createNotebook(title: "A", pageCount: 2)
        let pages = try XCTUnwrap(try ipad.pages(ofNotebook: notebook.id))
        let ink = Data("same ink on both pages".utf8)
        harness.clock.advance(); try ipad.edit(page: pages[0], ink: ink)
        harness.clock.advance(); try ipad.edit(page: pages[1], ink: ink)
        harness.clock.advance(); try ipad.sync()

        let expected = "\(PayloadHash.sha256(of: ink)).drawing"
        XCTAssertEqual(harness.folderPayloadNames(), [expected], "one file, named by its hash")
        for page in pages {
            let dto = try XCTUnwrap(harness.pageInFolder(page.id))
            XCTAssertEqual(dto.drawingHash, PayloadHash.sha256(of: ink))
            XCTAssertEqual(dto.drawingFileRef, "\(page.id.uuidString).drawing", "local name is unchanged")
        }
        XCTAssertEqual(harness.inkInFolder(forPageID: pages[0].id), ink)
    }

    /// A payload still downloading rehashes to something other than its
    /// name. That page must not be applied, the notebook must not be
    /// republished from the incomplete side, and the next pull finishes.
    func testPull_partialPayload_defersThePage_andCompletesLater() throws {
        let ipad = try harness.makeDevice("iPad")
        let mac = try harness.makeDevice("Mac")
        let notebook = try ipad.createNotebook(title: "A", pageCount: 2)
        let pages = try XCTUnwrap(try ipad.pages(ofNotebook: notebook.id))
        let ink = Data("this ink takes a while to download".utf8)
        harness.clock.advance(); try ipad.edit(page: pages[1], ink: ink)
        harness.clock.advance(); try ipad.sync()

        // Simulate iCloud mid-download: the file exists but is truncated.
        let payload = harness.folderFile("files/\(PayloadHash.sha256(of: ink)).drawing")
        let complete = try Data(contentsOf: payload)
        try complete.prefix(complete.count / 2).write(to: payload)
        let notebookFileBefore = try Data(contentsOf: harness.folderFile("notebooks/\(notebook.id.uuidString).json"))

        harness.clock.advance(); try mac.sync()
        XCTAssertEqual(try mac.pages(ofNotebook: notebook.id)?.count, 1, "the page whose ink is incomplete is not applied yet")
        XCTAssertNil(mac.ink(forPageID: pages[1].id), "no half-downloaded ink may land locally")
        XCTAssertNil(mac.state.lastAppliedRemoteSignature, "an incomplete pull is not marked done")
        XCTAssertEqual(try Data(contentsOf: harness.folderFile("notebooks/\(notebook.id.uuidString).json")), notebookFileBefore,
                       "the incomplete side must not republish the notebook")

        try complete.write(to: payload)
        harness.clock.advance(); try mac.sync()
        XCTAssertEqual(try mac.pages(ofNotebook: notebook.id)?.count, 2)
        XCTAssertEqual(mac.ink(forPageID: pages[1].id), ink)
        XCTAssertNotNil(mac.state.lastAppliedRemoteSignature)
    }

    // MARK: Index history (M0 task 7)

    func testPush_keepsTheLastNIndexes_andTheNewestMatchesIndexJSON() throws {
        let ipad = try harness.makeDevice("iPad", indexHistoryLimit: 3)
        let notebook = try ipad.createNotebook(title: "A", pageCount: 1)
        let page = try XCTUnwrap(try ipad.pages(ofNotebook: notebook.id)?.first)

        for round in 1...5 {
            harness.clock.advance(); try ipad.edit(page: page, ink: Data("round \(round)".utf8))
            harness.clock.advance(); try ipad.sync()
        }

        let history = harness.historyFileNames()
        XCTAssertEqual(history.count, 3, "history should be pruned to the limit, got \(history)")
        let newest = try XCTUnwrap(history.last)
        XCTAssertEqual(try Data(contentsOf: harness.folderFile("index-history/\(newest)")),
                       try Data(contentsOf: harness.folderFile("index.json")),
                       "the newest history entry is a copy of the current index")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = SnapshotDates.decoding
        let oldest = try decoder.decode(LibraryIndex.self, from: Data(contentsOf: harness.folderFile("index-history/\(history[0])")))
        XCTAssertEqual(oldest.notebooks.first?.id, notebook.id, "older entries must still decode")
    }

    // MARK: Tombstones in the folder (M0 task 9)

    /// A deletion is recorded in `tombstones.json`, not in the index, and
    /// a device that had the notebook removes it on pull.
    func testNotebookDeletion_travelsThroughTombstonesJSON() throws {
        let ipad = try harness.makeDevice("iPad")
        let mac = try harness.makeDevice("Mac")
        let keep = try ipad.createNotebook(title: "Keep", pageCount: 1)
        let gone = try ipad.createNotebook(title: "Gone", pageCount: 1)
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()
        XCTAssertNotNil(try mac.notebook(id: gone.id), "precondition")

        harness.clock.advance(); try ipad.deleteNotebook(try XCTUnwrap(try ipad.notebook(id: gone.id)))
        harness.clock.advance(); try ipad.sync()

        let file = try harness.readTombstoneFile()
        XCTAssertTrue(file.tombstones.contains { $0.id == gone.id && $0.kind == .notebook })
        XCTAssertNil(try harness.readIndex().tombstones, "the index no longer carries tombstones")
        XCTAssertFalse(try harness.readIndex().notebooks.contains { $0.id == gone.id })

        harness.clock.advance(); try mac.sync()
        XCTAssertNil(try mac.notebook(id: gone.id), "the Mac should have removed the deleted notebook")
        XCTAssertNotNil(try mac.notebook(id: keep.id))
        XCTAssertTrue(mac.trashedInk().count >= 1, "the deleted notebook's ink went to the Mac's trash, not away")
    }

    /// A fresh device (reinstall) that pulls a folder with a tombstone and
    /// then pushes must re-broadcast it - the folder is the record.
    func testTombstones_surviveAReinstallAndAreReBroadcast() throws {
        let ipad = try harness.makeDevice("iPad")
        let notebook = try ipad.createNotebook(title: "Gone", pageCount: 1)
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try ipad.deleteNotebook(try XCTUnwrap(try ipad.notebook(id: notebook.id)))
        harness.clock.advance(); try ipad.sync()

        let fresh = try harness.makeDevice("Reinstalled")
        harness.clock.advance(); try fresh.sync()
        XCTAssertTrue(SyncTombstones.load(from: fresh.state).contains { $0.id == notebook.id })

        // Its own push must keep the tombstone in the folder.
        _ = try fresh.createNotebook(title: "New here", pageCount: 1)
        harness.clock.advance(); try fresh.sync()
        XCTAssertTrue(try harness.readTombstoneFile().tombstones.contains { $0.id == notebook.id })
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

    /// Same scenario, other order: the iPad reaches the folder first. This
    /// passed even under whole-notebook merge, because payload files travel
    /// separately from metadata; it's pinned so both orders stay green.
    func testEditsToDifferentPages_iPadSyncsFirst_bothSurvive() throws {
        let ipad = try harness.makeDevice("iPad")
        let mac = try harness.makeDevice("Mac")
        let notebookID = try ipad.createNotebook(title: "Physics", pageCount: 8).id
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()
        let ipadPages = try XCTUnwrap(try ipad.pages(ofNotebook: notebookID))
        let macPages = try XCTUnwrap(try mac.pages(ofNotebook: notebookID))
        let page3ID = ipadPages[2].id, page7ID = ipadPages[6].id
        let ipadInk = Data("iPad wrote on page 3".utf8), macInk = Data("Mac wrote on page 7".utf8)

        harness.clock.advance(); try ipad.edit(page: ipadPages[2], ink: ipadInk)
        harness.clock.advance(); try mac.edit(page: macPages[6], ink: macInk)

        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()

        for device in [ipad, mac] {
            XCTAssertEqual(try device.pages(ofNotebook: notebookID)?.count, 8, "\(device.name) lost pages")
            XCTAssertEqual(device.ink(forPageID: page3ID), ipadInk, "\(device.name): page 3 wrong")
            XCTAssertEqual(device.ink(forPageID: page7ID), macInk, "\(device.name): page 7 wrong")
        }
    }

    /// Invariant 2, directly: a pull that changes one page must not replace
    /// the others. The untouched page's SwiftData identity survives.
    func testPull_updatesPagesInPlace_neverRebuildsTheTree() throws {
        let ipad = try harness.makeDevice("iPad")
        let mac = try harness.makeDevice("Mac")
        let notebookID = try ipad.createNotebook(title: "Physics", pageCount: 4).id
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()

        let macBefore = try XCTUnwrap(try mac.pages(ofNotebook: notebookID))
        let identitiesBefore = macBefore.map(\.persistentModelID)

        let ipadPages = try XCTUnwrap(try ipad.pages(ofNotebook: notebookID))
        harness.clock.advance(); try ipad.edit(page: ipadPages[1], ink: Data("new".utf8))
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()

        let macAfter = try XCTUnwrap(try mac.pages(ofNotebook: notebookID))
        XCTAssertEqual(macAfter.map(\.persistentModelID), identitiesBefore,
                       "page objects were deleted and recreated - the tree was rebuilt")
    }

    // MARK: Same page, both devices - keep both versions

    /// Both devices write on page 3 offline; the Mac is later. Both must
    /// end up showing the Mac's ink, and the iPad's ink must still exist
    /// in the iPad's trash - the losing side is recoverable, never gone.
    func testSamePageEditedOnBothDevices_newerShows_olderIsKeptInTrash() throws {
        let ipad = try harness.makeDevice("iPad")
        let mac = try harness.makeDevice("Mac")
        let notebookID = try ipad.createNotebook(title: "Physics", pageCount: 4).id
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()
        let ipadPages = try XCTUnwrap(try ipad.pages(ofNotebook: notebookID))
        let macPages = try XCTUnwrap(try mac.pages(ofNotebook: notebookID))
        let page3ID = ipadPages[2].id
        let ipadInk = Data("iPad's version of page 3".utf8)
        let macInk = Data("Mac's later version of page 3".utf8)

        harness.clock.advance(); try ipad.edit(page: ipadPages[2], ink: ipadInk)
        harness.clock.advance(); try mac.edit(page: macPages[2], ink: macInk)

        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()

        XCTAssertEqual(ipad.ink(forPageID: page3ID), macInk, "iPad should show the newer (Mac) ink")
        XCTAssertEqual(mac.ink(forPageID: page3ID), macInk, "Mac should keep its own newer ink")
        XCTAssertEqual(harness.inkInFolder(forPageID: page3ID), macInk)
        XCTAssertTrue(ipad.trashedInk().contains(ipadInk), "the iPad's losing ink must be in its trash, not destroyed")
        XCTAssertEqual(try ipad.pages(ofNotebook: notebookID)?.count, 4)
    }

    // MARK: Deletion

    /// A page deleted on one device disappears on the other and does not
    /// come back on later rounds.
    func testPageDeletedOnOneDevice_isRemovedOnTheOther_andStaysRemoved() throws {
        let ipad = try harness.makeDevice("iPad")
        let mac = try harness.makeDevice("Mac")
        let notebookID = try ipad.createNotebook(title: "Physics", pageCount: 4).id
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()
        let ipadPages = try XCTUnwrap(try ipad.pages(ofNotebook: notebookID))
        let deletedID = ipadPages[1].id

        harness.clock.advance(); try ipad.deletePage(ipadPages[1])
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()

        for device in [ipad, mac] {
            let pages = try XCTUnwrap(try device.pages(ofNotebook: notebookID))
            XCTAssertEqual(pages.count, 3, "\(device.name) has the wrong page count")
            XCTAssertFalse(pages.contains { $0.id == deletedID }, "\(device.name): the deleted page came back")
            XCTAssertEqual(pages.map(\.index), [0, 1, 2], "\(device.name): indices not contiguous")
        }
    }

    /// The other device edited the page *after* it was deleted. The edit is
    /// newer than the deletion, so the page - and its ink - survive on both.
    func testPageEditedAfterRemoteDeletion_survivesEverywhere() throws {
        let ipad = try harness.makeDevice("iPad")
        let mac = try harness.makeDevice("Mac")
        let notebookID = try ipad.createNotebook(title: "Physics", pageCount: 4).id
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()
        let ipadPages = try XCTUnwrap(try ipad.pages(ofNotebook: notebookID))
        let macPages = try XCTUnwrap(try mac.pages(ofNotebook: notebookID))
        let pageID = ipadPages[1].id
        let macInk = Data("Mac kept writing on page 2".utf8)

        harness.clock.advance(); try ipad.deletePage(ipadPages[1])
        harness.clock.advance(); try mac.edit(page: macPages[1], ink: macInk)

        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()

        for device in [ipad, mac] {
            let pages = try XCTUnwrap(try device.pages(ofNotebook: notebookID))
            XCTAssertTrue(pages.contains { $0.id == pageID }, "\(device.name): a page edited after deletion was lost")
            XCTAssertEqual(device.ink(forPageID: pageID), macInk, "\(device.name): the post-deletion ink was lost")
        }
    }
}
