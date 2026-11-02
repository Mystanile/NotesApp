import XCTest
import SwiftData
import PencilKit
@testable import Mystnotes

/// Go to Page maths, the page indicator text, Duplicate Page and the laser
/// trail (Nov 2, 2026).
final class PageNavigationExtrasTests: XCTestCase {

    private static let schema = Schema([
        Folder.self, Notebook.self, Page.self, TypedTextBlock.self,
        ImportedDocument.self, Link.self, Sticker.self
    ])

    func testGoToPage_clampsToTheNotebook() {
        XCTAssertEqual(PageNavigation.index(forEntered: "3", pageCount: 10), 2)
        XCTAssertEqual(PageNavigation.index(forEntered: " 1 ", pageCount: 10), 0)
        XCTAssertEqual(PageNavigation.index(forEntered: "0", pageCount: 10), 0)
        XCTAssertEqual(PageNavigation.index(forEntered: "-4", pageCount: 10), 0)
        XCTAssertEqual(PageNavigation.index(forEntered: "99", pageCount: 10), 9)
        XCTAssertNil(PageNavigation.index(forEntered: "", pageCount: 10))
        XCTAssertNil(PageNavigation.index(forEntered: "abc", pageCount: 10))
        XCTAssertNil(PageNavigation.index(forEntered: "2", pageCount: 0))
    }

    func testIndicatorText() {
        XCTAssertEqual(PageNavigation.indicatorText(index: 2, count: 20), "3 / 20")
        XCTAssertEqual(PageNavigation.indicatorText(index: 0, count: 1), "1 / 1")
    }

    func testLaserTrail_fadesAndDropsOldPoints() {
        XCTAssertEqual(LaserTrail.opacity(age: 0), 1, accuracy: 0.0001)
        XCTAssertEqual(LaserTrail.opacity(age: LaserTrail.lifetime / 2), 0.5, accuracy: 0.0001)
        XCTAssertEqual(LaserTrail.opacity(age: 5), 0)
        var trail = LaserTrail()
        trail.add(.zero, at: 0)
        trail.add(CGPoint(x: 5, y: 5), at: 0.1)
        trail.endStroke()
        trail.add(CGPoint(x: 9, y: 9), at: 2)
        XCTAssertEqual(trail.points.count, 1)
        XCTAssertTrue(trail.points[0].startsStroke)
        trail.removeAll()
        XCTAssertTrue(trail.points.isEmpty)
    }

    @MainActor
    func testDuplicate_insertsAfterTheSource_renumbers_andCopiesElementsAndInk() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PageNavigationExtrasTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DrawingStore.inDirectory(directory)

        let container = try ModelContainer(for: Self.schema,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let notebook = Notebook(title: "N")
        context.insert(notebook)
        let pages = (0..<3).map { Page(index: $0, notebook: notebook) }
        pages.forEach(context.insert)
        notebook.pages = pages
        let source = pages[1]
        source.title = "Source"

        let point = PKStrokePoint(location: CGPoint(x: 10, y: 10), timeOffset: 0, size: CGSize(width: 3, height: 3),
                                  opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        let stroke = PKStroke(ink: PKInk(.pen, color: .black),
                              path: PKStrokePath(controlPoints: [point, point], creationDate: Date()))
        try store.save(PKDrawing(strokes: [stroke]), pageID: source.id)

        let block = TypedTextBlock(content: "hello", page: source)
        context.insert(block)
        let sticker = Sticker(assetRef: "star", page: source)
        context.insert(sticker)
        let doc = ImportedDocument(sourceType: "pdf", fileRef: "book.pdf", pdfPageIndex: 4, page: source)
        context.insert(doc)
        try context.save()

        let copy = await PageDuplication.duplicate(source, in: notebook, documents: [doc],
                                                   context: context, store: store)
        try context.save()

        let ordered = (notebook.pages ?? []).sorted { $0.index < $1.index }
        XCTAssertEqual(ordered.count, 4)
        XCTAssertEqual(ordered.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(ordered[2].id, copy.id)
        XCTAssertEqual(ordered[1].id, source.id)
        XCTAssertEqual(ordered[3].id, pages[2].id)
        XCTAssertEqual(copy.title, "Source")
        XCTAssertNotNil(copy.modifiedAt)
        XCTAssertNotNil(pages[2].modifiedAt)
        XCTAssertEqual(copy.textBlocks?.first?.content, "hello")
        XCTAssertEqual(copy.stickers?.first?.assetRef, "star")
        let docs = try context.fetch(FetchDescriptor<ImportedDocument>()).filter { $0.page?.id == copy.id }
        XCTAssertEqual(docs.first?.fileRef, "book.pdf")
        XCTAssertEqual(docs.first?.pdfPageIndex, 4)
        // The source keeps its own elements.
        XCTAssertEqual(source.textBlocks?.count, 1)

        let loaded = store.load(pageID: copy.id)
        XCTAssertEqual(loaded?.strokes.count, 1)
        XCTAssertNotNil(copy.drawingFileRef)
    }
}
