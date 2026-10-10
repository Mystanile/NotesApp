import XCTest
import SwiftData
import SwiftUI
@testable import Mystnotes

final class NotebookGraphTests: XCTestCase {
    @MainActor private static var container: ModelContainer?

    func testLayout_isDeterministic_insideSize_withDistinctPoints() {
        let ids = (0..<7).map { _ in UUID() }
        let size = CGSize(width: 600, height: 500)
        let a = NotebookGraphView.layout(pageIDs: ids, edges: [], in: size)
        let b = NotebookGraphView.layout(pageIDs: ids, edges: [], in: size)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 7)
        XCTAssertEqual(Set(a.values.map { "\($0.x),\($0.y)" }).count, 7)
        for p in a.values { XCTAssertTrue(CGRect(origin: .zero, size: size).contains(p)) }
    }

    func testEdges_dropSelfLinksAndForeignPages() {
        let nb = Notebook(title: "N")
        let pages = (0..<3).map { Page(index: $0, notebook: nb) }
        let links = [
            Link(sourcePageID: pages[0].id, destinationPageID: pages[1].id),
            Link(sourcePageID: pages[0].id, destinationPageID: pages[1].id),
            Link(sourcePageID: pages[2].id, destinationPageID: pages[2].id),
            Link(sourcePageID: pages[1].id, destinationPageID: UUID()),
            Link(sourcePageID: UUID(), destinationPageID: pages[0].id),
        ]
        let e = NotebookGraphView.edges(pages: pages, links: links)
        XCTAssertEqual(e.count, 1)
        XCTAssertEqual(e[0].0, pages[0].id)
        XCTAssertEqual(e[0].1, pages[1].id)
    }

    @MainActor
    func testRender_writesPicture() async throws {
        let container = try Self.container ?? ModelContainer(for: Folder.self, Notebook.self, Page.self, TypedTextBlock.self,
                                                             Sticker.self, ImportedDocument.self, Link.self,
                                                             configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        Self.container = container
        let context = container.mainContext
        let nb = Notebook(title: "Map")
        context.insert(nb)
        let pages = (0..<6).map { Page(index: $0, notebook: nb) }
        pages[1].title = "Worked example"
        pages.forEach { context.insert($0) }
        nb.pages = pages
        let links = [(0, 1), (1, 3), (3, 0), (4, 1)].map { Link(sourcePageID: pages[$0.0].id, destinationPageID: pages[$0.1].id) }
        links.forEach { context.insert($0) }
        try context.save()

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 700, height: 600)
        window.rootViewController = UIHostingController(rootView: NotebookGraphView(pages: pages, links: links) { _ in })
        window.makeKeyAndVisible()
        defer { window.rootViewController = nil; window.isHidden = true }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("graph.png")
        try XCTUnwrap(image.pngData()).write(to: url)
        print("[shot] \(url.path)")
    }

    func testPlaced_savedPositionsWin_andADragMovesOnlyItsCard() {
        let a = UUID(), b = UUID()
        let circle = [a: CGPoint(x: 100, y: 100), b: CGPoint(x: 300, y: 100)]
        let size = CGSize(width: 400, height: 200)
        let placed = NotebookGraphView.placed(circle, saved: [a: CGPoint(x: 0.5, y: 0.5), UUID(): CGPoint(x: 0, y: 0)],
                                              dragging: (b, CGSize(width: -20, height: 30)), in: size)
        XCTAssertEqual(placed[a], CGPoint(x: 200, y: 100))
        XCTAssertEqual(placed[b], CGPoint(x: 280, y: 130))
        XCTAssertEqual(placed.count, 2, "a saved position for a page that's gone is ignored")
    }
}
