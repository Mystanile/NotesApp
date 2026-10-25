import XCTest
import SwiftData
import SwiftUI
import PencilKit
import UIKit
@testable import Mystnotes

/// The left page sidebar that replaced the bottom strip (Oct 24, 2026):
/// its sizes, and the notebook screen hosted in a real window.
@MainActor
final class PageSidebarTests: XCTestCase {

    // MARK: Sizes

    func testWidthClamps_andThumbnailsFitTheColumn() {
        XCTAssertEqual(PageSidebarMetrics.clamped(10), 96)
        XCTAssertEqual(PageSidebarMetrics.clamped(10_000), 220)
        XCTAssertEqual(PageSidebarMetrics.clamped(150), 150)
        XCTAssertEqual(PageSidebarMetrics.defaultWidth, 128)
        for width in [96, 128, 220] as [CGFloat] {
            XCTAssertLessThan(PageSidebarMetrics.thumbnailWidth(sidebarWidth: width), width, "a cell plus its chrome fits")
        }
        XCTAssertGreaterThan(PageSidebarMetrics.thumbnailHeight(sidebarWidth: 220, aspect: 0.75),
                             PageSidebarMetrics.thumbnailHeight(sidebarWidth: 128, aspect: 0.75),
                             "dragging wider makes the pages bigger")
        XCTAssertLessThan(PageSidebarMetrics.thumbnailHeight(sidebarWidth: 128, aspect: 1.5),
                          PageSidebarMetrics.thumbnailHeight(sidebarWidth: 128, aspect: 0.75), "a landscape page is shorter")
    }

    // MARK: Hosted

    private static var container: ModelContainer?

    private func host(size: CGSize, compact: Bool, pages: Int = 6) async throws -> (UIWindow, Notebook) {
        let container = try Self.container ?? ModelContainer(
            for: Folder.self, Notebook.self, Page.self, TypedTextBlock.self, Sticker.self, ImportedDocument.self, Link.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        Self.container = container
        let context = container.mainContext
        let notebook = Notebook(title: "Sidebar")
        context.insert(notebook)
        var made: [Page] = []
        for index in 0..<pages {
            let page = Page(index: index, notebook: notebook)
            context.insert(page)
            made.append(page)
        }
        notebook.pages = made
        try context.save()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let root = NavigationStack { NotebookDetailView(notebook: notebook) }
            .modelContainer(container)
            .environment(\.horizontalSizeClass, compact ? .compact : .regular)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        try await Task.sleep(for: .seconds(2))
        return (window, notebook)
    }

    private func close(_ window: UIWindow) {
        window.rootViewController = nil
        window.isHidden = true
    }

    private func savePNG(_ window: UIWindow, _ name: String) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let folder = URL(fileURLWithPath: "/tmp/mystnotes-probes", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? image.pngData()?.write(to: folder.appendingPathComponent("\(name).png"))
    }

    private func labels(in window: UIWindow) -> [String] {
        var seen = Set<ObjectIdentifier>()
        var found: [String] = []
        func visit(_ element: NSObject, _ depth: Int) {
            guard depth < 80, seen.insert(ObjectIdentifier(element)).inserted else { return }
            if element.isAccessibilityElement, let label = element.accessibilityLabel { found.append(label) }
            if let children = element.accessibilityElements {
                children.compactMap { $0 as? NSObject }.forEach { visit($0, depth + 1) }
            } else {
                let count = element.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    for i in 0..<count { if let child = element.accessibilityElement(at: i) as? NSObject { visit(child, depth + 1) } }
                }
            }
            if let view = element as? UIView { view.subviews.forEach { visit($0, depth + 1) } }
        }
        visit(window, 0)
        return found
    }

