import XCTest
import SwiftData
import PencilKit
@testable import Mystnotes

/// The real deletion a pending Delete Page commits to. Pins what
/// `NotebookDetailView.deletePage` did before it moved (Sept 25, 2026).
final class PageDeletionTests: XCTestCase {

    private static let schema = Schema([
        Folder.self, Notebook.self, Page.self, TypedTextBlock.self,
        ImportedDocument.self, Link.self, Sticker.self
    ])

    @MainActor
    func testDelete_removesThePage_trashesItsInk_andLeavesATombstone() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PageDeletionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DrawingStore.inDirectory(directory)
        let tombstones = InMemorySyncStateStore()

        let container = try ModelContainer(for: Self.schema,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let notebook = Notebook(title: "N")
        context.insert(notebook)
        let pages = (0..<3).map { Page(index: $0, notebook: notebook) }
        pages.forEach(context.insert)
        notebook.pages = pages
        let doomed = pages[1]

        let point = PKStrokePoint(location: CGPoint(x: 10, y: 10), timeOffset: 0, size: CGSize(width: 3, height: 3),
                                  opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        let stroke = PKStroke(ink: PKInk(.pen, color: .black),
                              path: PKStrokePath(controlPoints: [point, point], creationDate: Date()))
        try store.save(PKDrawing(strokes: [stroke]), pageID: doomed.id)
        let inkFile = directory.appendingPathComponent(DrawingStore.fileName(for: doomed.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inkFile.path))

        let own = ImportedDocument(sourceType: "image", fileRef: "only-here.png", pdfPageIndex: 0, page: doomed)
        let shared = ImportedDocument(sourceType: "pdf", fileRef: "book.pdf", pdfPageIndex: 1, page: doomed)
        let sharedElsewhere = ImportedDocument(sourceType: "pdf", fileRef: "book.pdf", pdfPageIndex: 0, page: pages[0])
        [own, shared, sharedElsewhere].forEach(context.insert)
        for name in ["only-here.png", "book.pdf"] {
            try Data([1]).write(to: directory.appendingPathComponent(name))
        }
        let link = Link(sourcePageID: pages[0].id, destinationPageID: doomed.id)
        context.insert(link)
        try context.save()

        PageDeletion.delete(doomed, from: notebook, in: context, drawingStore: store, tombstones: tombstones)
        try context.save()

        let left = try context.fetch(FetchDescriptor<Page>()).sorted { $0.index < $1.index }
        XCTAssertEqual(left.map(\.id), [pages[0].id, pages[2].id])
        XCTAssertEqual(left.map(\.index), [0, 1], "remaining pages re-sequenced")
        XCTAssertEqual(try context.fetch(FetchDescriptor<ImportedDocument>()).map(\.fileRef), ["book.pdf"])
        XCTAssertTrue(try context.fetch(FetchDescriptor<Link>()).isEmpty)

        XCTAssertFalse(FileManager.default.fileExists(atPath: inkFile.path), "ink not moved out")
        let trashed = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("trash").path)
        XCTAssertTrue(trashed.contains { $0.hasPrefix(doomed.id.uuidString) }, "ink not in trash: \(trashed)")
        XCTAssertTrue(trashed.contains { $0.hasPrefix("only-here") }, "the page's own photo not in trash")
        XCTAssertFalse(trashed.contains { $0.hasPrefix("book") }, "a file another page uses was trashed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("book.pdf").path))

        XCTAssertTrue(SyncTombstones.load(from: tombstones).contains { $0.kind == .page && $0.id == doomed.id })
    }
}
