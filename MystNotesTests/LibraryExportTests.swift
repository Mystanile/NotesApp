import XCTest
import SwiftData
import PDFKit
@testable import Mystnotes

/// Everything out, in open formats (invariant 9): Markdown for a
/// notebook's text, and the whole library as a zip of PDFs and Markdown.
final class LibraryExportTests: XCTestCase {

    private static let schema = Schema([
        Folder.self, Notebook.self, Page.self, TypedTextBlock.self,
        ImportedDocument.self, Link.self, Sticker.self
    ])

    @MainActor
    private func library() throws -> (ModelContext, Notebook, Notebook) {
        let container = try ModelContainer(for: Self.schema,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let folder = Folder(name: "Term 1")
        context.insert(folder)
        let physics = Notebook(title: "Physics", folder: folder)
        let loose = Notebook(title: "Ideas")
        context.insert(physics); context.insert(loose)
        for (notebook, count) in [(physics, 2), (loose, 1)] {
            let pages = (0..<count).map { Page(index: $0, notebook: notebook) }
            pages.forEach(context.insert)
            notebook.pages = pages
        }
        let first = try XCTUnwrap(physics.pages?.first { $0.index == 0 })
        first.title = "Kinematics"
        first.recognizedTextCache = "v equals u plus at"
        let block = TypedTextBlock(content: "Newton's second law: F = ma", page: first)
        context.insert(block)
        first.textBlocks = [block]
        try context.save()
        return (context, physics, loose)
    }

    @MainActor
    func testMarkdown_hasTheTitlePagesTextAndHandwriting() throws {
        let (_, physics, _) = try library()
        let markdown = LibraryExport.markdown(for: physics)
        XCTAssertTrue(markdown.hasPrefix("# Physics\n"), markdown)
        XCTAssertTrue(markdown.contains("## Page 1: Kinematics"), markdown)
        XCTAssertTrue(markdown.contains("Newton's second law: F = ma"), markdown)
        XCTAssertTrue(markdown.contains("> v equals u plus at"), markdown)
        XCTAssertTrue(markdown.contains("## Page 2"), markdown)
    }

    @MainActor
    func testLibraryArchive_isAZipOfEveryNotebookAsPDFAndMarkdown() async throws {
        let (_, physics, loose) = try library()
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryExportTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }

        let (folder, zip) = try await LibraryExport.makeArchive(of: [physics, loose], documents: [], in: work)

        let files = try XCTUnwrap(FileManager.default.subpaths(atPath: folder.path)).sorted()
        XCTAssertEqual(files.filter { !$0.hasSuffix("/") && $0.contains(".") },
                       ["Ideas.md", "Ideas.pdf", "Term 1/Physics.md", "Term 1/Physics.pdf"])
        let pdf = try XCTUnwrap(PDFDocument(url: folder.appendingPathComponent("Term 1/Physics.pdf")))
        XCTAssertEqual(pdf.pageCount, 2)

        let zipped = try Data(contentsOf: zip)
        XCTAssertEqual(Array(zipped.prefix(4)), [0x50, 0x4B, 0x03, 0x04], "not a zip")
        XCTAssertGreaterThan(zipped.count, 1000)
    }

    /// The file system ignores case: "Ideas" and "ideas" must be two files,
    /// or the second replaces the first and a notebook is missing from the
    /// export (invariant 9).
    func testLibraryArchive_keepsNotebooksWhoseTitlesDifferOnlyInCase() async throws {
        let (context, _, loose) = try library()
        let twin = Notebook(title: "ideas")
        context.insert(twin)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryExportTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }

        let (folder, _) = try await LibraryExport.makeArchive(of: [loose, twin], documents: [], in: work)

        let markdown = try XCTUnwrap(FileManager.default.subpaths(atPath: folder.path)).filter { $0.hasSuffix(".md") }
        XCTAssertEqual(markdown.count, 2, "both notebooks are in the export: \(markdown)")
    }
}
