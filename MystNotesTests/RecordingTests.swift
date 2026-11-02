import XCTest
import SwiftData
@testable import Mystnotes

/// Audio on a page (M3 seed): the model's defaults, the ink/audio timeline
/// arithmetic, deleting a recording (the file goes to `trash/`, never away,
/// and stays while another recording shares it) and export (invariant 9).
final class RecordingTests: XCTestCase {

    private static let schema = Schema([
        Folder.self, Notebook.self, Page.self, TypedTextBlock.self,
        ImportedDocument.self, Link.self, Sticker.self, Recording.self
    ])

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(for: Self.schema,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        return ModelContext(container)
    }

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RecordingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: Model

    @MainActor
    func testRecording_defaults_areAllOptionalOrDefaulted() throws {
        let context = try makeContext()
        let recording = Recording()
        context.insert(recording)
        XCTAssertNil(recording.page)
        XCTAssertNil(recording.startedAt)
        XCTAssertNil(recording.title)
        XCTAssertEqual(recording.duration, 0)
        XCTAssertEqual(recording.fileRef, "")
        XCTAssertTrue(Page().recordings?.isEmpty ?? false, "a new page has no recordings")
        try context.save()
    }

    @MainActor
    func testRecording_cascadesWithItsPage() throws {
        let context = try makeContext()
        let notebook = Notebook(title: "N")
        let page = Page(index: 0, notebook: notebook)
        context.insert(notebook); context.insert(page)
        let recording = Recording(page: page, startedAt: Date(), duration: 5, fileRef: "a.m4a")
        context.insert(recording)
        page.recordings?.append(recording)
        try context.save()
        context.delete(page)
        try context.save()
        XCTAssertTrue(try context.fetch(FetchDescriptor<Recording>()).isEmpty)
    }

    func testClock_formatsMinutesAndHours() {
        XCTAssertEqual(Recording.clock(0), "0:00")
        XCTAssertEqual(Recording.clock(65), "1:05")
        XCTAssertEqual(Recording.clock(3_725), "1:02:05")
        XCTAssertEqual(Recording.clock(-3), "0:00")
    }

    // MARK: InkTimeline

    func testOffset_isSecondsIntoTheRecording_andNilOutsideIt() {
        let start = Date(timeIntervalSince1970: 1_000)
        let rec = (start: start, duration: 60.0)
        XCTAssertEqual(InkTimeline.offset(of: start.addingTimeInterval(12.5), in: rec), 12.5)
        XCTAssertEqual(InkTimeline.offset(of: start, in: rec), 0)
        XCTAssertEqual(InkTimeline.offset(of: start.addingTimeInterval(60), in: rec), 60)
        XCTAssertNil(InkTimeline.offset(of: start.addingTimeInterval(-1), in: rec), "written before it began")
        XCTAssertNil(InkTimeline.offset(of: start.addingTimeInterval(61), in: rec), "written after it ended")
    }

    func testStrokeIndices_writtenAfterThePlayhead_excludeStrokesFromBeforeTheRecording() {
        let start = Date(timeIntervalSince1970: 1_000)
        let dates = [-30, 0, 5, 10, 20].map { start.addingTimeInterval(Double($0)) }
        let later = InkTimeline.strokeIndices(writtenAfter: 10, recordingStart: start, strokeDates: dates)
        XCTAssertEqual(Array(later), [4], "only the stroke at +20 s is after the playhead at 10 s")
        let all = InkTimeline.strokeIndices(writtenAfter: -1, recordingStart: start, strokeDates: dates)
        XCTAssertEqual(Array(all), [1, 2, 3, 4], "the pre-recording stroke is always shown")
        XCTAssertTrue(InkTimeline.strokeIndices(writtenAfter: 100, recordingStart: start, strokeDates: dates).isEmpty)
    }

    func testNearestStroke_picksTheSmallestContainingStroke_andIgnoresFarTaps() {
        let t = Date(timeIntervalSince1970: 0)
        let strokes: [(bounds: CGRect, date: Date)] = [
            (CGRect(x: 0, y: 0, width: 200, height: 200), t),                       // a box round everything
            (CGRect(x: 50, y: 50, width: 20, height: 20), t.addingTimeInterval(1)), // a word inside it
            (CGRect(x: 300, y: 300, width: 10, height: 10), t.addingTimeInterval(2))
        ]
        XCTAssertEqual(InkTimeline.nearestStroke(at: CGPoint(x: 60, y: 60), strokes: strokes), 1)
        XCTAssertEqual(InkTimeline.nearestStroke(at: CGPoint(x: 150, y: 150), strokes: strokes), 0)
        XCTAssertEqual(InkTimeline.nearestStroke(at: CGPoint(x: 305, y: 305), strokes: strokes), 2)
        XCTAssertEqual(InkTimeline.nearestStroke(at: CGPoint(x: 205, y: 205), strokes: strokes), 0, "inside the tolerance")
        XCTAssertNil(InkTimeline.nearestStroke(at: CGPoint(x: 500, y: 500), strokes: strokes))
        XCTAssertNil(InkTimeline.nearestStroke(at: .zero, strokes: []))
    }

    func testSeekOffset_isNilWhenTheTappedStrokeIsOutsideTheRecording() {
        let start = Date(timeIntervalSince1970: 1_000)
        let strokes: [(bounds: CGRect, date: Date)] = [
            (CGRect(x: 0, y: 0, width: 10, height: 10), start.addingTimeInterval(-5)),
            (CGRect(x: 100, y: 0, width: 10, height: 10), start.addingTimeInterval(7))
        ]
        let rec = (start: start, duration: 30.0)
        XCTAssertNil(InkTimeline.seekOffset(at: CGPoint(x: 5, y: 5), strokes: strokes, recording: rec))
        XCTAssertEqual(InkTimeline.seekOffset(at: CGPoint(x: 105, y: 5), strokes: strokes, recording: rec), 7)
    }

