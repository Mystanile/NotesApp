import Foundation
import PDFKit

/// Builds the plain-text blob that a page is searched against. A page's text
/// can come from three sources: typed `TypedTextBlock`s (stored on the model),
/// recognized handwriting (Vision OCR, cached in `recognizedTextCache`), and
/// the text layer of an imported PDF (extracted from the file on demand).
enum SearchIndex {
    /// The text of one page within an imported PDF, extracted lazily and cached.
    /// Synchronous: callers on the main thread should prefer
    /// `PDFTextExtractor.lookup` and extract off-main (the Study panel does).
    static func pdfPageText(fileRef: String, pageIndex: Int) -> String? {
        PDFTextExtractor.text(fileRef: fileRef, pageIndex: pageIndex)
    }

    // MARK: - Blob cache

    /// What a cached blob was built from. A page's blob is rebuilt only when
    /// one of these changes: its edit clock, its OCR clock, or (for edits
    /// that don't bump the clock - a title, a tag, a typed block) a hash of
    /// that text.
    struct BlobKey: Hashable {
        let pageID: UUID
        let modifiedAt: Date?
        let ocrUpdatedAt: Date?
        let contentHash: Int
    }

    private static var blobCache: [UUID: (key: BlobKey, blob: String)] = [:]

    /// The blob for `key`, building it with `build` only when the cache holds
    /// no blob for exactly this key.
    static func blob(forKey key: BlobKey, build: () -> String) -> String {
        if let hit = blobCache[key.pageID], hit.key == key { return hit.blob }
        let blob = build()
        blobCache[key.pageID] = (key, blob)
        return blob
    }

    static func resetBlobCache() { blobCache.removeAll() }

    /// Drops blobs for pages that no longer exist (deleted, synced away).
    static func pruneBlobCache(keeping pageIDs: Set<UUID>) {
        for id in blobCache.keys where !pageIDs.contains(id) { blobCache[id] = nil }
    }

    static var blobCacheCount: Int { blobCache.count }

    /// `searchableText`, memoized per page so typing a query doesn't rebuild
    /// and re-lowercase every page's text on every keystroke.
    static func cachedSearchableText(for page: Page, importedDocuments: [ImportedDocument],
                                     imageText: ImageTextCache = .shared) -> String {
        var hasher = Hasher()
        hasher.combine(page.title)
        hasher.combine(page.tags ?? [])
        for block in page.textBlocks ?? [] { hasher.combine(block.content) }
        // The recognized text changes without `modifiedAt` moving; its size
        // (O(1) on UTF-8) catches a re-read that lands on the same date.
        hasher.combine(page.recognizedTextCache?.utf8.count ?? -1)
        for doc in importedDocuments { hasher.combine(doc.fileRef); hasher.combine(doc.pdfPageIndex) }
        // Photo text arrives later, from the background pass, without the
        // page's clocks moving: key on which photos have text and how much.
        for doc in importedDocuments where isPhoto(doc) {
            hasher.combine(imageText.text(forFileRef: doc.fileRef)?.utf8.count ?? -1)
        }
        let key = BlobKey(pageID: page.id, modifiedAt: page.modifiedAt,
                          ocrUpdatedAt: page.ocrUpdatedAt, contentHash: hasher.finalize())
        return blob(forKey: key) { searchableText(for: page, importedDocuments: importedDocuments, imageText: imageText) }
    }

    /// The combined, lowercased searchable text for a page. `importedDocuments`
    /// are the page's `ImportedDocument`s (the model has no inverse
    /// relationship from `Page` to `ImportedDocument`, so callers resolve
    /// them) - every PDF page on it contributes its text.
    static func searchableText(for page: Page, importedDocuments: [ImportedDocument],
                               imageText: ImageTextCache = .shared) -> String {
        var parts: [String] = []

        if let title = page.title, !title.isEmpty {
            parts.append(title)
        }
        if let recognized = page.recognizedTextCache, !recognized.isEmpty {
            parts.append(recognized)
        }
        // Tags too, so a smart folder can be "every page tagged exam".
        parts.append(contentsOf: page.tags ?? [])
        if let blocks = page.textBlocks, !blocks.isEmpty {
            parts.append(contentsOf: blocks.compactMap { $0.content.isEmpty ? nil : $0.content })
        }
        for doc in importedDocuments where doc.sourceType == "pdf" && !doc.fileRef.isEmpty {
            if let pdfText = pdfPageText(fileRef: doc.fileRef, pageIndex: doc.pdfPageIndex),
               !pdfText.isEmpty {
                parts.append(pdfText)
            }
        }

        parts.append(contentsOf: photoTexts(in: importedDocuments, imageText: imageText))

        return parts.joined(separator: "\n").lowercased()
    }

