import XCTest
@testable import Mystnotes

/// The pieces of search indexing and highlights that don't need Vision or a
/// device: the blob cache, the Vision-to-drawing rect mapping, line matching,
/// the staleness test and the lines cache's round trip.
@MainActor
final class SearchIndexerTests: XCTestCase {

    // MARK: - Blob cache

    func testBlobCache_rebuildsOnlyWhenTheKeyChanges() {
        SearchIndex.resetBlobCache()
        let id = UUID()
        let edited = Date(timeIntervalSince1970: 1_000)
        let ocr1 = Date(timeIntervalSince1970: 2_000)
        let ocr2 = Date(timeIntervalSince1970: 3_000)
        var builds = 0
        func blob(ocr: Date?, modified: Date? = edited, content: Int = 0) -> String {
            let key = SearchIndex.BlobKey(pageID: id, modifiedAt: modified, ocrUpdatedAt: ocr, contentHash: content)
            return SearchIndex.blob(forKey: key) { builds += 1; return "build \(builds)" }
        }

        XCTAssertEqual(blob(ocr: ocr1), "build 1")
        XCTAssertEqual(blob(ocr: ocr1), "build 1", "same key: served from the cache")
        XCTAssertEqual(builds, 1)

        XCTAssertEqual(blob(ocr: ocr2), "build 2", "a new ocrUpdatedAt invalidates the blob")
        XCTAssertEqual(blob(ocr: ocr2), "build 2")

        XCTAssertEqual(blob(ocr: ocr2, modified: Date(timeIntervalSince1970: 1_500)), "build 3",
                       "a new modifiedAt invalidates it too")
        XCTAssertEqual(blob(ocr: ocr2, modified: Date(timeIntervalSince1970: 1_500), content: 7), "build 4",
                       "so does changed title/tag/text content")
        SearchIndex.resetBlobCache()
    }

    func testBlobCache_isPerPage() {
        SearchIndex.resetBlobCache()
        let a = SearchIndex.BlobKey(pageID: UUID(), modifiedAt: nil, ocrUpdatedAt: nil, contentHash: 0)
        let b = SearchIndex.BlobKey(pageID: UUID(), modifiedAt: nil, ocrUpdatedAt: nil, contentHash: 0)
        XCTAssertEqual(SearchIndex.blob(forKey: a) { "a" }, "a")
        XCTAssertEqual(SearchIndex.blob(forKey: b) { "b" }, "b")
        XCTAssertEqual(SearchIndex.blob(forKey: a) { "rebuilt" }, "a")
        SearchIndex.resetBlobCache()
    }

    // MARK: - Vision rect -> drawing rect

    func testDrawingRect_mapsVisionBoxIntoDrawingCoordinates() {
        // Rendered rect (the ink bounds, inset) at 2x is a 600 x 300 px image.
        let rendered = CGRect(x: 100, y: 200, width: 300, height: 150)
        // Vision: 10% in from the left, bottom edge half way up, half the
        // width, a fifth of the height; origin bottom-left.
        let box = CGRect(x: 0.1, y: 0.5, width: 0.5, height: 0.2)
        let rect = RecognizedGeometry.drawingRect(normalized: box, renderedRect: rendered, scale: 2)
        // x: 100 + 0.1*300 = 130. Top edge is 1 - 0.7 = 0.3 down: 200 + 0.3*150 = 245.
        XCTAssertEqual(rect.minX, 130, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 245, accuracy: 0.001)
        XCTAssertEqual(rect.width, 150, accuracy: 0.001)
        XCTAssertEqual(rect.height, 30, accuracy: 0.001)
    }

    func testDrawingRect_isIndependentOfRenderScale() {
        let rendered = CGRect(x: -50, y: 10, width: 200, height: 100)
        let box = CGRect(x: 0.25, y: 0.1, width: 0.5, height: 0.3)
        XCTAssertEqual(RecognizedGeometry.drawingRect(normalized: box, renderedRect: rendered, scale: 1),
                       RecognizedGeometry.drawingRect(normalized: box, renderedRect: rendered, scale: 3))
    }

    func testDrawingRect_fullImageBoxIsTheRenderedRect() {
        let rendered = CGRect(x: 12, y: 34, width: 120, height: 80)
        XCTAssertEqual(RecognizedGeometry.drawingRect(normalized: CGRect(x: 0, y: 0, width: 1, height: 1),
                                                      renderedRect: rendered), rendered)
    }

    // MARK: - Line matching

    private let lines = [
        RecognizedLine(text: "Shopping list", rect: CGRect(x: 0, y: 0, width: 100, height: 20)),
        RecognizedLine(text: "Buy Oat Milk", rect: CGRect(x: 0, y: 30, width: 90, height: 20)),
        RecognizedLine(text: "Call the dentist", rect: CGRect(x: 0, y: 60, width: 110, height: 20)),
    ]

    func testLineMatching_isCaseInsensitiveAndPicksTheRightLine() {
        XCTAssertEqual(RecognizedGeometry.line(matching: "oat milk", in: lines)?.rect.minY, 30)
        XCTAssertEqual(RecognizedGeometry.line(matching: "DENTIST", in: lines)?.rect.minY, 60)
        XCTAssertEqual(RecognizedGeometry.line(matching: "  list ", in: lines)?.rect.minY, 0)
    }

    func testLineMatching_phraseAcrossLinesFallsBackToItsFirstFoundWord() {
        // "milk call" is on no single line; "milk" is found first.
        XCTAssertEqual(RecognizedGeometry.line(matching: "milk call", in: lines)?.rect.minY, 30)
    }

