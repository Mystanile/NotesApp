import XCTest
import SwiftData
import SwiftUI
@testable import Mystnotes

final class LinkedFromTests: XCTestCase {
    @MainActor private static var container: ModelContainer?

    func testSources_areUniqueInPageOrder_withoutSelfOrMissingPages() throws {
        let notebook = Notebook(title: "N")
        let pages = (0..<4).map { Page(index: $0, notebook: notebook) }
        let target = pages[1]
        let links = [
            Link(sourcePageID: pages[3].id, destinationPageID: target.id),
            Link(sourcePageID: pages[0].id, destinationPageID: target.id),
            Link(sourcePageID: pages[3].id, destinationPageID: target.id),   // a second link from p. 4
            Link(sourcePageID: target.id, destinationPageID: target.id),     // to itself
            Link(sourcePageID: UUID(), destinationPageID: target.id),        // source page deleted
            Link(sourcePageID: pages[2].id, destinationPageID: pages[0].id), // elsewhere
        ]
        let sources = LinkedFromStrip.sources(linkingTo: target.id, links: links, pages: pages)
        XCTAssertEqual(sources.map(\.id), [pages[0].id, pages[3].id])
    }

    func testLabel_usesThePageNameWhenThereIsOne() {
        let page = Page(index: 2, notebook: Notebook(title: "N"))
        XCTAssertEqual(LinkedFromStrip.label(for: page), "p. 3")
        page.title = "Lecture 4"
        XCTAssertEqual(LinkedFromStrip.label(for: page), "p. 3 · Lecture 4")
    }

    /// The strip on screen: page 2 links to page 1, the page a notebook
    /// opens on. Writes a picture of the window for a look.
    @MainActor
    func testStrip_showsOnTheLinkedPage() async throws {
        // Kept for the life of the process: the screen's observers outlive
        // the test (CLAUDE.md gotcha on hosted `@Query` screens).
        let container = try Self.container ?? ModelContainer(for: Folder.self, Notebook.self, Page.self, TypedTextBlock.self,
                                                             Sticker.self, ImportedDocument.self, Link.self,
                                                             configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        Self.container = container
        let context = container.mainContext
        let notebook = Notebook(title: "Linked")
        context.insert(notebook)
        let first = Page(index: 0, notebook: notebook)
        let second = Page(index: 1, notebook: notebook)
        second.title = "Worked example"
        context.insert(first); context.insert(second)
        notebook.pages = [first, second]
        context.insert(Link(sourcePageID: second.id, destinationPageID: first.id))
        try context.save()

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        window.rootViewController = UIHostingController(rootView:
            NavigationStack { NotebookDetailView(notebook: notebook) }.modelContainer(container))
        window.makeKeyAndVisible()
        defer { window.rootViewController = nil; window.isHidden = true }
        try await Task.sleep(nanoseconds: 2_000_000_000)

        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("linked-from.png")
        try XCTUnwrap(image.pngData()).write(to: url)
        print("[shot] \(url.path)")
    }

    func testLinkAnchor_isTheSelectionsBox_atLeastATapWide() {
        let rotated = [CGPoint(x: 100, y: 200), CGPoint(x: 300, y: 180), CGPoint(x: 310, y: 260), CGPoint(x: 110, y: 280)]
        XCTAssertEqual(NotebookDetailView.linkAnchor(around: rotated), CGRect(x: 100, y: 180, width: 210, height: 100))
        let thin = [CGPoint(x: 10, y: 10), CGPoint(x: 200, y: 10), CGPoint(x: 200, y: 12), CGPoint(x: 10, y: 12)]
        XCTAssertEqual(NotebookDetailView.linkAnchor(around: thin)?.height, 44)
        XCTAssertNil(NotebookDetailView.linkAnchor(around: []))
    }
}