    // MARK: - Photos

    /// An imported picture (not a PDF, whose text layer is read directly).
    static func isPhoto(_ doc: ImportedDocument) -> Bool {
        isPhoto(sourceType: doc.sourceType, fileRef: doc.fileRef)
    }

    nonisolated static func isPhoto(sourceType: String, fileRef: String) -> Bool {
        sourceType == "image" && !fileRef.isEmpty && !fileRef.lowercased().hasSuffix(".pdf")
    }

    /// The recognized text of each photo on the page that has been read.
    static func photoTexts(in documents: [ImportedDocument], imageText: ImageTextCache = .shared) -> [String] {
        documents.compactMap { doc in
            guard isPhoto(doc), let text = imageText.text(forFileRef: doc.fileRef), !text.isEmpty else { return nil }
            return text
        }
    }

    /// What the result row's snippet should say about its source: "in a
    /// photo" when the (lowercased) `needles` match only text read from a
    /// photo, nil otherwise.
    static func photoSnippetLabel(for page: Page, importedDocuments: [ImportedDocument], needles: String,
                                  imageText: ImageTextCache = .shared) -> String? {
        guard !needles.isEmpty,
              photoTexts(in: importedDocuments, imageText: imageText)
                .contains(where: { $0.lowercased().contains(needles) }) else { return nil }
        // Without the photos, does the page still match?
        let withoutPhotos = searchableText(for: page, importedDocuments: importedDocuments.filter { !isPhoto($0) },
                                           imageText: imageText)
        return withoutPhotos.contains(needles) ? nil : "in a photo"
    }

    /// `snippet` prefixed with its source label, if it has one.
    static func labeledSnippet(_ snippet: String, label: String?) -> String {
        guard let label else { return snippet }
        return snippet.isEmpty ? label : "\(label): \(snippet)"
    }
}
/// Memoized PDF text so a (potentially large) PDF is not re-read on every
/// keystroke or panel refresh. Safe to call from any thread: the tables are
/// guarded by a lock and the PDF is parsed outside it. A file that fails to
/// open is remembered, so a broken PDF is not retried on every refresh.
nonisolated enum PDFTextExtractor {
    enum Lookup: Equatable, Sendable {
        case hit(String)
        /// Known to have no text for this page (unreadable file, or page out of range).
        case failed
        /// Not read yet.
        case unknown
    }

    private static let lock = NSLock()
    /// Key: "<fileRef>:<pageIndex>".
    nonisolated(unsafe) private static var pages: [String: String] = [:]
    nonisolated(unsafe) private static var loadedFiles: Set<String> = []
    nonisolated(unsafe) private static var failedFiles: Set<String> = []

    /// What the cache knows, without touching the disk.
    static func lookup(fileRef: String, pageIndex: Int) -> Lookup {
        lock.lock(); defer { lock.unlock() }
        if let text = pages["\(fileRef):\(pageIndex)"] { return .hit(text) }
        if loadedFiles.contains(fileRef) || failedFiles.contains(fileRef) { return .failed }
        return .unknown
    }

    /// The page's text, reading the whole file once if it is not cached.
    static func text(fileRef: String, pageIndex: Int) -> String? {
        switch lookup(fileRef: fileRef, pageIndex: pageIndex) {
        case .hit(let text): return text
        case .failed: return nil
        case .unknown: break
        }
        guard let document = PDFDocument(url: FileStore.url(for: fileRef)) else {
            lock.lock(); failedFiles.insert(fileRef); lock.unlock()
            return nil
        }
        var texts: [String] = []
        for i in 0..<document.pageCount { texts.append(document.page(at: i)?.string ?? "") }
        lock.lock()
        for (i, text) in texts.enumerated() { pages["\(fileRef):\(i)"] = text }
        loadedFiles.insert(fileRef)
        lock.unlock()
        return texts.indices.contains(pageIndex) ? texts[pageIndex] : nil
    }
}
