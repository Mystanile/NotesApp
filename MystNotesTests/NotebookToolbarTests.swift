import XCTest
import SwiftData
import SwiftUI
import UIKit
@testable import Mystnotes

/// The Oct 24 toolbar change: one Insert menu, Share, More, labelled icons,
/// and the pen's colour dot. Hosted in a real window; nothing touches the
/// screen. Menus open through the control's primary action and are read
/// through accessibility; the tests skip if the rows can't be reached.
@MainActor
final class NotebookToolbarTests: XCTestCase {

    private static var container: ModelContainer?

    private func makeWindow(_ size: CGSize) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        return window
    }

    private func render(_ window: UIWindow) -> UIImage {
        UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func savePNG(_ image: UIImage, _ name: String) {
        let folder = URL(fileURLWithPath: "/tmp/mystnotes-probes", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? image.pngData()?.write(to: folder.appendingPathComponent("\(name).png"))
    }

    private func axElements(in root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        var found: [NSObject] = []
        func visit(_ element: NSObject, _ depth: Int) {
            guard depth < 80, seen.insert(ObjectIdentifier(element)).inserted else { return }
            if element.isAccessibilityElement { found.append(element) }
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
        visit(root, 0)
        return found
    }

    private func labels(in window: UIWindow) -> [String] {
        axElements(in: window).compactMap(\.accessibilityLabel)
    }

    /// Opens the menu button with this label; returns the labels in the
    /// scene afterwards, or nil if there is no such button.
    private func openMenu(_ label: String, in window: UIWindow) async throws -> [String]? {
        guard let button = axElements(in: window).first(where: { $0.accessibilityLabel == label }) else { return nil }
        var control = button as? UIView
        while let view = control, !(view is UIControl) { control = view.superview }
        if let control = control as? UIControl { control.performPrimaryAction() } else { _ = button.accessibilityActivate() }
        try await Task.sleep(for: .seconds(1.5))
        return (window.windowScene?.windows ?? [window]).flatMap { axElements(in: $0) }.compactMap(\.accessibilityLabel)
    }

    private func bar(color: Color = .black) -> some View {
        var state = DrawingToolState()
        state.penColor = color
        return DrawingToolbarView(style: .inline, toolState: .constant(state), openPopover: .constant(nil),
                                  canUndo: true, canRedo: true, isFillToolAvailable: true, isTextBoxAvailable: true,
                                  containerSize: .zero, onUndo: {}, onRedo: {}, onAddTextBox: {}, onAddSticker: {},
                                  onAddLink: {}, onAddImage: {}, onImportFile: {}, onPasteImage: {},
                                  canPasteImage: true, onNewPagesFromFiles: {}, onNewPagesFromPhotos: {}, onNewPagesScan: {})
    }

    func testInsertMenu_holdsExactlyTheVisibleItems() async throws {
        let key = AppSettings.Keys.hiddenToolbarItems
        let saved = UserDefaults.standard.object(forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        let first = ["Text Box", "Photo", "Sticker", "Link to a Page"]

        for (hidden, expected) in [
            (Set<ToolbarItemChoice>(), first),
            ([.sticker, .link], ["Text Box", "Photo"]),
        ] as [(Set<ToolbarItemChoice>, [String])] {
            UserDefaults.standard.set(ToolbarItemChoice.stored(hidden), forKey: key)
            let window = try makeWindow(CGSize(width: 800, height: 700))
            window.rootViewController = UIHostingController(rootView: bar())
            window.makeKeyAndVisible()
            defer { window.rootViewController = nil; window.isHidden = true }
            try await Task.sleep(for: .seconds(1))
            guard let after = try await openMenu("Insert", in: window), after.contains("From Photos") else {
                throw XCTSkip("couldn't read the Insert menu through accessibility")
            }
            for item in first {
                XCTAssertEqual(after.contains(item), expected.contains(item), "\(item) with hidden \(hidden): \(after)")
            }
            for always in ["PDF or Image File", "From Files"] { XCTAssertTrue(after.contains(always), "\(always) missing: \(after)") }
            window.rootViewController?.presentedViewController?.dismiss(animated: false)
        }

        UserDefaults.standard.set(ToolbarItemChoice.stored([.textBox, .sticker, .image, .link]), forKey: key)
        let window = try makeWindow(CGSize(width: 800, height: 700))
        window.rootViewController = UIHostingController(rootView: bar())
        window.makeKeyAndVisible()
        defer { window.rootViewController = nil; window.isHidden = true }
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(labels(in: window).contains("Insert"),
                      "with all four page items hidden, Insert must stay: it is the only way to import or scan")
    }

    func testPenButton_showsTheActiveColour() async throws {
        UserDefaults.standard.removeObject(forKey: AppSettings.Keys.hiddenToolbarItems)
        var count0 = 0
        func redPixels(_ color: Color) async throws -> Int {
            let window = try makeWindow(CGSize(width: 800, height: 80))
            window.rootViewController = UIHostingController(rootView: bar(color: color))
            window.makeKeyAndVisible()
            defer { window.rootViewController = nil; window.isHidden = true }
            try await Task.sleep(for: .seconds(1))
            let img = render(window)
            savePNG(img, "toolbar-pen-\(count0)"); count0 += 1
            let cg = try XCTUnwrap(img.cgImage)
            // Redraw into a known RGBA8 buffer: the window's own format is wide-gamut.
            var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            let ctx = try XCTUnwrap(CGContext(data: &px, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                              bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            var count = 0
            for i in stride(from: 0, to: px.count, by: 4) {
                let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
                if g > 180, g - r > 80, g - b > 80 { count += 1 }
            }
            return count
        }
        let plain = try await redPixels(.black)
        let red = try await redPixels(Color(red: 0, green: 1, blue: 0))
        print("[toolbar] saturated pixels: black pen \(plain), red pen \(red)")
        XCTAssertGreaterThan(red, plain + 20, "a green pen shows no colour dot on the pen button")
    }

    func testNotebookScreen_hasLabelledShareMoreAndNoUnlabelledIcons() async throws {
        UserDefaults.standard.removeObject(forKey: AppSettings.Keys.hiddenToolbarItems)
        for size in [CGSize(width: 1180, height: 820), CGSize(width: 585, height: 820)] {
            let window = try await hostNotebook(size)
            defer {
                window.rootViewController?.presentedViewController?.dismiss(animated: false)
                window.rootViewController = nil
                window.isHidden = true
            }
            savePNG(render(window), "toolbar-\(Int(size.width))x\(Int(size.height))")
            let all = axElements(in: window)
            let names = all.compactMap(\.accessibilityLabel)
            print("[toolbar] \(Int(size.width)) labels: \(names)")
            for needed in ["Share", "More", "Page Map", "Pages", "Insert", "Undo", "Redo", "Pen", "Eraser"] {
                XCTAssertTrue(names.contains(needed), "\(needed) missing at \(Int(size.width)) wide: \(names)")
            }
            for old in ["Save", "Import", "Outline", "Present"] {
                XCTAssertFalse(names.contains(old), "\(old) is still on the bar at \(Int(size.width)) wide")
            }
            let symbolNamed = all.filter {
                $0.accessibilityTraits.contains(.button) && ($0.accessibilityLabel ?? "").contains(".")
                    && !($0.accessibilityLabel ?? "").contains(" ")
            }.compactMap(\.accessibilityLabel)
            XCTAssertTrue(symbolNamed.isEmpty, "buttons announced by symbol name: \(symbolNamed)")

            if size.width > 1000, let opened = try await openMenu("More", in: window), opened.contains("Present") {
                XCTAssertTrue(opened.contains("Outline") && opened.contains("New Page"), "More menu: \(opened)")
            }
        }
    }

    private func hostNotebook(_ size: CGSize) async throws -> UIWindow {
        let container = try Self.container ?? ModelContainer(for: Folder.self, Notebook.self, Page.self, TypedTextBlock.self,
                                                             Sticker.self, ImportedDocument.self, Link.self,
                                                             configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        Self.container = container
        let context = container.mainContext
        let notebook = Notebook(title: "Probe")
        context.insert(notebook)
        let page = Page(index: 0, notebook: notebook)
        context.insert(page)
        notebook.pages = [page]
        try context.save()
        let window = try makeWindow(size)
        window.rootViewController = UIHostingController(rootView:
            NavigationStack { NotebookDetailView(notebook: notebook) }.modelContainer(container))
        window.makeKeyAndVisible()
        try await Task.sleep(for: .seconds(2))
        return window
    }
}
