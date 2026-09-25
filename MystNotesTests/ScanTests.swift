import XCTest
import PDFKit
import UIKit
@testable import Mystnotes

/// Scanned pages become a PDF with the words Vision reads laid invisibly
/// over each picture, so a scan is searchable and exports its text.
final class ScanTests: XCTestCase {

    private func page(_ text: String) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 1600), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1200, height: 1600))
            NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 72)])
                .draw(at: CGPoint(x: 100, y: 300))
        }
    }

    func testScan_becomesAPDFWithItsTextReadable() async throws {
        let data = await ScanToPDF.pdf(from: [page("Entropy lecture"), page("Second page")])
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(document.pageCount, 2)
        let first = try XCTUnwrap(document.page(at: 0)?.string)
        XCTAssertTrue(first.localizedCaseInsensitiveContains("Entropy lecture"), "text layer: \(first)")
        XCTAssertTrue(try XCTUnwrap(document.page(at: 1)?.string).localizedCaseInsensitiveContains("Second page"))
        // The page is the scan's shape.
        let bounds = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width / bounds.height, 1200.0 / 1600.0, accuracy: 0.01)
    }
}
