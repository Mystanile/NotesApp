import XCTest
import SwiftData
import UIKit
import PDFKit
@testable import Mystnotes

/// The library's Import, a drop on the library and "Open in Mystnotes":
/// a file becomes a notebook named after it.
@MainActor
final class NotebookImportTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let schema = Schema([Folder.self, Notebook.self, Page.self, TypedTextBlock.self,
                             ImportedDocument.self, Link.self, Sticker.self])
        return ModelContext(try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func makePDF(pages: Int, size: CGSize) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { context in
            for _ in 0..<pages { context.beginPage() }
        }
    }

    func testAPDF_becomesANotebookWithOnePagePerPDFPage() async throws {
        let context = try makeContext()
        let folder = Folder(name: "Physics")
        context.insert(folder)

        let made = await NotebookImport.makeNotebook(
            from: makePDF(pages: 3, size: CGSize(width: 612, height: 792)),
            fileName: "Lecture 4.pdf", in: folder, context: context)
        let notebook = try XCTUnwrap(made)

        XCTAssertEqual(notebook.title, "Lecture 4")
        XCTAssertEqual(notebook.folder?.id, folder.id)
        let pages = (notebook.pages ?? []).sorted { $0.index < $1.index }
        XCTAssertEqual(pages.map(\.index), [0, 1, 2])
        XCTAssertEqual(pages.compactMap { $0.importedDocuments?.first?.pdfPageIndex }, [0, 1, 2])
        XCTAssertEqual(try XCTUnwrap(pages[0].aspectRatio), 612.0 / 792.0, accuracy: 0.001, "the page takes the PDF page's shape")
    }

    func testAnImage_becomesAOnePageNotebook() async throws {
        let context = try makeContext()
        let png = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).pngData { _ in }

        let made = await NotebookImport.makeNotebook(from: png, fileName: "board.png", in: nil, context: context)
        let notebook = try XCTUnwrap(made)

        XCTAssertEqual(notebook.pages?.count, 1)
        XCTAssertEqual(notebook.pages?.first?.importedDocuments?.first?.sourceType, "image")
    }

    func testAFileThatIsNeither_makesNoNotebook() async throws {
        let context = try makeContext()
        let made = await NotebookImport.makeNotebook(from: Data("not a pdf".utf8), fileName: "notes.txt", in: nil, context: context)
        XCTAssertNil(made)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Notebook>()), 0)
    }

    /// A PDF imported while on page 2 of 3 goes in after page 2, and the
    /// last page moves down to make room.
    func testPDFPages_goInAfterTheCurrentPage() throws {
        let context = try makeContext()
        let notebook = Notebook(title: "Notes")
        context.insert(notebook)
        let old = (0..<3).map { Page(index: $0, notebook: notebook) }
        old.forEach(context.insert)
        notebook.pages = old
        let pdf = try XCTUnwrap(PDFDocument(data: makePDF(pages: 2, size: CGSize(width: 612, height: 792))))

        NotebookImport.makeRoom(for: pdf.pageCount, at: 2, in: old)
        NotebookImport.appendPDFPages(pdf, storedAs: "lecture.pdf", to: notebook, startingAt: 2, in: context)

        let order = (notebook.pages ?? []).sorted { $0.index < $1.index }
        XCTAssertEqual(order.map(\.index), [0, 1, 2, 3, 4])
        XCTAssertEqual(order[4].id, old[2].id, "the old last page is now last")
        XCTAssertNotNil(old[2].modifiedAt, "its move is marked so it syncs")
        XCTAssertEqual(order[2].importedDocuments?.first?.pdfPageIndex, 0)
    }
}
