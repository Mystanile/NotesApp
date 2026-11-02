import XCTest
@testable import Mystnotes

/// Photo search without Vision: the cache's round trip and keying, the blob
/// picking up photo text, and the indexer's skip decision.
@MainActor
final class ImageTextTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ImageTextTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func entry(_ ref: String, _ text: String) -> ImageTextEntry {
        ImageTextEntry(fileRef: ref, text: text,
                       lines: [ImageTextLine(text: text, x: 0.1, y: 0.2, width: 0.5, height: 0.05)])
    }

    func testCache_roundTripsAcrossInstances() {
        let a = ImageTextCache(directory: directory)
        XCTAssertNil(a.entry(forFileRef: "photo.jpg"))
        XCTAssertTrue(a.store(entry("photo.jpg", "Whiteboard notes")))
        let b = ImageTextCache(directory: directory)   // cold memo: reads the file
        XCTAssertEqual(b.entry(forFileRef: "photo.jpg"), entry("photo.jpg", "Whiteboard notes"))
        XCTAssertEqual(b.text(forFileRef: "photo.jpg"), "Whiteboard notes")
    }

    func testCache_isKeyedByFileName_andOverwritesInPlace() {
        let cache = ImageTextCache(directory: directory)
        cache.store(entry("a.jpg", "alpha"))
        cache.store(entry("b.jpg", "beta"))
        XCTAssertNotEqual(ImageTextCache.key(forFileRef: "a.jpg"), ImageTextCache.key(forFileRef: "b.jpg"))
        XCTAssertEqual(ImageTextCache.key(forFileRef: "a.jpg"), ImageTextCache.key(forFileRef: "a.jpg"))
        XCTAssertEqual(cache.text(forFileRef: "a.jpg"), "alpha")
        XCTAssertEqual(cache.text(forFileRef: "b.jpg"), "beta")

        cache.store(entry("a.jpg", "alpha two"))
        XCTAssertEqual(cache.text(forFileRef: "a.jpg"), "alpha two")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertEqual(files.count, 2, "overwrite, not a second file")
    }

    func testCache_emptyTextIsAnEntry_andAMissIsRememberedUntilStored() {
        let cache = ImageTextCache(directory: directory)
        XCTAssertFalse(cache.hasEntry(forFileRef: "x.png"))
        cache.store(entry("x.png", ""))
        XCTAssertTrue(cache.hasEntry(forFileRef: "x.png"))
    }

    func testBlob_includesPhotoText_andKeyChangesWhenItArrives() throws {
        SearchIndex.resetBlobCache()
        let cache = ImageTextCache(directory: directory)
        let page = Page()
        let photo = ImportedDocument(sourceType: "image", fileRef: "menu.jpg")
        let pdf = ImportedDocument(sourceType: "pdf", fileRef: "doc.pdf")

        XCTAssertFalse(SearchIndex.cachedSearchableText(for: page, importedDocuments: [photo], imageText: cache)
            .contains("espresso"))
        cache.store(entry("menu.jpg", "Espresso 3.50"))
        XCTAssertTrue(SearchIndex.cachedSearchableText(for: page, importedDocuments: [photo], imageText: cache)
            .contains("espresso 3.50"), "the cached blob must not hide text that arrived later")

        cache.store(entry("doc.pdf", "should be ignored"))
        XCTAssertFalse(SearchIndex.searchableText(for: page, importedDocuments: [pdf], imageText: cache)
            .contains("ignored"))
    }

    func testSnippetLabel_onlyWhenThePhotoIsTheSource() {
        let cache = ImageTextCache(directory: directory)
        cache.store(entry("menu.jpg", "Espresso"))
        let page = Page()
        page.title = "Cafe"
        let photo = ImportedDocument(sourceType: "image", fileRef: "menu.jpg")
        XCTAssertEqual(SearchIndex.photoSnippetLabel(for: page, importedDocuments: [photo], needles: "espresso",
                                                     imageText: cache), "in a photo")
        XCTAssertNil(SearchIndex.photoSnippetLabel(for: page, importedDocuments: [photo], needles: "cafe",
                                                   imageText: cache))
        XCTAssertEqual(SearchIndex.labeledSnippet("…espresso…", label: "in a photo"), "in a photo: …espresso…")
    }

    func testIndexer_skipsCachedFiles_pdfsAndDuplicates() {
        let cached: Set<String> = ["done.jpg"]
        let todo = SearchIndexer.photosNeedingText(
            fileRefs: ["done.jpg", "new.jpg", "new.jpg", "", "scan.pdf", "other.png"],
            hasEntry: { cached.contains($0) })
        XCTAssertEqual(todo, ["new.jpg", "other.png"])
    }
}