    // MARK: Deleting

    @MainActor
    private func pageWithRecordings(_ context: ModelContext, files: [String]) throws -> (Page, [Recording]) {
        let notebook = Notebook(title: "N")
        let page = Page(index: 0, notebook: notebook)
        context.insert(notebook); context.insert(page)
        notebook.pages = [page]
        var made: [Recording] = []
        for (i, file) in files.enumerated() {
            let r = Recording(page: page, startedAt: Date(timeIntervalSince1970: Double(1_000 + i)),
                              duration: 10, fileRef: file)
            context.insert(r)
            page.recordings?.append(r)
            made.append(r)
        }
        try context.save()
        return (page, made)
    }

    @MainActor
    func testDelete_movesTheFileToTrash_marksThePage_andRemovesTheRecord() throws {
        let dir = try tempDirectory()
        let context = try makeContext()
        let (page, recordings) = try pageWithRecordings(context, files: ["one.m4a"])
        try Data("audio".utf8).write(to: dir.appendingPathComponent("one.m4a"))
        page.modifiedAt = Date(timeIntervalSince1970: 100)
        let now = Date(timeIntervalSince1970: 5_000)

        Recording.delete(recordings[0], in: context, store: DrawingStore.inDirectory(dir), now: now)
        try context.save()

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("one.m4a").path))
        let trashed = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("trash").path)
        XCTAssertEqual(trashed.count, 1, "moved to trash/, not removed")
        XCTAssertTrue(trashed[0].hasPrefix("one-") && trashed[0].hasSuffix(".m4a"), trashed[0])
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("trash").appendingPathComponent(trashed[0])),
                       Data("audio".utf8))
        XCTAssertEqual(page.modifiedAt, now, "the deletion is a page edit, so it syncs")
        XCTAssertTrue(try context.fetch(FetchDescriptor<Recording>()).isEmpty)
    }

    @MainActor
    func testDelete_keepsTheFileWhileAnotherRecordingStillNamesIt() throws {
        let dir = try tempDirectory()
        let context = try makeContext()
        let (_, recordings) = try pageWithRecordings(context, files: ["shared.m4a", "shared.m4a"])
        try Data("audio".utf8).write(to: dir.appendingPathComponent("shared.m4a"))

        Recording.delete(recordings[0], in: context, store: DrawingStore.inDirectory(dir))
        try context.save()

        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("shared.m4a").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("trash").path))
        XCTAssertEqual(try context.fetch(FetchDescriptor<Recording>()).count, 1)
    }

    @MainActor
    func testPageDeletion_trashesItsAudio() throws {
        let dir = try tempDirectory()
        let context = try makeContext()
        let (page, _) = try pageWithRecordings(context, files: ["page-audio.m4a"])
        try Data("audio".utf8).write(to: dir.appendingPathComponent("page-audio.m4a"))
        let notebook = try XCTUnwrap(page.notebook)

        PageDeletion.delete(page, from: notebook, in: context,
                            drawingStore: DrawingStore.inDirectory(dir), tombstones: InMemorySyncStateStore())
        try context.save()

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("page-audio.m4a").path))
        let trashed = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("trash").path)
        XCTAssertTrue(trashed.contains { $0.hasPrefix("page-audio-") })
    }

    // MARK: Install

    func testInstall_movesTheTempFileIntoPlace() throws {
        let dir = try tempDirectory()
        let temp = dir.appendingPathComponent("temp.m4a")
        try Data("x".utf8).write(to: temp)
        let docs = dir.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try PageAudioController.install(temp, as: "final.m4a", in: docs)
        XCTAssertEqual(try Data(contentsOf: docs.appendingPathComponent("final.m4a")), Data("x".utf8))
    }

    // MARK: Export

    @MainActor
    func testMarkdown_listsEachRecordingUnderItsPage() throws {
        let context = try makeContext()
        let (page, recordings) = try pageWithRecordings(context, files: ["a.m4a"])
        recordings[0].title = "Week 4"
        recordings[0].duration = 125
        page.title = "Kinematics"
        let markdown = LibraryExport.markdown(for: try XCTUnwrap(page.notebook))
        XCTAssertTrue(markdown.contains("Audio: Week 4 (2:05)"), markdown)
    }

    @MainActor
    func testArchive_includesTheAudioFilesInRecordings() async throws {
        let work = try tempDirectory()
        let local = work.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let context = try makeContext()
        let (_, recordings) = try pageWithRecordings(context, files: ["lecture.m4a"])
        recordings[0].title = "Week 4"
        try Data("audio-bytes".utf8).write(to: local.appendingPathComponent("lecture.m4a"))
        let notebook = try XCTUnwrap(recordings[0].page?.notebook)

        let (folder, _) = try await LibraryExport.makeArchive(
            of: [notebook], documents: [], in: work,
            handwritingProfile: work.appendingPathComponent("none.json"), localFiles: local)

        let name = LibraryExport.recordingFileName(recordings[0])
        let exported = folder.appendingPathComponent("N/Recordings/\(name)")
        XCTAssertEqual(try Data(contentsOf: exported), Data("audio-bytes".utf8))
        XCTAssertTrue(name.hasPrefix("Week 4 "), name)
        let md = try String(contentsOf: folder.appendingPathComponent("N.md"), encoding: .utf8)
        XCTAssertTrue(md.contains("Audio: Week 4 (0:10)"), md)
    }
}
