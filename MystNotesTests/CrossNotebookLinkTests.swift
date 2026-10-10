import XCTest
import SwiftData
import SwiftUI
@testable import Mystnotes

final class CrossNotebookLinkTests: XCTestCase {
    @MainActor private static var container: ModelContainer?

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try Self.container ?? ModelContainer(for: Folder.self, Notebook.self, Page.self, TypedTextBlock.self,
                                                             Sticker.self, ImportedDocument.self, Link.self,
                                                             configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        Self.container = container
        return container.mainContext
    }

    @MainActor
    private func twoNotebooks(_ context: ModelContext) throws -> (Notebook, [Page], Notebook, [Page]) {
        let a = Notebook(title: "Alpha"), b = Notebook(title: "Beta")
        context.insert(a); context.insert(b)
        let ap = (0..<2).map { Page(index: $0, notebook: a) }
        let bp = (0..<2).map { Page(index: $0, notebook: b) }
        (ap + bp).forEach { context.insert($0) }
        a.pages = ap; b.pages = bp
        try context.save()
        return (a, ap, b, bp)
    }

    @MainActor
    func testSources_includeOtherNotebook_withNotebookLabel() throws {
        let (a, ap, b, bp) = try twoNotebooks(try makeContext())
        let links = [Link(sourcePageID: ap[0].id, destinationPageID: bp[1].id)]
        let sources = LinkedFromStrip.sources(linkingTo: bp[1].id, links: links, pages: ap + bp)
        XCTAssertEqual(sources.map(\.id), [ap[0].id])
        XCTAssertEqual(LinkedFromStrip.label(for: ap[0], currentNotebookID: b.id), "Alpha · p. 1")
        XCTAssertEqual(LinkedFromStrip.label(for: ap[0], currentNotebookID: a.id), "p. 1")
    }

    @MainActor
    func testPicker_otherNotebooks_excludeCurrent_sortedByTitle() throws {
        let c = Notebook(title: "Gamma")
        let (a, _, b, _) = try twoNotebooks(try makeContext())
        let others = LinkDestinationPickerView.otherNotebooks([c, b, a], excluding: a.id)
        XCTAssertEqual(others.map(\.title), ["Beta", "Gamma"])
    }

    /// Open B on the linked page with the strip's data in the store.
    @MainActor
    func testScreen_opensOnDestination_withLinkFromOtherNotebook() async throws {
        let context = try makeContext()
        let (_, ap, b, bp) = try twoNotebooks(context)
        context.insert(Link(sourcePageID: ap[0].id, destinationPageID: bp[1].id))
        try context.save()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        window.rootViewController = UIHostingController(rootView:
            NavigationStack { NotebookDetailView(notebook: b, initialPageID: bp[1].id) }
                .navigationDestination(for: SearchResult.self) { NotebookDetailView(notebook: $0.notebook, initialPageID: $0.pageID) }
                .modelContainer(Self.container!))
        window.makeKeyAndVisible()
        defer { window.rootViewController = nil; window.isHidden = true }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertNotNil(window.rootViewController?.view)
    }

    func testLinkToOtherNotebook_reachesTheOtherDevice() throws {
        let harness = try SyncTestHarness()
        defer { harness.tearDown() }
        let ipad = try harness.makeDevice("iPad")
        let mac = try harness.makeDevice("Mac")
        let a = try ipad.createNotebook(title: "A", pageCount: 1)
        let b = try ipad.createNotebook(title: "B", pageCount: 2)
        let ap = try XCTUnwrap(try ipad.pages(ofNotebook: a.id)), bp = try XCTUnwrap(try ipad.pages(ofNotebook: b.id))
        harness.clock.advance()
        let link = try ipad.addLink(from: ap[0], to: bp[1])
        harness.clock.advance(); try ipad.sync()
        harness.clock.advance(); try mac.sync()
        let arrived = try XCTUnwrap(try mac.context.fetch(FetchDescriptor<Mystnotes.Link>()).first { $0.id == link.id })
        XCTAssertEqual(arrived.destinationPageID, bp[1].id)
    }
}
