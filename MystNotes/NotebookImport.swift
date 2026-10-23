import Foundation
import PDFKit
import SwiftData

/// Turns imported files into pages. A notebook's Import > As New Pages,
/// the library's Import, a file dropped on the library, and "Open in
/// Mystnotes" from another app all build pages through here, so a PDF
/// becomes the same pages whichever way it arrived.
enum NotebookImport {

    /// Appends one page per PDF page to `notebook`, starting at `index`,
    /// and returns how many it added.
    ///
    /// Each page takes that PDF page's own proportions and is filled edge
    /// to edge, so an engineering-paper template arrives as a real portrait
    /// sheet rather than a letterboxed picture on a differently-shaped
    /// page. Page shapes are per-page, so a PDF that mixes portrait and
    /// landscape imports correctly too.
    @discardableResult
    static func appendPDFPages(_ document: PDFDocument, storedAs fileRef: String, to notebook: Notebook,
                               startingAt index: Int, in context: ModelContext) -> Int {
        for pdfPageIndex in 0..<document.pageCount {
            let page = Page(index: index + pdfPageIndex, type: "paged", template: "blank", notebook: notebook)
            page.backgroundRef = fileRef
            context.insert(page)

            let importedDoc = ImportedDocument(sourceType: "pdf", fileRef: fileRef, pdfPageIndex: pdfPageIndex, page: page)
            if let aspect = ImportedArtwork.aspectRatio(fileRef: fileRef, pdfPageIndex: pdfPageIndex) {
                page.aspectRatio = aspect
                importedDoc.frameX = 0
                importedDoc.frameY = 0
                importedDoc.frameWidth = 1
                importedDoc.frameHeight = 1
            }
            context.insert(importedDoc)
            append(page, to: notebook)
        }
        notebook.modifiedAt = Date()
        return document.pageCount
    }

    /// Appends one page with the image as its background, and returns it.
    @discardableResult
    static func appendImagePage(storedAs fileRef: String, to notebook: Notebook, at index: Int,
                                in context: ModelContext) -> Page {
        let page = Page(index: index, type: "paged", template: "blank", notebook: notebook)
        page.backgroundRef = fileRef
        context.insert(page)
        context.insert(ImportedDocument(sourceType: "image", fileRef: fileRef, pdfPageIndex: 0, page: page))
        append(page, to: notebook)
        notebook.modifiedAt = Date()
        return page
    }

    /// A new notebook in `folder`, made from a PDF (one page per PDF page)
    /// or an image (one page). The notebook is named after the file.
    /// Returns nil, and writes nothing to the library, when the file is
    /// neither.
    static func makeNotebook(from data: Data, fileName: String, in folder: Folder?,
                             context: ModelContext) async -> Notebook? {
        guard let kind = ImportedFileType.of(data) else { return nil }
        let document = kind.isPDF ? PDFDocument(data: data) : nil
        if kind.isPDF && (document?.pageCount ?? 0) == 0 { return nil }
        guard let fileRef = await NotebookDetailView.writeImport(data, extension: kind.fileExtension) else { return nil }

        let title = (fileName as NSString).deletingPathExtension
        let notebook = Notebook(title: title.isEmpty ? "Imported" : title, folder: folder)
        context.insert(notebook)
        if let document {
            appendPDFPages(document, storedAs: fileRef, to: notebook, startingAt: 0, in: context)
        } else {
            appendImagePage(storedAs: fileRef, to: notebook, at: 0, in: context)
        }
        do {
            try context.save()
        } catch {
            AppLog.note("import", "Failed to save the imported notebook: \(error)")
        }
        return notebook
    }

    /// Reads a file the user picked or another app handed over, holding
    /// its security scope only while reading.
    /// Off the main thread: a lecture PDF can be tens of megabytes.
    nonisolated static func readFile(at url: URL) async -> Data? {
        await Task.detached(priority: .userInitiated) { () -> Data? in
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            return try? Data(contentsOf: url)
        }.value
    }

    /// Moves every page at `index` or after down by `count`, so `count`
    /// new pages can go in at `index`. Each moved page is marked modified,
    /// as a reorder does, so its new place syncs.
    static func makeRoom(for count: Int, at index: Int, in sortedPages: [Page]) {
        guard count > 0 else { return }
        for page in sortedPages where page.index >= index {
            page.index += count
            page.markModified()
        }
    }

    private static func append(_ page: Page, to notebook: Notebook) {
        if notebook.pages == nil {
            notebook.pages = [page]
        } else {
            notebook.pages?.append(page)
        }
    }
}
