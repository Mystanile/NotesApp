import XCTest
import SwiftData
import SwiftUI
@testable import Mystnotes

final class PageTagsUITests: XCTestCase {
    @MainActor private static var container: ModelContainer?

    func testAdding_splitsOnCommasNormalizesAndDedupes() {
        XCTAssertEqual(PageTagsSheet.adding("limits, #Exam ,exam,", to: ["Zeta"]), ["Exam", "limits", "Zeta"])
        XCTAssertEqual(PageTagsSheet.adding("  ", to: ["a"]), ["a"])
    }

    func testRemoving_ignoresCase() {
        XCTAssertEqual(PageTagsSheet.removing("EXAM", from: ["Exam", "Limits"]), ["Limits"])
    }

    @MainActor
    func testLibraryTagList_countsPagesAndLabels() {
        let nb = Notebook(title: "Calc")
        let a = Page(index: 0, notebook: nb), b = Page(index: 1, notebook: nb)
        b.title = "Limits"
        a.setTags(["Exam"]); b.setTags(["exam", "Limits"])
        let tags = PageTags.counts(in: [a, b])
        XCTAssertEqual(tags.map(\.name), ["Exam", "Limits"])
        XCTAssertEqual(tags.map { $0.pages.count }, [2, 1])
        XCTAssertEqual(TagPages.label(for: b), "Calc · p. 2 · Limits")
        XCTAssertEqual(TagPages.label(for: a), "Calc · p. 1")
    }

    @MainActor
    func testMarkdown_listsTagsUnderThePageHeading() throws {
        let container = try Self.container ?? ModelContainer(for: Folder.self, Notebook.self, Page.self, TypedTextBlock.self,
                                                             Sticker.self, ImportedDocument.self, Link.self,
                                                             configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        Self.container = container
        let nb = Notebook(title: "Calc")
        container.mainContext.insert(nb)
        let page = Page(index: 0, notebook: nb)
        container.mainContext.insert(page)
        nb.pages = [page]
        page.setTags(["Exam", "Limits"])
        let md = LibraryExport.markdown(for: nb)
        XCTAssertTrue(md.contains("## Page 1\n\nTags: #Exam #Limits"), md)
    }

    @MainActor
    func testSheet_rendersThreeTags() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 500, height: 400)
        window.rootViewController = UIHostingController(rootView: PageTagsSheet(tags: ["Exam", "Limits", "Week 3"]) { _ in })
        window.makeKeyAndVisible()
        defer { window.rootViewController = nil; window.isHidden = true }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tags.png")
        try XCTUnwrap(image.pngData()).write(to: url)
        print("[shot] \(url.path)")
    }
}
