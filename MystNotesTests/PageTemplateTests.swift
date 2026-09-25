import XCTest
import UIKit
@testable import Mystnotes

/// The papers, drawn by the one ruling renderer the editor, thumbnails
/// and exports share.
final class PageTemplateTests: XCTestCase {

    private let size = CGSize(width: 780, height: 1040)

    private func render(_ template: String) throws -> (px: [UInt8], width: Int) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            PageTemplate.draw(template, in: size, context: context.cgContext)
        }
        let cg = try XCTUnwrap(image.cgImage)
        var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        px.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8,
                      bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                .draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return (px, cg.width)
    }

    private func darkest(_ r: (px: [UInt8], width: Int), column x: Int) -> UInt8 {
        stride(from: 0, to: Int(size.height), by: 1).map { r.px[($0 * r.width + x) * 4] }.min() ?? 255
    }

    func testEveryPaperButBlank_drawsSomething() throws {
        for option in PageTemplate.options {
            let r = try render(option.id)
            let marked = stride(from: 0, to: r.px.count, by: 4).contains { r.px[$0] < 250 }
            XCTAssertEqual(marked, option.id != "blank", option.id)
        }
        XCTAssertTrue(PageTemplate.options.contains { $0.id == "engineering" })
        XCTAssertTrue(PageTemplate.options.contains { $0.id == "cornell" })
    }

    /// Engineering paper: a fine grid with every fifth line heavier.
    func testEngineering_hasHeavierMajorLines() throws {
        let r = try render("engineering")
        let spacing = Int(PageTemplate.engineeringSpacing)
        let minor = darkest(r, column: spacing), major = darkest(r, column: spacing * 5)
        XCTAssertLessThan(major, minor, "a major line should be darker than a minor one")
        XCTAssertLessThan(minor, 250, "minor lines are drawn")
    }

    /// Cornell: a cue column down the left, over lined paper.
    func testCornell_hasACueColumn() throws {
        let r = try render("cornell")
        let x = Int(size.width * PageTemplate.cornellCueFraction)
        XCTAssertLessThan(darkest(r, column: x), 200, "the cue column's line")
    }

    /// A paper this build doesn't know - a newer build's - is blank, not
    /// an error.
    func testUnknownPaper_isBlank() throws {
        XCTAssertTrue(PageTemplate.isEmpty("hexagons"))
    }
}
