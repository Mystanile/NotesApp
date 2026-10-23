import SwiftUI
import SwiftData
#if targetEnvironment(macCatalyst) || canImport(UIKit)
import PencilKit
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import PDFKit
import PhotosUI

extension NotebookDetailView {
    // MARK: - Export

    #if targetEnvironment(macCatalyst) || canImport(UIKit)
    /// The page's artwork stack, bottom first, as values for a renderer.
    func artwork(for page: Page) -> [ArtworkLayer] {
        ArtworkLayer.stack(for: page, stacked: documentsByPageID)
    }

    /// The page's artwork stack as the documents themselves, for editing.
    func documents(on page: Page) -> [ImportedDocument] {
        ImportedDocument.stack(on: page.id, in: allImportedDocuments)
    }

    /// `ImportedDocument` has no inverse relationship from `Page`, so the
    /// mapping is built here once per update rather than scanned once per
    /// page - the page strip asks for every page in the notebook.
    var documentsByPageID: [UUID: [ImportedDocument]] {
        ImportedDocument.stacksByPage(allImportedDocuments)
    }

    func exportPageToPhotos() {
        guard let page = currentPage else { return }
        // Flush pending ink first so the export matches what's on screen.
        saveCurrentPage(blocking: true)
        let image = PageRenderer.image(for: page, artwork: artwork(for: page))
        Task {
            do {
                try await PageRenderer.saveToPhotos(image)
                exportMessage = "Saved this page to your photo library."
            } catch {
                exportMessage = error.localizedDescription
            }
        }
    }

    func exportPageAsPDF() {
        guard let page = currentPage else { return }
        saveCurrentPage(blocking: true)
        let data = PageRenderer.pdfData(for: [(page: page, artwork: artwork(for: page))])
        presentPDF(data, named: "\(notebook.title) - Page \(currentPageIndex + 1)")
    }

    func exportNotebookAsPDF() {
        saveCurrentPage(blocking: true)
        let entries = sortedPages.map { (page: $0, artwork: artwork(for: $0)) }
        guard !entries.isEmpty else { return }
        let data = PageRenderer.pdfData(for: entries)
        presentPDF(data, named: notebook.title)
    }

    func presentPDF(_ data: Data, named name: String) {
        do {
            pdfExportURL = PDFExport(url: try PageRenderer.writeTemporaryPDF(data, named: name))
        } catch {
            exportMessage = "Couldn't create the PDF: \(error.localizedDescription)"
        }
    }
    #endif
}