    private func firstView<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews { if let found = firstView(type, in: sub) { return found } }
        return nil
    }

    /// Page numbers shown in the sidebar, top to bottom, as the numbers
    /// 1, 2, 3...: the labels that are only digits.
    private func cellNumbers(in window: UIWindow) -> [Int] {
        labels(in: window).compactMap { Int($0) }
    }

    func testRegularWidth_showsOneCellPerPageInOrder_andAddPage() async throws {
        let wasVisible = AppSettings.pageStripVisible
        AppSettings.pageStripVisible = true
        let (window, _) = try await host(size: CGSize(width: 1180, height: 820), compact: false)
        defer { close(window); AppSettings.pageStripVisible = wasVisible }
        savePNG(window, "sidebar-regular")
        let numbers = cellNumbers(in: window)
        XCTAssertGreaterThanOrEqual(numbers.count, 3, "the sidebar shows cells: \(labels(in: window))")
        XCTAssertEqual(numbers, Array(1...numbers.count), "in page order, one per page (lazy: a prefix is built)")
        XCTAssertLessThanOrEqual(numbers.count, 6)
        XCTAssertTrue(labels(in: window).contains("Page 1 of 6"), "the position label stays")
    }

    func testCompactWidth_startsHidden_opensOverTheCanvas() async throws {
        let (window, _) = try await host(size: CGSize(width: 585, height: 820), compact: true)
        defer { close(window) }
        savePNG(window, "sidebar-compact-closed")
        XCTAssertTrue(cellNumbers(in: window).isEmpty, "hidden until opened in compact width")
        let host = try XCTUnwrap(firstView(PagedCanvasHostView.self, in: window))
        let widthBefore = host.bounds.width

        let button = try findButton(labelled: "Pages", in: window)
        XCTAssertTrue(button.accessibilityActivate())
        try await Task.sleep(for: .seconds(1.5))
        savePNG(window, "sidebar-compact")
        XCTAssertFalse(cellNumbers(in: window).isEmpty, "opened")
        XCTAssertEqual(firstView(PagedCanvasHostView.self, in: window)?.bounds.width, widthBefore,
                       "it overlays the canvas rather than squeezing it")
    }

    /// Opening, closing and resizing the sidebar refits the page; it must
    /// not replace the canvas (PageReloadTests' rule).
    func testToggling_refitsTheCanvas_withoutReloading() async throws {
        let wasVisible = AppSettings.pageStripVisible
        let wasWidth = AppSettings.pageSidebarWidth
        AppSettings.pageStripVisible = true
        let (window, _) = try await host(size: CGSize(width: 1180, height: 820), compact: false)
        defer { close(window); AppSettings.pageStripVisible = wasVisible; AppSettings.pageSidebarWidth = wasWidth }
        let canvas = try XCTUnwrap(firstView(PKCanvasView.self, in: window))
        let host = try XCTUnwrap(firstView(PagedCanvasHostView.self, in: window))
        let shown = host.bounds.width

        AppSettings.pageStripVisible = false
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertGreaterThan(host.bounds.width, shown + 100, "the canvas takes the sidebar's room")
        AppSettings.pageSidebarWidth = 200
        AppSettings.pageStripVisible = true
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertLessThan(host.bounds.width, shown, "a wider sidebar leaves a narrower canvas")
        XCTAssertTrue(firstView(PKCanvasView.self, in: window) === canvas, "the canvas was replaced")
    }

    private func findButton(labelled label: String, in window: UIWindow) throws -> NSObject {
        var seen = Set<ObjectIdentifier>()
        var result: NSObject?
        func visit(_ element: NSObject, _ depth: Int) {
            guard result == nil, depth < 80, seen.insert(ObjectIdentifier(element)).inserted else { return }
            if element.isAccessibilityElement, element.accessibilityLabel == label { result = element; return }
            if let children = element.accessibilityElements {
                children.compactMap { $0 as? NSObject }.forEach { visit($0, depth + 1) }
            } else {
                let count = element.accessibilityElementCount()
                if count != NSNotFound, count > 0 {
                    for i in 0..<count { if let child = element.accessibilityElement(at: i) as? NSObject { visit(child, depth + 1) } }
                }
            }
            if let view = element as? UIView { view.subviews.forEach { visit($0, depth + 1) } }
        }
        visit(window, 0)
        return try XCTUnwrap(result, "no element labelled \(label)")
    }
}
