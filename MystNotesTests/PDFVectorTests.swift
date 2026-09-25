import XCTest
import PDFKit
import UIKit
import SwiftUI
@testable import Mystnotes

/// Imported PDF pages drawn as vectors: sharp at any zoom, and an exported
/// PDF that keeps the source's real text (M1 task 2, Sept 25, 2026).
final class PDFVectorTests: XCTestCase {

    private var written: [URL] = []

    override func tearDown() {
        for url in written { try? FileManager.default.removeItem(at: url) }
        written = []
        super.tearDown()
    }

    private static let text = "Entropy is disorder"

    /// A portrait PDF page that shows which way up it is: red top-left
    /// quadrant, blue strip along the bottom, and a line of real text.
    private func writePDF() throws -> String {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 600)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 540, width: 400, height: 60))
            NSAttributedString(string: Self.text, attributes: [.font: UIFont.systemFont(ofSize: 24)])
                .draw(at: CGPoint(x: 210, y: 320))
        }
        let ref = "\(UUID().uuidString).pdf"
        let url = FileStore.url(for: ref)
        try data.write(to: url)
        written.append(url)
        return ref
    }

    private func layer(_ ref: String, rotation: Double? = nil, crop: CGRect? = nil,
                       frame: CGRect? = CGRect(x: 0, y: 0, width: 1, height: 1)) -> ArtworkLayer {
        ArtworkLayer(id: UUID(), fileRef: ref, sourceType: "pdf", pdfPageIndex: 0,
                     frameX: frame.map { Double($0.minX) }, frameY: frame.map { Double($0.minY) },
                     frameWidth: frame.map { Double($0.width) }, frameHeight: frame.map { Double($0.height) },
                     cropX: crop.map { Double($0.minX) }, cropY: crop.map { Double($0.minY) },
                     cropWidth: crop.map { Double($0.width) }, cropHeight: crop.map { Double($0.height) },
                     rotationDegrees: rotation)
    }

    private func pixels(size: CGSize, scale: CGFloat, draw: (CGContext) -> Void) -> [UInt8] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.green.setFill()                  // anything left undrawn shows as green
            context.fill(CGRect(origin: .zero, size: size))
            draw(context.cgContext)
        }
        let cg = image.cgImage!
        var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        px.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8,
                      bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                .draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return px
    }

    /// The vector drawing is the same picture the raster path makes, for
    /// every quarter turn, with and without a crop. A wrong rotation or
    /// crop puts the red quadrant or the blue strip somewhere else, and
    /// most of the pixels disagree.
    func testVectorDrawing_matchesTheRaster_forEveryRotationAndCrop() throws {
        let ref = try writePDF()
        let page = try XCTUnwrap(PDFDocument(url: FileStore.url(for: ref))?.page(at: 0))
        let rect = CGRect(x: 20, y: 30, width: 240, height: 180)
        let container = CGSize(width: 300, height: 260)
        for rotation in [0.0, 90, 180, 270] {
            for crop in [nil, CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6)] {
                let artwork = layer(ref, rotation: rotation, crop: crop, frame: nil)
                let raster = try XCTUnwrap(artwork.image(targetSize: CGSize(width: 1200, height: 1200)))
                let expected = pixels(size: container, scale: 2) { _ in raster.draw(in: rect) }
                let actual = pixels(size: container, scale: 2) { cg in
                    ImportedArtwork.drawPDF(page, layer: artwork, in: rect, context: cg)
                }
                let differing = stride(from: 0, to: expected.count, by: 4).filter { i in
                    (0..<3).contains { abs(Int(expected[i + $0]) - Int(actual[i + $0])) > 64 }
                }.count
                XCTAssertLessThan(Double(differing) / Double(expected.count / 4), 0.01,
                                  "rotation \(rotation), crop \(String(describing: crop)): \(differing) pixels differ")
            }
        }
    }

    /// The shape it reports is the raster's shape, so an unplaced layer
    /// is fitted the same way whichever path draws it.
    func testDisplayedSize_isTheRastersShape() throws {
        let ref = try writePDF()
        let page = try XCTUnwrap(PDFDocument(url: FileStore.url(for: ref))?.page(at: 0))
        for rotation in [0.0, 90] {
            let artwork = layer(ref, rotation: rotation, crop: CGRect(x: 0, y: 0, width: 0.5, height: 1))
            let size = try XCTUnwrap(ImportedArtwork.displayedSize(of: page, layer: artwork))
            let raster = try XCTUnwrap(artwork.image(targetSize: CGSize(width: 1200, height: 1200)))
            XCTAssertEqual(size.width / size.height, raster.size.width / raster.size.height, accuracy: 0.01)
        }
    }

    /// Export used to flatten the whole page to a bitmap, so the PDF's
    /// text was gone from the exported file: not selectable, not
    /// searchable. The page is drawn as vectors now.
    func testPDFExport_keepsTheImportedPDFsText() throws {
        let ref = try writePDF()
        let page = Page(index: 0)
        page.aspectRatio = 400.0 / 600.0
        let data = PageRenderer.pdfData(for: [(page: page, artwork: [layer(ref)])])
        let exported = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0)?.string)
        XCTAssertTrue(exported.contains(Self.text), "exported text: \(exported)")
    }

    // MARK: - The tiles on screen

    /// Hosted like the page hosts it - under a SwiftUI `.scaleEffect` -
    /// the tiles draw at the zoomed detail (sharp), and never on the main
    /// thread (invariant 10: a 16x tile of a dense page is real work).
    @MainActor
    func testTiles_drawAtTheZoomedDetail_offTheMainThread() async throws {
        let ref = try writePDF()
        ObservedTileLayer.reset()
        let view = ObservedLayerView()
        view.tiles.show(layer(ref))

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 800, height: 800)
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView:
            HostedView(view: view).frame(width: 100, height: 150)
                .scaleEffect(4, anchor: .topLeading)
                .frame(width: 800, height: 800, alignment: .topLeading))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .seconds(1.5))

        let draws = ObservedTileLayer.draws()
        XCTAssertFalse(draws.isEmpty, "no tiles drawn")
        XCTAssertFalse(draws.contains { $0.onMain }, "a tile drew on the main thread")
        XCTAssertEqual(draws.map(\.scale).max() ?? 0, 4 * window.screen.scale, accuracy: 0.01)
    }
}

private struct HostedView: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

private final class ObservedLayerView: PDFLayerView {
    override class var layerClass: AnyClass { ObservedTileLayer.self }
}

nonisolated private final class ObservedTileLayer: PDFTileLayer, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [(onMain: Bool, scale: CGFloat)] = []

    static func reset() { lock.lock(); recorded = []; lock.unlock() }
    static func draws() -> [(onMain: Bool, scale: CGFloat)] { lock.lock(); defer { lock.unlock() }; return recorded }

    override func draw(in context: CGContext) {
        Self.lock.lock()
        Self.recorded.append((Thread.isMainThread, context.userSpaceToDeviceSpaceTransform.a))
        Self.lock.unlock()
        super.draw(in: context)
    }
}
