import XCTest
import SwiftData
import PDFKit
import UIKit
@testable import Mystnotes

/// Stickers, link anchors and typed text reach exports and thumbnails
/// (invariant 9). Exports used to drop stickers and link anchors, and
/// thumbnails had no text (Sept 25, 2026).
final class PageElementsExportTests: XCTestCase {

    private static let schema = Schema([
        Folder.self, Notebook.self, Page.self, TypedTextBlock.self,
        ImportedDocument.self, Link.self, Sticker.self
    ])

    @MainActor
    private func twoPages() throws -> (ModelContext, Page, Page) {
        let container = try ModelContainer(for: Self.schema,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let first = Page(index: 0), second = Page(index: 1)
        context.insert(first); context.insert(second)
        return (context, first, second)
    }

    /// Non-white pixels inside `rect` (page points) of an image of the page.
    private func inkedPixels(in rect: CGRect, of image: UIImage) throws -> Int {
        let cg = try XCTUnwrap(image.cgImage)
        let scale = CGFloat(cg.width) / image.size.width
        var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        px.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8,
                      bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                .draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        var count = 0
        for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
            for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                let i = (y * cg.width + x) * 4
                if px[i] < 200 || px[i + 1] < 200 || px[i + 2] < 200 { count += 1 }
            }
        }
        return count
    }

    @MainActor
    func testImageExport_drawsStickersAndLinkAnchors() throws {
        let (context, page, other) = try twoPages()
        let sticker = Sticker(assetRef: "star.fill", page: page)
        (sticker.frameX, sticker.frameY, sticker.frameWidth, sticker.frameHeight) = (100, 100, 60, 60)
        context.insert(sticker)
        page.stickers = [sticker]
        let link = Link(sourcePageID: page.id, destinationPageID: other.id)
        (link.anchorX, link.anchorY) = (300, 500)
        context.insert(link)
        try context.save()

        let image = PageRenderer.image(for: page, artwork: [], scale: 1)
        XCTAssertGreaterThan(try inkedPixels(in: CGRect(x: 100, y: 100, width: 60, height: 60), of: image), 400,
                             "no sticker in the export")
        XCTAssertGreaterThan(try inkedPixels(in: CGRect(x: 300, y: 500, width: 44, height: 44), of: image), 300,
                             "no link anchor in the export")
    }

    /// A link in an exported notebook is a real PDF link to its page.
    @MainActor
    func testPDFExport_linkJumpsToItsPage() throws {
        let (context, page, other) = try twoPages()
        let link = Link(sourcePageID: page.id, destinationPageID: other.id)
        (link.anchorX, link.anchorY) = (300, 500)
        context.insert(link)
        try context.save()

        let data = PageRenderer.pdfData(for: [(page: page, artwork: []), (page: other, artwork: [])])
        let document = try XCTUnwrap(PDFDocument(data: data))
        let annotations = try XCTUnwrap(document.page(at: 0)).annotations
        let target = annotations.compactMap { ($0.action as? PDFActionGoTo)?.destination.page ?? $0.destination?.page }.first
        XCTAssertNotNil(target, "no link on page 1: \(annotations.map(\.type))")
        XCTAssertEqual(target.map { document.index(for: $0) }, 1)
    }

    /// Thumbnails show typed text now, not just ink and artwork.
    @MainActor
    func testThumbnail_drawsTypedText() async throws {
        let (context, page, _) = try twoPages()
        let block = TypedTextBlock(content: "MMMMMMMM MMMMMMMM", page: page)
        (block.frameX, block.frameY, block.frameWidth, block.frameHeight) = (40, 40, 600, 200)
        block.fontSize = 60
        context.insert(block)
        page.textBlocks = [block]
        page.template = "lined"   // the whole-page path, not the fit-to-ink one
        let nominal = PageGeometry.contentSize(for: page)
        let request = PageThumbnailRequest(pageID: page.id, inkStamp: "-", template: page.template, artwork: [],
                                           elements: PageElements(page: page), nominal: nominal,
                                           output: CGSize(width: nominal.width / 2, height: nominal.height / 2))
        let rendered = await PageThumbnailRenderer.render(request)
        let image = try XCTUnwrap(rendered)
        let textRegion = CGRect(x: 20, y: 20, width: 300, height: 60)   // in thumbnail points
        XCTAssertGreaterThan(try inkedPixels(in: textRegion, of: image), 500, "no text in the thumbnail")
    }

    /// A turned sticker exports turned: a wide symbol at 90 degrees is tall.
    func testRotatedSticker_exportsRotated() throws {
        func inkedBounds(rotation: Double) throws -> CGRect {
            let elements = PageElements(stickers: [.init(name: "rectangle.fill", frame: CGRect(x: 100, y: 100, width: 200, height: 200),
                                                         rotation: rotation)])
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 400), format: format).image { context in
                UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
                elements.draw(in: CGSize(width: 400, height: 400))
            }
            let cg = try XCTUnwrap(image.cgImage)
            var px = [UInt8](repeating: 0, count: 400 * 400 * 4)
            px.withUnsafeMutableBytes { raw in
                CGContext(data: raw.baseAddress, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 1600,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    .draw(cg, in: CGRect(x: 0, y: 0, width: 400, height: 400))
            }
            var box = CGRect.null
            for y in 0..<400 { for x in 0..<400 where px[(y * 400 + x) * 4 + 2] < 128 {
                box = box.union(CGRect(x: x, y: y, width: 1, height: 1)) } }
            return box
        }
        let flat = try inkedBounds(rotation: 0), turned = try inkedBounds(rotation: 90)
        XCTAssertGreaterThan(flat.width, flat.height * 1.2, "rectangle.fill should be wide: \(flat)")
        XCTAssertGreaterThan(turned.height, turned.width * 1.2, "turned 90 it should be tall: \(turned)")
    }
}