    func testLineMatching_noMatchOrEmptyQueryIsNil() {
        XCTAssertNil(RecognizedGeometry.line(matching: "zebra", in: lines))
        XCTAssertNil(RecognizedGeometry.line(matching: "   ", in: lines))
    }

    // MARK: - Lens layout

    func testLensRegion_isCentredAndClamped() {
        let small = SearchLensLayout.region(for: CGRect(x: 100, y: 100, width: 10, height: 10))
        XCTAssertEqual(small.size, CGSize(width: 120, height: 60))
        XCTAssertEqual(small.midX, 105, accuracy: 0.001)
        XCTAssertEqual(small.midY, 105, accuracy: 0.001)

        let big = SearchLensLayout.region(for: CGRect(x: 0, y: 0, width: 900, height: 400))
        XCTAssertEqual(big.size, CGSize(width: 240, height: 120))
    }

    // MARK: - Staleness

    func testNeedsOCR() {
        let old = Date(timeIntervalSince1970: 100)
        let new = Date(timeIntervalSince1970: 200)
        XCTAssertFalse(SearchIndexer.needsOCR(inkModified: nil, ocrUpdatedAt: nil, hasCache: false), "no ink")
        XCTAssertTrue(SearchIndexer.needsOCR(inkModified: old, ocrUpdatedAt: nil, hasCache: false), "never recognized")
        XCTAssertTrue(SearchIndexer.needsOCR(inkModified: old, ocrUpdatedAt: new, hasCache: false), "nil cache retries")
        XCTAssertTrue(SearchIndexer.needsOCR(inkModified: new, ocrUpdatedAt: old, hasCache: true), "ink newer")
        XCTAssertFalse(SearchIndexer.needsOCR(inkModified: old, ocrUpdatedAt: new, hasCache: true), "up to date")
    }

    func testShouldContinue_staleOrCancelledPassStops() {
        XCTAssertTrue(SearchIndexer.shouldContinue(passGeneration: 3, currentGeneration: 3, cancelled: false))
        XCTAssertFalse(SearchIndexer.shouldContinue(passGeneration: 3, currentGeneration: 4, cancelled: false),
                       "a newer pass (or a stop) makes this one stale")
        XCTAssertFalse(SearchIndexer.shouldContinue(passGeneration: 3, currentGeneration: 3, cancelled: true))
    }

    func testIsSettled_skipsInkChangedWithinTheSettleInterval() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertFalse(SearchIndexer.isSettled(inkModified: now.addingTimeInterval(-5), now: now))
        XCTAssertTrue(SearchIndexer.isSettled(inkModified: now.addingTimeInterval(-SearchIndexer.settleInterval), now: now))
    }

    func testNotebookCounter_isMultiWindowSafeAndNeverNegative() {
        let indexer = SearchIndexer.shared
        let base = indexer.openNotebookCount
        indexer.notebookOpened()
        indexer.notebookOpened()
        XCTAssertEqual(indexer.openNotebookCount, base + 2)
        indexer.notebookClosed()
        XCTAssertEqual(indexer.openNotebookCount, base + 1, "one window closing leaves the pass paused")
        indexer.notebookClosed()
        XCTAssertEqual(indexer.openNotebookCount, base)
        if base == 0 {
            indexer.notebookClosed()
            XCTAssertEqual(indexer.openNotebookCount, 0)
        }
    }

    func testPageGap_isOneSecond() {
        XCTAssertEqual(SearchIndexer.pageGap, .seconds(1))
    }

    func testPruneBlobCache_dropsPagesThatAreGone() {
        SearchIndex.resetBlobCache()
        let keep = UUID(), gone = UUID()
        for id in [keep, gone] {
            let key = SearchIndex.BlobKey(pageID: id, modifiedAt: nil, ocrUpdatedAt: nil, contentHash: 0)
            _ = SearchIndex.blob(forKey: key) { "x" }
        }
        SearchIndex.pruneBlobCache(keeping: [keep])
        XCTAssertEqual(SearchIndex.blobCacheCount, 1)
        var rebuilt = false
        _ = SearchIndex.blob(forKey: SearchIndex.BlobKey(pageID: keep, modifiedAt: nil, ocrUpdatedAt: nil, contentHash: 0)) {
            rebuilt = true; return "y"
        }
        XCTAssertFalse(rebuilt)
        SearchIndex.resetBlobCache()
    }

    // MARK: - Lines cache

    func testLinesStore_roundTripsAndRejectsAStaleStamp() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecognizedLinesTests-\(UUID().uuidString)", isDirectory: true)
        let id = UUID()
        let stamp = RecognizedLinesStore.stamp(for: Date(timeIntervalSince1970: 1_700_000_000.1234))
        let saved = [RecognizedLine(text: "hello", rect: CGRect(x: 1, y: 2, width: 30, height: 4))]

        RecognizedLinesStore.save(saved, pageID: id, stamp: stamp, in: dir)
        XCTAssertEqual(RecognizedLinesStore.load(pageID: id, stamp: stamp, in: dir), saved)
        XCTAssertNil(RecognizedLinesStore.load(pageID: id, stamp: stamp + 1, in: dir),
                     "ink changed since: the lines are stale")

        // Overwrite, never remove.
        RecognizedLinesStore.save([], pageID: id, stamp: stamp + 1, in: dir)
        XCTAssertEqual(RecognizedLinesStore.load(pageID: id, stamp: stamp + 1, in: dir), [])
    }
}
