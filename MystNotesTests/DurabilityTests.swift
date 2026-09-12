import XCTest
import PencilKit
import SwiftData
@testable import Mystnotes

/// Invariant 1: never lose ink. Every write is atomic and recoverable, and
/// whatever a kill leaves on disk, the last committed state must load.
///
/// A unit test can't kill its own process, so each test reproduces the
/// on-disk state a kill leaves behind and drives the app's real load/save
/// path (`DrawingStore`) over it. Nothing here writes drawing bytes by
/// hand except to plant corruption.
@MainActor
final class DurabilityTests: XCTestCase {
    private var directory: URL!
    private var store: DrawingStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DurabilityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = DrawingStore.inDirectory(directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Mid-stroke

    /// A stroke in progress lives only in `PKCanvasView`; autosave fires a
    /// second after it ends. Killed mid-stroke, the file on disk is the
    /// last autosave, so this is what "kill mid-stroke" must load. It's
    /// also the control for the rest of the suite: save and load round-trip
    /// a real drawing exactly.
    func testKillMidStroke_lastAutosaveLoadsIntact() throws {
        let pageID = UUID()
        let saved = makeDrawing(strokes: 3)

        try store.save(saved, pageID: pageID)

        let loaded = try XCTUnwrap(store.load(pageID: pageID), "the last autosave did not load")
        XCTAssertEqual(loaded, saved)
        XCTAssertEqual(loaded.strokes.count, 3)
    }

    // MARK: Mid-save

    /// The process dies partway through writing the drawing file. Whatever
    /// is on disk afterwards must load as a committed drawing - the one
    /// before the save or the one being saved - never as nothing.
    ///
    /// The legacy-ink rescale in `MystNotesDetailView.fittingWithinPage`
    /// writes back through the same path on load, so this also covers a
    /// kill in the middle of that migration.
    func testKillMidSave_previousDrawingSurvives() throws {
        let pageID = UUID()
        let first = makeDrawing(strokes: 3)
        let second = makeDrawing(strokes: 5, xOffset: 200, seed: 100)
        try store.save(first, pageID: pageID)

        var dying = store!
        dying.write = Self.writerKilled(afterFraction: 0.5)
        XCTAssertThrowsError(try dying.save(second, pageID: pageID))

        let loaded = store.load(pageID: pageID)
        XCTAssertNotNil(loaded, "kill mid-write left an unreadable file: the previous drawing is gone and the page will load blank")
        if let loaded {
            XCTAssertTrue(loaded == first || loaded == second,
                          "loaded a drawing that is neither the previous one nor the new one")
        }
    }

    /// The file was written but the process died before `context.save()`
    /// persisted `drawingFileRef`. Loading keys on the page id, so the ink
    /// must still come back.
    func testKillBetweenFileWriteAndModelSave_drawingStillLoads() throws {
        let pageID = UUID()
        let saved = makeDrawing(strokes: 2)
        try store.save(saved, pageID: pageID)

        // Relaunch: the Page row has no drawingFileRef. Load must not care.
        let page = Page(index: 0)
        page.id = pageID
        XCTAssertNil(page.drawingFileRef)

        XCTAssertEqual(store.load(pageID: page.id), saved)
    }

    // MARK: Corruption from outside the save path

    /// A `.drawing` file that can't be decoded - a payload copied from the
    /// sync folder before it finished downloading, a bad sector, anything.
    /// Loading it must not silently present a blank page that the next
    /// autosave then writes over the only copy. The damaged bytes have to
    /// survive somewhere the user can recover from.
    func testUnreadableDrawing_isNotOverwrittenByNextSave() throws {
        let pageID = UUID()
        let damaged = Data("this is not a PKDrawing".utf8)
        try damaged.write(to: store.fileURL(for: pageID))

        // The app opens the page...
        let loaded = store.load(pageID: pageID)
        // ...the user draws one stroke, autosave fires.
        try store.save(loaded ?? makeDrawing(strokes: 1), pageID: pageID)

        XCTAssertTrue(fileExists(withContents: damaged, under: directory),
                      "the unreadable drawing was overwritten - the only copy of that ink is destroyed")
    }

    // MARK: Migration

    /// A library written by an earlier build opens under the current schema
    /// with its notebook, pages and ink intact. Trivially true while the
    /// schema is unchanged; the moment a field is added (M0 task 4 adds
    /// `Page.modifiedAt`) this exercises SwiftData's lightweight migration
    /// against a real store from before the change.
    ///
    /// Regenerate the fixture only when the format deliberately moves on:
    ///   TEST_RUNNER_MYSTNOTES_GENERATE_FIXTURE=<dir> xcodebuild test ... \
    ///     -only-testing:MystnotesTests/DurabilityTests/testGenerateSchemaFixture
    func testPreviousSchemaFixture_opensWithNotebookPagesAndInk() throws {
        let bundle = Bundle(for: DurabilityTests.self)
        let fixtureStore = try XCTUnwrap(
            bundle.url(forResource: Self.fixtureStoreName, withExtension: "sqlite", subdirectory: "Fixtures")
                ?? bundle.url(forResource: Self.fixtureStoreName, withExtension: "sqlite"),
            "fixture store missing from the test bundle")

        // Never open the bundled copy: SQLite wants to write next to it.
        let storeURL = directory.appendingPathComponent("store.sqlite")
        try FileManager.default.copyItem(at: fixtureStore, to: storeURL)

        let container = try ModelContainer(for: Self.schema, configurations: [
            ModelConfiguration("fixture", schema: Self.schema, url: storeURL, cloudKitDatabase: .none)
        ])
        let context = ModelContext(container)

        let title = Self.fixtureNotebookTitle
        let notebooks = try context.fetch(FetchDescriptor<Notebook>(predicate: #Predicate { $0.title == title }))
        let notebook = try XCTUnwrap(notebooks.first, "fixture notebook did not survive opening the store")
        let pages = (notebook.pages ?? []).sorted { $0.index < $1.index }
        XCTAssertEqual(pages.count, Self.fixturePageCount)

        for page in pages {
            let inkURL = try XCTUnwrap(
                bundle.url(forResource: page.id.uuidString, withExtension: "drawing", subdirectory: "Fixtures")
                    ?? bundle.url(forResource: page.id.uuidString, withExtension: "drawing"),
                "fixture ink for page \(page.index) missing from the test bundle")
            try FileManager.default.copyItem(at: inkURL, to: store.fileURL(for: page.id))
            let drawing = try XCTUnwrap(store.load(pageID: page.id), "fixture ink for page \(page.index) did not load")
            XCTAssertEqual(drawing.strokes.count, page.index + 1)
        }
    }

    /// The fixture was written before `Page.modifiedAt` existed. After the
    /// lightweight migration those pages must come back with `nil` - the
    /// value merge treats as "older than anything dated" - not with a
    /// backfilled date that would make every migrated page look freshly
    /// edited on every device at once.
    func testPreviousSchemaFixture_pagesWithoutModifiedAtMigrateToNil() throws {
        let bundle = Bundle(for: DurabilityTests.self)
        let fixtureStore = try XCTUnwrap(
            bundle.url(forResource: Self.fixtureStoreName, withExtension: "sqlite", subdirectory: "Fixtures")
                ?? bundle.url(forResource: Self.fixtureStoreName, withExtension: "sqlite"))
        let storeURL = directory.appendingPathComponent("store.sqlite")
        try FileManager.default.copyItem(at: fixtureStore, to: storeURL)

        let container = try ModelContainer(for: Self.schema, configurations: [
            ModelConfiguration("fixture", schema: Self.schema, url: storeURL, cloudKitDatabase: .none)
        ])
        let pages = try ModelContext(container).fetch(FetchDescriptor<Page>())
        XCTAssertEqual(pages.count, Self.fixturePageCount)
        for page in pages {
            XCTAssertNil(page.modifiedAt, "page \(page.index) from the pre-modifiedAt store should migrate to nil")
        }
    }

    /// Writes a fresh fixture with the *current* schema. Skipped unless
    /// `MYSTNOTES_GENERATE_FIXTURE` names an output directory.
    func testGenerateSchemaFixture() throws {
        guard let out = ProcessInfo.processInfo.environment["MYSTNOTES_GENERATE_FIXTURE"] else {
            throw XCTSkip("set MYSTNOTES_GENERATE_FIXTURE=<dir> to regenerate the schema fixture")
        }
        let outDir = URL(fileURLWithPath: out, isDirectory: true)
        try? FileManager.default.removeItem(at: outDir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let storeURL = outDir.appendingPathComponent("\(Self.fixtureStoreName).sqlite")
        let container = try ModelContainer(for: Self.schema, configurations: [
            ModelConfiguration("fixture", schema: Self.schema, url: storeURL, cloudKitDatabase: .none)
        ])
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let inkStore = DrawingStore.inDirectory(outDir)
        let notebook = Notebook(title: Self.fixtureNotebookTitle)
        context.insert(notebook)
        for index in 0..<Self.fixturePageCount {
            let page = Page(index: index, notebook: notebook)
            context.insert(page)
            notebook.pages?.append(page)
            page.drawingFileRef = try inkStore.save(makeDrawing(strokes: index + 1, seed: UInt32(index * 10)), pageID: page.id)
        }
        try context.save()
        print("FIXTURE written to \(outDir.path)")
    }

    // MARK: - Helpers

    private static let fixtureStoreName = "schema-v1"
    private static let fixtureNotebookTitle = "Schema Fixture"
    private static let fixturePageCount = 3

    private static let schema = Schema([
        Folder.self, Notebook.self, Page.self, TypedTextBlock.self,
        ImportedDocument.self, Link.self, Sticker.self
    ])

    /// A writer that gets `fraction` of the bytes onto disk and then dies,
    /// leaving exactly what an interrupted `write(2)` leaves.
    private static func writerKilled(afterFraction fraction: Double) -> (Data, URL) throws -> Void {
        { data, url in
            let partial = data.prefix(Int(Double(data.count) * fraction))
            try partial.write(to: url)
            throw SimulatedKill.midWrite
        }
    }

    private enum SimulatedKill: Error { case midWrite }

    /// Real strokes with real points, so the file is a genuine `PKDrawing`
    /// payload and equality means what it says.
    private func makeDrawing(strokes: Int, xOffset: CGFloat = 0, seed: UInt32 = 1) -> PKDrawing {
        let ink = PKInk(.pen, color: .black)
        let result = (0..<strokes).map { strokeIndex -> PKStroke in
            let points = (0..<24).map { pointIndex in
                PKStrokePoint(
                    location: CGPoint(x: xOffset + 40 + CGFloat(pointIndex) * 8,
                                      y: 100 + CGFloat(strokeIndex) * 60),
                    timeOffset: TimeInterval(pointIndex) * 0.008,
                    size: CGSize(width: 3, height: 3),
                    opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
                )
            }
            let path = PKStrokePath(controlPoints: points,
                                    creationDate: Date(timeIntervalSince1970: 1_800_000_000 + Double(strokeIndex)))
            return PKStroke(ink: ink, path: path, randomSeed: seed + UInt32(strokeIndex))
        }
        return PKDrawing(strokes: result)
    }

    private func fileExists(withContents contents: Data, under root: URL) -> Bool {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return false
        }
        for case let url as URL in files {
            if (try? Data(contentsOf: url)) == contents { return true }
        }
        return false
    }
}
