import XCTest
import PencilKit
import SwiftData
@testable import Mystnotes

/// M2 tasks 7, 8 (Link This To / picker Nodes) and 13: nodes resolve to
/// the ink they were made around, undo takes them away, the picker lists
/// only nodes, and the Markdown export names them.
@MainActor
final class NodeTests: XCTestCase {
    /// One container for the class (CLAUDE.md gotcha on shared observers).
    private static var container: ModelContainer?
    private var directory: URL!
    private var store: DrawingStore!

    private func makeContext() throws -> ModelContext {
        let container = try Self.container ?? ModelContainer(
            for: Folder.self, Notebook.self, Page.self, TypedTextBlock.self, Sticker.self,
            ImportedDocument.self, Link.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        Self.container = container
        return container.mainContext
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NodeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = DrawingStore.inDirectory(directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeDrawing(strokes count: Int) -> PKDrawing {
        let ink = PKInk(.pen, color: .black)
        return PKDrawing(strokes: (0..<count).map { index in
            let points = (0..<12).map { point in
                PKStrokePoint(location: CGPoint(x: 40 + CGFloat(point) * 8, y: 100 + CGFloat(index) * 60),
                              timeOffset: TimeInterval(point) * 0.008, size: CGSize(width: 3, height: 3),
                              opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            let path = PKStrokePath(controlPoints: points,
                                    creationDate: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)))
            return PKStroke(ink: ink, path: path, randomSeed: UInt32(index + 1))
        })
    }

    private func notebook(_ title: String, pages: Int, in context: ModelContext) -> Notebook {
        let notebook = Notebook(title: title)
        context.insert(notebook)
        let made = (0..<pages).map { Page(index: $0, notebook: notebook) }
        made.forEach(context.insert)
        notebook.pages = made
        return notebook
    }

    // MARK: Make

    func testMakeNode_resolvesToTheSelectedStrokes_inTheStoredRecord() throws {
        let context = try makeContext()
        let book = notebook("Make", pages: 1, in: context)
        let page = try XCTUnwrap(book.pages?.first)
        let drawing = makeDrawing(strokes: 4)
        try store.save(drawing, pageID: page.id)

        // What flushInkAndReadIDs does after the save.
        let map = store.ids.map(for: page.id)
        let selected = [drawing.strokes[1], drawing.strokes[2]]
        let ids = try selected.map { try XCTUnwrap(map.existingID(for: $0)).uuidString }

        let node = Links.makeNode(on: page, strokeIDs: ids, title: "Two lines",
                                  anchor: PKDrawing(strokes: selected).bounds, in: context)
        XCTAssertTrue(Links.isNode(node))

        let wanted = Set((node.strokeIDs ?? []).compactMap(UUID.init(uuidString:)))
        let ink = try XCTUnwrap(store.readRegionInk(pageID: page.id, ids: wanted))
        XCTAssertEqual(ink.strokes.map(\.path.creationDate), selected.map(\.path.creationDate))
        XCTAssertEqual(ink.bounds.minY, PKDrawing(strokes: selected).bounds.minY, accuracy: 6)

        // Erase one of the two and save: the node still resolves (one stroke left).
        try store.save(PKDrawing(strokes: [drawing.strokes[0], drawing.strokes[1], drawing.strokes[3]]), pageID: page.id)
        XCTAssertEqual(store.readRegionInk(pageID: page.id, ids: wanted)?.strokes.count, 1)

        // Erase both: it is gone, and NodeInk says so without touching the node.
        try store.save(PKDrawing(strokes: [drawing.strokes[0], drawing.strokes[3]]), pageID: page.id)
        let probe = NodeProbe(id: node.id, pageID: page.id, strokeIDs: node.strokeIDs ?? [])
        let gone = NodeInk.goneIDs([probe]) { self.store.readRegionInk(pageID: $0, ids: $1) != nil }
        XCTAssertEqual(gone, [node.id])
        XCTAssertNotNil(node.modelContext, "nothing is deleted because the ink is gone")
    }

    func testNodeInk_aNodeWithUnreadableIDs_isNeverGone() {
        let probe = NodeProbe(id: UUID(), pageID: UUID(), strokeIDs: ["not-a-uuid"])
        XCTAssertTrue(NodeInk.goneIDs([probe]) { _, _ in false }.isEmpty)
    }

    func testUndoOfMake_removesTheNode_andRedoPutsItBackUnderTheSameID() throws {
        let context = try makeContext()
        let page = try XCTUnwrap(notebook("Undo", pages: 1, in: context).pages?.first)
        let snapshot = NotebookDetailView.NodeSnapshot(strokeIDs: [UUID().uuidString], title: "Idea",
                                                       anchor: CGRect(x: 10, y: 20, width: 100, height: 40))
        func nodes() throws -> [Link] {
            try context.fetch(FetchDescriptor<Link>()).filter { $0.sourcePageID == page.id && Links.isNode($0) }
        }

        NotebookDetailView.applyNode(snapshot, present: true, on: page, in: context)
        XCTAssertEqual(try nodes().map(\.id), [snapshot.id])
        XCTAssertEqual(try nodes().first?.title, "Idea")

        let before = page.modifiedAt
        NotebookDetailView.applyNode(snapshot, present: false, on: page, in: context)   // the undo
        XCTAssertTrue(try nodes().isEmpty)
        XCTAssertNotNil(page.modifiedAt)
        XCTAssertGreaterThanOrEqual(page.modifiedAt ?? .distantPast, before ?? .distantPast)

        NotebookDetailView.applyNode(snapshot, present: true, on: page, in: context)    // the redo
        XCTAssertEqual(try nodes().map(\.id), [snapshot.id])
    }

    func testSnapshotOfANode_keepsEverythingNeededToRestoreIt() throws {
        let context = try makeContext()
        let page = try XCTUnwrap(notebook("Snap", pages: 1, in: context).pages?.first)
        let node = Links.makeNode(on: page, strokeIDs: ["A", "B"], title: "T",
                                  anchor: CGRect(x: 1, y: 2, width: 30, height: 40), in: context)
        let snapshot = NotebookDetailView.NodeSnapshot(of: node)
        XCTAssertEqual(snapshot.id, node.id)
        XCTAssertEqual(snapshot.strokeIDs, ["A", "B"])
        XCTAssertEqual(snapshot.title, "T")
        XCTAssertEqual(snapshot.anchor, CGRect(x: 1, y: 2, width: 30, height: 40))
    }

    // MARK: Connections list

    func testSplit_capsAtFive_andKeepsTheRest() {
        for (count, shown, hidden) in [(3, 3, 0), (5, 5, 0), (9, 5, 4)] {
            let parts = LinkedFromStrip.split(Array(0..<count))
            XCTAssertEqual(parts.shown.count, shown, "\(count) items")
            XCTAssertEqual(parts.hidden.count, hidden, "\(count) items")
            XCTAssertEqual(parts.shown + parts.hidden, Array(0..<count), "order is kept")
        }
        XCTAssertEqual(LinkedFromStrip.split([1, 2, 3], limit: 0).hidden, [1, 2, 3])
        XCTAssertEqual(LinkedFromStrip.split([1, 2, 3], limit: -2).shown, [])
    }

    // MARK: Picker

    func testPickerNodes_listOnlyNodes_withWhereTheyLive() throws {
        let context = try makeContext()
        let book = notebook("Physics", pages: 2, in: context)
        let pages = (book.pages ?? []).sorted { $0.index < $1.index }
        let node = Links.makeNode(on: pages[1], strokeIDs: [UUID().uuidString], title: "Newton II",
                                  anchor: .init(x: 0, y: 0, width: 10, height: 10), in: context)
        let plain = Link(sourcePageID: pages[0].id, destinationPageID: pages[1].id)
        let mention = Link(sourcePageID: pages[0].id, destinationPageID: pages[1].id)
        mention.kind = "mention"
        let transclusion = Link(sourcePageID: pages[0].id, destinationPageID: pages[1].id)
        transclusion.kind = "transclusion"
        let orphan = Links.makeNode(on: pages[0], strokeIDs: ["A"], title: "Nowhere",
                                    anchor: .init(x: 0, y: 0, width: 10, height: 10), in: context)
        orphan.sourcePageID = UUID()   // its page is not in the library

        let choices = LinkDestinationPickerView.nodeChoices(links: [plain, mention, transclusion, node, orphan],
                                                            notebooks: [book])
        XCTAssertEqual(choices.map(\.id), [node.id])
        XCTAssertEqual(choices.first?.title, "Newton II")
        XCTAssertEqual(choices.first?.subtitle, "Physics · p. 2")
        XCTAssertEqual(choices.first?.pageID, pages[1].id)
    }

    func testLinkToNode_pointsAtTheNodesPage_andRecordsTheNode() throws {
        let context = try makeContext()
        let book = notebook("Pick", pages: 2, in: context)
        let pages = (book.pages ?? []).sorted { $0.index < $1.index }
        let node = Links.makeNode(on: pages[1], strokeIDs: ["A"], title: "N",
                                  anchor: .init(x: 0, y: 0, width: 10, height: 10), in: context)
        let link = Link(sourcePageID: pages[0].id, destinationPageID: pages[0].id)
        link.strokeIDs = ["X"]
        context.insert(link)
        Links.setDestination(link, toNode: node, in: context)
        XCTAssertEqual(link.destinationPageID, pages[1].id)
        XCTAssertEqual(link.destinationID, node.id.uuidString)
        XCTAssertEqual(link.destinationKind, "region")
        XCTAssertEqual(link.strokeIDs, ["X"], "the source anchor's strokes are kept")
        XCTAssertFalse(Links.isUnfinished(link))
    }

    // MARK: Export

    func testMarkdown_namesTheNodesOnEachPage_inReadingOrder() throws {
        let context = try makeContext()
        let book = notebook("Export", pages: 2, in: context)
        let pages = (book.pages ?? []).sorted { $0.index < $1.index }
        Links.makeNode(on: pages[0], strokeIDs: ["A"], title: "Lower", anchor: .init(x: 0, y: 200, width: 10, height: 10), in: context)
        Links.makeNode(on: pages[0], strokeIDs: ["B"], title: "Upper", anchor: .init(x: 0, y: 10, width: 10, height: 10), in: context)
        let plain = Link(sourcePageID: pages[1].id, destinationPageID: pages[0].id)
        context.insert(plain)
        try context.save()

        let markdown = LibraryExport.markdown(for: book)
        XCTAssertTrue(markdown.contains("Nodes: Upper, Lower"), markdown)
        XCTAssertEqual(markdown.components(separatedBy: "Nodes:").count - 1, 1, "page 2 has no nodes line")
    }
}
