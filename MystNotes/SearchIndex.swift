import Foundation
import PDFKit

/// Builds the plain-text blob that a page is searched against. A page's text
/// can come from three sources: typed `TypedTextBlock`s (stored on the model),
/// recognized handwriting (Vision OCR, cached in `recognizedTextCache`), and
/// the text layer of an imported PDF (extracted from the file on demand).
enum SearchIndex {
    /// Memoized PDF text so we don't re-read a (potentially large) PDF file on
    /// every keystroke. Key: "<fileRef>:<pageIndex>".
    private static var pdfTextCache: [String: String] = [:]

    /// The text of one page within an imported PDF, extracted lazily and cached.
    static func pdfPageText(fileRef: String, pageIndex: Int) -> String? {
        let key = "\(fileRef):\(pageIndex)"
        if let cached = pdfTextCache[key] { return cached }

        let url = FileStore.url(for: fileRef)
        guard let document = PDFDocument(url: url) else { return nil }

        // Extract every page's text once, then cache per-page entries.
        var texts: [String] = []
        for i in 0..<document.pageCount {
            texts.append(document.page(at: i)?.string ?? "")
        }
        for (i, text) in texts.enumerated() {
            pdfTextCache["\(fileRef):\(i)"] = text
        }
        return texts.indices.contains(pageIndex) ? texts[pageIndex] : nil
    }

    /// The combined, lowercased searchable text for a page. `importedDocuments`
    /// are the page's `ImportedDocument`s (the model has no inverse
    /// relationship from `Page` to `ImportedDocument`, so callers resolve
    /// them) - every PDF page on it contributes its text.
    static func searchableText(for page: Page, importedDocuments: [ImportedDocument]) -> String {
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

        return parts.joined(separator: "\n").lowercased()
    }
}