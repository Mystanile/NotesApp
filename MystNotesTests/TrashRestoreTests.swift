import XCTest
import SwiftData
import PencilKit
@testable import Mystnotes

/// Getting a page back out of the trash (Settings > Trash > Restore).
final class TrashRestoreTests: XCTestCase {

    private static let schema = Schema([
        Folder.self, Notebook.self, Page.self, TypedTextBlock.self,
        ImportedDocument.self, Link.self, Sticker.self
    ])

    @MainActor
    func testTrashedInk_comesBackAsANewPage_andStaysInTheTrash() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TrashRestore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DrawingStore.inDirectory(directory)

        let gone = UUID()
        let point = { (x: CGFloat) in PKStrokePoint(location: CGPoint(x: x, y: 10), timeOffset: 0, size: CGSize(width: 3, height: 3),
                                                     opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2) }
        let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: [point(0), point(80)], creationDate: Date()))
        try store.save(PKDrawing(strokes: [stroke, stroke]), pageID: gone)
        store.trashDrawing(forPageID: gone)

        let items = TrashRestore.restorableInk(in: [directory.appendingPathComponent("trash")])
        XCTAssertEqual(items.count, 1, "one trashed page (its render cache isn't a separate item)")

        let container = try ModelContainer(for: Self.schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let page = try TrashRestore.restore(items[0], in: context, store: store)
        try context.save()

        XCTAssertNotEqual(page.id, gone, "a restored page is a new page")
        XCTAssertEqual(page.notebook?.title, TrashRestore.notebookTitle)
        XCTAssertEqual(store.load(pageID: page.id)?.strokes.count, 2, "the ink came back")
        XCTAssertTrue(FileManager.default.fileExists(atPath: items[0].url.path), "the trashed copy stays until it expires")

        // A second restore lands in the same Recovered Pages notebook.
        let again = try TrashRestore.restore(items[0], in: context, store: store)
        XCTAssertEqual(again.notebook?.id, page.notebook?.id)
        XCTAssertEqual(again.index, 1)
    }
}
