import XCTest
import SwiftUI
import SwiftData
import PencilKit
@testable import Mystnotes

/// Field report, Sept 25, 2026: finishing an action - resizing a picture,
/// turning a sticker, changing the paper - reset the zoom, and stickers
/// blinked. The page's canvas was being replaced, which refits the page.
/// Checked here in the real notebook screen, in a window.
@MainActor
final class PageReloadTests: XCTestCase {

    private static let schema = Schema([
        Folder.self, Notebook.self, Page.self, TypedTextBlock.self,
        ImportedDocument.self, Link.self, Sticker.self
    ])

    /// One container for the class: SwiftUI's `@Query` observers from one
    /// test's screen outlive it, and a save in the next test notified them
    /// about a container that had gone - a crash in the tests, not the app.
    private static var container: ModelContainer?
    private static func sharedContainer() throws -> ModelContainer {
        if let container { return container }
        let made = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        container = made
        return made
    }

    /// Takes the notebook screen down with the test. Only hiding the
    /// window left it running on models whose container was going away,
    /// and the next test crashed.
    private func close(_ window: UIWindow) {
        window.rootViewController = nil
        window.isHidden = true
    }

    private func canvases(in view: UIView) -> [PKCanvasView] {
        (view as? PKCanvasView).map { [$0] } ?? view.subviews.flatMap(canvases(in:))
    }

    /// Every distinct canvas the window shows over `seconds`.
    private func canvasesShown(in window: UIWindow, for seconds: Double) async throws -> [ObjectIdentifier] {
        var seen: [ObjectIdentifier] = []
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            for canvas in canvases(in: window) where !seen.contains(ObjectIdentifier(canvas)) {
                seen.append(ObjectIdentifier(canvas))
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return seen
    }

    func testEditingWhatsOnThePage_keepsTheCanvas() async throws {
        let container = try Self.sharedContainer()
        let context = container.mainContext
        let notebook = Notebook(title: "Reload")
        context.insert(notebook)
        let page = Page(index: 0, notebook: notebook)
        context.insert(page)
        notebook.pages = [page]
        let sticker = Sticker(assetRef: "heart.fill", page: page)
        context.insert(sticker)
        page.stickers = [sticker]
        try context.save()

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        window.rootViewController = UIHostingController(rootView:
            NavigationStack { NotebookDetailView(notebook: notebook) }.modelContainer(container))
        window.makeKeyAndVisible()
        defer { close(window) }

        let settled = try await canvasesShown(in: window, for: 2)
        XCTAssertEqual(settled.count, 1, "one canvas once the page is open")

        // What a sticker turn, a paper change or an image's Done does.
        sticker.rotationDegrees = 90
        page.template = "grid"
        page.markModified()
        try context.save()

        let after = try await canvasesShown(in: window, for: 4)
        XCTAssertEqual(after, settled, "the canvas was replaced \(after.count - 1) time(s): the zoom resets and the page's layers blink")
    }

    /// What a reload is for: a pull brought new ink. It must still show.
    func testNewInkFromAPull_stillReloadsThePage() async throws {
        let container = try Self.sharedContainer()
        let context = container.mainContext
        let notebook = Notebook(title: "Reload")
        context.insert(notebook)
        let page = Page(index: 0, notebook: notebook)
        context.insert(page)
        notebook.pages = [page]
        try context.save()

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        window.rootViewController = UIHostingController(rootView:
            NavigationStack { NotebookDetailView(notebook: notebook) }.modelContainer(container))
        window.makeKeyAndVisible()
        defer {
            close(window)
            DrawingStore.live.trashDrawing(forPageID: page.id)
        }
        _ = try await canvasesShown(in: window, for: 2)

        // As a pull does: the record is rewritten, then the page's date.
        let point = PKStrokePoint(location: CGPoint(x: 100, y: 100), timeOffset: 0, size: CGSize(width: 4, height: 4),
                                  opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        let stroke = PKStroke(ink: PKInk(.pen, color: .black),
                              path: PKStrokePath(controlPoints: [point, point], creationDate: Date()))
        page.drawingFileRef = try DrawingStore.live.save(PKDrawing(strokes: [stroke]), pageID: page.id)
        page.markModified()
        try context.save()

        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(canvases(in: window).first?.drawing.strokes.count, 1, "the pulled ink isn't on the canvas")
    }
}
