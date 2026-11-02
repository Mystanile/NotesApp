import XCTest
import SwiftData
@testable import Mystnotes

/// Recording transcripts (M3): the segment JSON, merging words into
/// sentences, seeking, search (blob + label), the snapshot DTO and export.
final class TranscriptTests: XCTestCase {

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

    private func seg(_ s: Double, _ e: Double, _ t: String) -> TranscriptSegment {
        TranscriptSegment(start: s, end: e, text: t)
    }

    // MARK: Segments

    func testSegments_jsonRoundTrip() {
        let segments = [seg(0, 2.5, "Hello there."), seg(3, 7.25, "Second part")]
        XCTAssertEqual(TranscriptSegment.decode(TranscriptSegment.encode(segments)), segments)
    }

    func testSegments_decodeOfNilOrGarbage_isEmpty() {
        XCTAssertEqual(TranscriptSegment.decode(nil), [])
        XCTAssertEqual(TranscriptSegment.decode("not json"), [])
    }

    func testMerge_closesAtSentenceEnd_afterMinimumSpan() {
        let words = [seg(0, 1, "Hello "), seg(1, 2.2, "world."), seg(2.3, 3, " Next "), seg(3, 4, "bit.")]
        let merged = TranscriptSegment.merge(words)
        XCTAssertEqual(merged.map(\.text), ["Hello world.", "Next bit."])
        XCTAssertEqual(merged[0].start, 0)
        XCTAssertEqual(merged[0].end, 2.2)
    }

    func testMerge_capsSegmentLength() {
        let words = (0..<30).map { seg(Double($0), Double($0) + 1, "w\($0) ") }
        let merged = TranscriptSegment.merge(words, maxSpan: 12)
        XCTAssertGreaterThan(merged.count, 1)
        for s in merged { XCTAssertLessThanOrEqual(s.end - s.start, 12.0001) }
    }

    func testMerge_splitsAfterALongPause() {
        let merged = TranscriptSegment.merge([seg(0, 1, "one "), seg(5, 6, "two")])
        XCTAssertEqual(merged.map(\.text), ["one", "two"])
    }

    func testSeekTarget_isTheStartOfTheSegmentContainingTheTime() {
        let segments = [seg(0, 4, "a"), seg(5, 9, "b")]
        XCTAssertEqual(TranscriptSegment.seekTarget(at: 6.2, in: segments), 5)
        XCTAssertEqual(TranscriptSegment.seekTarget(at: 4.5, in: segments), 0)   // in the gap: previous stays lit
        XCTAssertEqual(TranscriptSegment.index(at: 6.2, in: segments), 1)
        XCTAssertNil(TranscriptSegment.seekTarget(at: 60, in: segments))
        XCTAssertNil(TranscriptSegment.seekTarget(at: 1, in: []))
    }

    // MARK: Search

    @MainActor
    private func pageWithTranscript(_ context: ModelContext, body: String? = nil) -> Page {
        let page = Page(index: 0)
        context.insert(page)
        if let body { page.title = body }
        let recording = Recording(page: page, startedAt: Date(), duration: 10, fileRef: "a.m4a")
        recording.transcript = "Mitochondria are the powerhouse"
        context.insert(recording)
        page.recordings = [recording]
        return page
    }

    @MainActor
    func testSearchBlob_includesTranscript_andLabelsRecordingOnlyMatches() throws {
        let context = try makeContext()
        let page = pageWithTranscript(context)
        let blob = SearchIndex.searchableText(for: page, importedDocuments: [])
        XCTAssertTrue(blob.contains("powerhouse"))
        XCTAssertEqual(SearchIndex.recordingSnippetLabel(for: page, importedDocuments: [], needles: "powerhouse"),
                       "in a recording")
        XCTAssertNil(SearchIndex.recordingSnippetLabel(for: page, importedDocuments: [], needles: "absent"))
    }

    @MainActor
    func testSearchLabel_isNil_whenThePageAlsoMatchesElsewhere() throws {
        let context = try makeContext()
        let page = pageWithTranscript(context, body: "Powerhouse notes")
        XCTAssertNil(SearchIndex.recordingSnippetLabel(for: page, importedDocuments: [], needles: "powerhouse"))
    }

    @MainActor
    func testBlobCache_rebuilds_whenATranscriptArrivesWithoutAClockMoving() throws {
        let context = try makeContext()
        SearchIndex.resetBlobCache()
        let page = Page(index: 0)
        context.insert(page)
        let recording = Recording(page: page, startedAt: Date(), duration: 5, fileRef: "b.m4a")
        context.insert(recording)
        page.recordings = [recording]
        XCTAssertFalse(SearchIndex.cachedSearchableText(for: page, importedDocuments: []).contains("zebra"))
        recording.transcript = "a zebra crossing"
        XCTAssertTrue(SearchIndex.cachedSearchableText(for: page, importedDocuments: []).contains("zebra"))
    }

    // MARK: Snapshot

    func testRecordingDTO_decodesWithoutTranscriptFields() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","duration":3.5,"fileRef":"x.m4a"}"#
        let dto = try JSONDecoder().decode(RecordingDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.id, id)
        XCTAssertNil(dto.transcript)
        XCTAssertNil(dto.transcriptSegments)
    }

    func testRecordingDTO_roundTripsTranscript() throws {
        let dto = RecordingDTO(id: UUID(), startedAt: nil, duration: 1, fileRef: "x.m4a", fileHash: nil, title: nil,
                               transcript: "hi", transcriptSegments: TranscriptSegment.encode([seg(0, 1, "hi")]))
        let back = try JSONDecoder().decode(RecordingDTO.self, from: JSONEncoder().encode(dto))
        XCTAssertEqual(back.transcript, "hi")
        XCTAssertEqual(TranscriptSegment.decode(back.transcriptSegments), [seg(0, 1, "hi")])
    }

    // MARK: Model

    @MainActor
    func testWritingATranscript_doesNotMoveThePageClock() throws {
        let context = try makeContext()
        let page = pageWithTranscript(context)
        let before = page.modifiedAt
        let recording = try XCTUnwrap(page.recordings?.first)
        recording.transcript = "changed"
        recording.transcriptSegments = TranscriptSegment.encode([seg(0, 1, "changed")])
        XCTAssertEqual(page.modifiedAt, before)
        XCTAssertEqual(recording.segments.count, 1)
    }
}
