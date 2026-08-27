import Foundation
import CoreGraphics
#if targetEnvironment(macCatalyst) || canImport(UIKit)
import UIKit
import PDFKit

/// Placement math shared by the view that renders imported artwork and the
/// overlay that lets you move/resize it, so both agree on exactly where the
/// image sits - which is what lets the selection handles hug the artwork
/// itself rather than some larger box around it.
enum ImportedArtwork {
    /// Aspect-fit `image` centered inside `container`. Matches what
    /// `.scaledToFit()` in a full-page frame used to produce, so artwork
    /// imported before placement was adjustable renders unchanged.
    static func fittedRect(for image: UIImage?, in container: CGSize) -> CGRect {
        guard let image, image.size.width > 0, image.size.height > 0,
              container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / image.size.width, container.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    /// The artwork's natural pixel/point size, straight off disk - used to
    /// seed the initial placement before anything is rendered.
    static func naturalSize(fileRef: String, pdfPageIndex: Int) -> CGSize? {
        let url = FileStore.url(for: fileRef)
        if fileRef.lowercased().hasSuffix(".pdf") {
            guard let document = PDFDocument(url: url),
                  let page = document.page(at: pdfPageIndex) else { return nil }
            let bounds = page.bounds(for: .mediaBox)
            return CGSize(width: bounds.width, height: bounds.height)
        }
        return UIImage(contentsOfFile: url.path)?.size
    }

    /// Aspect-fit the artwork named by `fileRef` inside `container`.
    static func fittedRect(fileRef: String, pdfPageIndex: Int, in container: CGSize) -> CGRect {
        guard let natural = naturalSize(fileRef: fileRef, pdfPageIndex: pdfPageIndex),
              natural.width > 0, natural.height > 0,
              container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / natural.width, container.height / natural.height)
        let size = CGSize(width: natural.width * scale, height: natural.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}
#endif
