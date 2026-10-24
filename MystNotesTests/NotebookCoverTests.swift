import XCTest
import SwiftUI
import PencilKit
@testable import Mystnotes

/// Draws every cover style at the library grid size and at the small
/// "Recent" size, for a look. Fails only if nothing renders.
@MainActor
final class NotebookCoverTests: XCTestCase {
    func testCovers_renderAtBothSizes() throws {
        let styles = ["default", "sunset", "ocean", "forest", "mono", "berry"]
        let notebooks = styles.map { style -> Notebook in
            let notebook = Notebook(title: style == "default" ? "Calculus II — Lecture Notes" : style.capitalized)
            notebook.coverStyle = style
            return notebook
        }
        let sheet = VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 24) { ForEach(notebooks, id: \.id) { NotebookCellView(notebook: $0).frame(width: 150) } }
            HStack(spacing: 16) { ForEach(notebooks, id: \.id) { RecentNotebookCellView(notebook: $0) } }
        }
        .padding(24)
        .background(Color(white: 0.95))

        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("covers.png")
        try XCTUnwrap(image.pngData()).write(to: url)
        print("[shot] \(url.path)")
    }

    // MARK: Edited date and page preview

    func testEditedText_todayYesterdayWeekdayOlder() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.locale = Locale(identifier: "en_US")
        let now = Date(timeIntervalSince1970: 1_792_843_200) // Sat Oct 24, 2026 12:00 UTC
        func text(daysAgo: Int, hoursAgo: Double = 0) -> String {
            let d = cal.date(byAdding: .day, value: -daysAgo, to: now)!.addingTimeInterval(-hoursAgo * 3600)
            return NotebookCellView.editedText(d, now: now, calendar: cal)
        }
        XCTAssertEqual(text(daysAgo: 0), "Edited today")
        XCTAssertEqual(text(daysAgo: 0, hoursAgo: 11), "Edited today")
        XCTAssertEqual(text(daysAgo: 1), "Edited yesterday")
        XCTAssertEqual(text(daysAgo: 3), "Edited Wednesday")
        XCTAssertEqual(text(daysAgo: 6), "Edited Sunday")
        XCTAssertEqual(text(daysAgo: 21), "Edited Oct 3")
        XCTAssertEqual(text(daysAgo: 400), "Edited Sep 19, 2025", "another year shows its year")
    }

    func testPreview_noneWithoutInk_noneWhenLocked_latestInkedPageOtherwise() {
        let notebook = Notebook(title: "N")
        let blank = Page(index: 0), old = Page(index: 1), recent = Page(index: 2)
        old.drawingFileRef = "a"; recent.drawingFileRef = "b"
        old.modifiedAt = Date(timeIntervalSince1970: 100); recent.modifiedAt = Date(timeIntervalSince1970: 200)
        blank.modifiedAt = Date(timeIntervalSince1970: 300)
        notebook.pages = [blank]
        XCTAssertNil(NotebookCoverView.previewPage(of: notebook), "a notebook with no ink has no preview")
        notebook.pages = [blank, old, recent]
        XCTAssertTrue(NotebookCoverView.previewPage(of: notebook) === recent)
        notebook.isLocked = true
        XCTAssertNil(NotebookCoverView.previewPage(of: notebook), "a locked notebook shows no page")
    }

    func testLibraryOfThree_rendersLightAndDark() async throws {
        let inked = Notebook(title: "Calculus II")
        let page = Page(index: 0)
        var points: [PKStrokePoint] = []
        for i in 0..<20 {
            let t = Double(i)
            let at = CGPoint(x: 100 + t * 20, y: 300 + 80 * sin(t / 3))
            points.append(PKStrokePoint(location: at, timeOffset: t * 0.01, size: CGSize(width: 6, height: 6),
                                        opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2))
        }
        let ink = PKStrokePath(controlPoints: points, creationDate: Date())
        page.drawingFileRef = try DrawingStore.live.save(PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: ink)]), pageID: page.id)
        inked.pages = [page]
        let plain = Notebook(title: "Empty one"); plain.coverStyle = "sunset"
        let locked = Notebook(title: "Private"); locked.coverStyle = "forest"; locked.isLocked = true
        locked.pages = [{ let p = Page(index: 0); p.drawingFileRef = page.drawingFileRef; return p }()]
        let notebooks = [inked, plain, locked]
        for mode in [UIUserInterfaceStyle.light, .dark] {
            let name = mode == .dark ? "dark" : "light"
            let root = HStack(alignment: .top, spacing: 24) {
                ForEach(notebooks, id: \.id) { NotebookCellView(notebook: $0).frame(width: 150) }
            }
            .padding(24).background(Color(uiColor: .systemBackground))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 24 * 4 + 450, height: 290)
            window.overrideUserInterfaceStyle = mode
            let host = UIHostingController(rootView: root)
            host.safeAreaRegions = []
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await Task.sleep(for: .seconds(2))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            window.rootViewController = nil
            window.isHidden = true
            let dir = URL(fileURLWithPath: "/tmp/mystnotes-probes", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try XCTUnwrap(image.pngData()).write(to: dir.appendingPathComponent("library-covers-\(name).png"))
        }
    }
}
