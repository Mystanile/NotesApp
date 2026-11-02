import XCTest
import UIKit
@testable import Mystnotes

/// Paper colour and line spacing: display preferences resolved into one
/// `PaperStyle` that the page, thumbnails and exports share.
final class PaperStyleTests: XCTestCase {

    func testSpacingMultiplier_perOption() {
        XCTAssertEqual(LineSpacingOption.narrow.multiplier, 0.8, accuracy: 0.0001)
        XCTAssertEqual(LineSpacingOption.normal.multiplier, 1, accuracy: 0.0001)
        XCTAssertEqual(LineSpacingOption.wide.multiplier, 1.25, accuracy: 0.0001)
    }

    func testResolution_fromStoredValues() {
        XCTAssertEqual(PaperStyle.resolve(colorRaw: "cream", spacingRaw: "wide"),
                       PaperStyle(color: .cream, spacing: .wide))
        XCTAssertEqual(PaperStyle.resolve(colorRaw: "dark", spacingRaw: "narrow").isDark, true)
        XCTAssertEqual(PaperStyle.resolve(colorRaw: nil, spacingRaw: nil), .standard)
        XCTAssertEqual(PaperStyle.resolve(colorRaw: "bogus", spacingRaw: "bogus"), .standard)
    }

    func testDarkPaper_values() {
        let style = PaperStyle(color: .dark, spacing: .normal)
        XCTAssertEqual(style.fillRGB.r, 0x1E / 255, accuracy: 0.001)
        XCTAssertEqual(style.fillRGB.g, 0x1F / 255, accuracy: 0.001)
        XCTAssertEqual(style.fillRGB.b, 0x24 / 255, accuracy: 0.001)
        XCTAssertEqual(style.rulingRGBA.r, 1)
        XCTAssertEqual(style.rulingRGBA.a, 0.18, accuracy: 0.001)
    }

    func testOutputStyle_darkBecomesWhite_creamStays() {
        let dark = PaperStyle(color: .dark, spacing: .wide).outputStyle
        XCTAssertEqual(dark.color, .white)
        XCTAssertEqual(dark.spacing, .wide)
        XCTAssertEqual(PaperStyle(color: .cream, spacing: .normal).outputStyle.color, .cream)
    }

    func testThumbnailRequest_hashDiffersBetweenPaperStyles() {
        func request(_ paper: PaperStyle) -> PageThumbnailRequest {
            PageThumbnailRequest(pageID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                 inkStamp: "-", template: "lined", artwork: [],
                                 nominal: CGSize(width: 100, height: 100),
                                 output: CGSize(width: 50, height: 50), paper: paper)
        }
        let white = request(.standard)
        let cream = request(PaperStyle(color: .cream, spacing: .normal))
        let wide = request(PaperStyle(color: .white, spacing: .wide))
        XCTAssertNotEqual(white, cream)
        XCTAssertNotEqual(white, wide)
        XCTAssertNotEqual(white.hashValue, cream.hashValue)
        XCTAssertEqual(white, request(.standard))
    }

    /// Rows of the lined template land at the scaled spacing.
    func testLinedRuling_followsSpacing() throws {
        let size = CGSize(width: 200, height: 200)
        func rowsWithInk(_ paper: PaperStyle) throws -> [Int] {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
                PageTemplate.draw("lined", in: size, context: ctx.cgContext, paper: paper)
            }
            let cg = try XCTUnwrap(image.cgImage)
            var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            px.withUnsafeMutableBytes { raw in
                CGContext(data: raw.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8,
                          bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    .draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            }
            return (0..<cg.height).filter { px[($0 * cg.width + 100) * 4] < 250 }
        }
        let normal = try rowsWithInk(.standard)
        let narrow = try rowsWithInk(PaperStyle(color: .white, spacing: .narrow))
        let wide = try rowsWithInk(PaperStyle(color: .white, spacing: .wide))
        XCTAssertGreaterThan(narrow.count, normal.count)
        XCTAssertLessThan(wide.count, normal.count)
    }

    /// Dark paper exports on white: the corner pixel is white, not #1E1F24.
    @MainActor
    func testDarkPaper_exportsUseWhiteFill() throws {
        let saved = AppSettings.paperColorRaw
        defer { AppSettings.paperColorRaw = saved }
        AppSettings.paperColorRaw = PaperColor.dark.rawValue

        let page = Page()
        let image = PageRenderer.image(for: page, artwork: [], scale: 1)
        let cg = try XCTUnwrap(image.cgImage)
        var px = [UInt8](repeating: 0, count: 4)
        px.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                .draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1), byTiling: false)
        }
        XCTAssertGreaterThan(Int(px[0]) + Int(px[1]) + Int(px[2]), 3 * 250, "a dark paper must export on white")
    }
}
