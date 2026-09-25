import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
import Vision
import VisionKit

/// Scanned pages (VisionKit's document camera) as a PDF: each page the
/// scan's own shape, with the words Vision reads on it laid invisibly over
/// the picture - so a scan is searchable, and its exported PDF carries its
/// text, like any other imported PDF.
nonisolated enum ScanToPDF {
    static func pdf(from images: [UIImage]) async -> Data {
        var pages: [(image: UIImage, words: [(text: String, box: CGRect)])] = []
        for image in images {
            pages.append((image, await words(in: image)))
        }
        guard let first = pages.first else { return Data() }
        return UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: first.image.size)).pdfData { context in
            for page in pages {
                let bounds = CGRect(origin: .zero, size: page.image.size)
                context.beginPage(withBounds: bounds, pageInfo: [:])
                page.image.draw(in: bounds)
                for word in page.words {
                    // Vision's box is normalized and bottom-up.
                    let rect = CGRect(x: word.box.minX * bounds.width, y: (1 - word.box.maxY) * bounds.height,
                                      width: word.box.width * bounds.width, height: word.box.height * bounds.height)
                    let font = UIFont.systemFont(ofSize: max(rect.height * 0.8, 1))
                    let text = NSAttributedString(string: word.text, attributes: [.font: font, .foregroundColor: UIColor.clear])
                    // Stretched to the box, so a selection lines up with the ink.
                    let natural = text.size()
                    let cg = context.cgContext
                    cg.saveGState()
                    cg.translateBy(x: rect.minX, y: rect.minY)
                    if natural.width > 0 { cg.scaleBy(x: rect.width / natural.width, y: 1) }
                    text.draw(at: .zero)
                    cg.restoreGState()
                }
            }
        }
    }

    /// Lines of text Vision finds on one page, with their boxes.
    private static func words(in image: UIImage) async -> [(text: String, box: CGRect)] {
        guard let cgImage = image.cgImage else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            do {
                try VNImageRequestHandler(cgImage: cgImage, orientation: .up).perform([request])
            } catch {
                return []
            }
            return (request.results ?? []).compactMap { observation in
                observation.topCandidates(1).first.map { (text: $0.string, box: observation.boundingBox) }
            }
        }.value
    }
}

/// VisionKit's document camera, handing back its pages as images.
struct DocumentScannerView: UIViewControllerRepresentable {
    var onFinish: ([UIImage]) -> Void
    var onCancel: () -> Void

    static var isAvailable: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScannerView
        init(parent: DocumentScannerView) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            parent.onFinish((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.onCancel()
        }
    }
}
#endif
