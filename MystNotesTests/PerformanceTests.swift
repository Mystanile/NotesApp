import XCTest
import PDFKit
import PencilKit
import SwiftData
@testable import Mystnotes

/// M0 task 20: regression floors. Each test prints `BASELINE …` and fails
/// only if it blows well past the recorded number - these thresholds catch
/// a 3–5× regression, not simulator noise. The numbers themselves live in
/// `Docs/PERFORMANCE_BASELINE.md`; update both together.
///
/// Ink latency on ProMotion is not here: it needs the iPad in hand. See
/// the baseline doc for how it's measured.
@MainActor
final class PerformanceTests: XCTestCase {

    // MARK: Sync engine at 200 notebooks

    /// 200 notebooks × 10 pages, every page with ink: first push, first pull
    /// on a second device, a one-page incremental push, and a full rebuild.
    func testSync_twoHundredNotebooks() throws {
        let harness = try SyncTestHarness()
        defer { harness.tearDown() }
        let ipad = try harness.makeDevice("iPad")
        let mac = try harness.makeDevice("Mac")

        for i in 0..<200 { _ = try ipad.createNotebook(title: "Notebook \(i)", pageCount: 10) }
        XCTAssertEqual(try ipad.context.fetchCount(FetchDescriptor<Page>()), 2000)

        harness.clock.advance()
        let fullPush = try timed { try ipad.sync() }
        harness.clock.advance()
        let fullPull = try timed { try mac.sync() }
        XCTAssertEqual(try mac.context.fetchCount(FetchDescriptor<Page>()), 2000)

        let page = try XCTUnwrap(try ipad.pages(ofNotebook: try ipad.context.fetch(FetchDescriptor<Notebook>())[0].id)?.first)
        harness.clock.advance(); try ipad.edit(page: page, ink: Data("one edit".utf8))
        harness.clock.advance()
        let incrementalPush = try timed { try ipad.sync() }
        harness.clock.advance()
        let incrementalPull = try timed { try mac.sync() }
        harness.clock.advance()
        let noOpSync = try timed { try ipad.sync() }

        let rebuild = try timed { try LibraryRebuild.rebuild(container: mac.container, environment: mac.environment) }
        XCTAssertEqual(try mac.context.fetchCount(FetchDescriptor<Page>()), 2000)

        print("BASELINE sync 200 notebooks / 2000 pages: full push \(fmt(fullPush)), full pull \(fmt(fullPull)), incremental push \(fmt(incrementalPush)), incremental pull \(fmt(incrementalPull)), no-op sync \(fmt(noOpSync)), rebuild \(fmt(rebuild))")
        XCTAssertLessThan(fullPush, 30, "full push")
        XCTAssertLessThan(fullPull, 30, "full pull")
        XCTAssertLessThan(incrementalPush, 5, "incremental push must not scale with library size")
        XCTAssertLessThan(incrementalPull, 5, "incremental pull must not scale with library size")
        XCTAssertLessThan(noOpSync, 5, "a sync with nothing to do")
        XCTAssertLessThan(rebuild, 30, "rebuild")
    }

    // MARK: Library list at 200 notebooks

    /// What `LibraryView` does on appear: fetch every notebook and sort by
    /// `modifiedAt`. A proxy for cold-launch cost until an XCUITest launch
    /// metric exists.
    func testLibraryFetch_twoHundredNotebooks() throws {
        let harness = try SyncTestHarness()
        defer { harness.tearDown() }
        let ipad = try harness.makeDevice("iPad")
        for i in 0..<200 { _ = try ipad.createNotebook(title: "Notebook \(i)", pageCount: 10) }

        let fresh = ModelContext(ipad.container)
        let elapsed = try timed {
            let notebooks = try fresh.fetch(FetchDescriptor<Notebook>()).sorted { $0.modifiedAt > $1.modifiedAt }
            XCTAssertEqual(notebooks.count, 200)
            _ = notebooks.map { ($0.pages ?? []).count }   // the cells touch page counts
        }
        print("BASELINE library fetch + sort, 200 notebooks: \(fmt(elapsed))")
        XCTAssertLessThan(elapsed, 2)
    }

    // MARK: A 500-page PDF

    /// Import rasterizes every page (M1 replaces this with a live PDFKit
    /// layer). Peak memory and total time for all 500 pages at the canvas
    /// size, through the same `ImportedArtwork.rasterized` the app uses.
    func testPDF_fiveHundredPages_rasterizeEveryPage() throws {
        let fileRef = "baseline-\(UUID().uuidString).pdf"
        let url = FileStore.url(for: fileRef)
        try Self.makePDF(pages: 500).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let canvas = CGSize(width: 780, height: 1040)
        var elapsed: TimeInterval = 0
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        measure(metrics: [XCTMemoryMetric()], options: options) {
            elapsed = (try? timed {
                for i in 0..<500 {
                    XCTAssertNotNil(ImportedArtwork.rasterized(fileRef: fileRef, pdfPageIndex: i, targetSize: canvas), "page \(i)")
                }
            }) ?? -1
        }
        print("BASELINE 500-page PDF, rasterize every page at 780×1040: \(fmt(elapsed)) (peak memory: see XCTMemoryMetric above)")
        XCTAssertLessThan(elapsed, 120)
    }

    // MARK: Ink files

    /// A dense page: 500 strokes of 32 control points through DrawingStore -
    /// the neutral record, the cache, and the load that prefers the cache.
    func testDrawingStore_denseRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DrawingStore.inDirectory(dir)
        let pageID = UUID()
        let drawing = PKDrawing(strokes: (0..<500).map { InkFixtures.stroke(inkType: .pen, index: $0 % 40) })

        let save = try timed { try store.save(drawing, pageID: pageID) }
        let secondSave = try timed { try store.save(drawing, pageID: pageID) }   // ids all known
        let load = try timed { XCTAssertEqual(store.load(pageID: pageID)?.strokes.count, 500) }
        let recordBytes = try Data(contentsOf: store.fileURL(for: pageID)).count
        let decodeOnly = try timed { _ = try StrokeCodec.decode(try Data(contentsOf: store.fileURL(for: pageID))) }

        print("BASELINE ink 500 strokes: save \(fmt(save)), second save \(fmt(secondSave)), load \(fmt(load)), decode only \(fmt(decodeOnly)), record \(recordBytes / 1024) KB")
        XCTAssertLessThan(save, 2)
        XCTAssertLessThan(load, 1)
    }

    // MARK: - Helpers

    private func timed(_ body: () throws -> Void) throws -> TimeInterval {
        let start = ContinuousClock.now
        try body()
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    private func fmt(_ t: TimeInterval) -> String { String(format: "%.3f s", t) }

    private static func makePDF(pages: Int) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        return renderer.pdfData { context in
            for i in 0..<pages {
                context.beginPage()
                let text = "Page \(i + 1) — lorem ipsum dolor sit amet, consectetur adipiscing elit."
                text.draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
                UIColor.gray.setStroke()
                for y in stride(from: 80, to: 760, by: 24) {
                    let path = UIBezierPath()
                    path.move(to: CGPoint(x: 40, y: y)); path.addLine(to: CGPoint(x: 572, y: y))
                    path.stroke()
                }
            }
        }
    }
}
