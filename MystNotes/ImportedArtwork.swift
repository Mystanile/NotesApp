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
    /// The artwork's rect in `container`'s coordinates, from the fractional
    /// frame stored on the document - or nil when it has never been placed.
    ///
    /// Frames whose fractions fall outside a sane range are treated as
    /// unplaced: an earlier build of this branch stored absolute points in
    /// these same fields, and interpreting those as fractions would blow the
    /// artwork up to hundreds of times the page size.
    static func placedRect(x: Double?, y: Double?, width: Double?, height: Double?, in container: CGSize) -> CGRect? {
        guard let x, let y, let width, let height,
              width > 0, height > 0,
              abs(x) <= 2, abs(y) <= 2, width <= 2, height <= 2 else { return nil }
        return CGRect(
            x: x * container.width,
            y: y * container.height,
            width: width * container.width,
            height: height * container.height
        )
    }

    /// Inverse of `placedRect` - points back to storable fractions.
    static func fractions(of rect: CGRect, in container: CGSize) -> (x: Double, y: Double, width: Double, height: Double)? {
        guard container.width > 0, container.height > 0 else { return nil }
        return (
            x: rect.origin.x / container.width,
            y: rect.origin.y / container.height,
            width: rect.width / container.width,
            height: rect.height / container.height
        )
    }

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

    /// Loads the artwork as an image, rasterizing a PDF page if needed.
    /// `targetSize` only guides PDF rasterization quality; photos come back
    /// at their natural size.
    static func rasterized(fileRef: String, pdfPageIndex: Int, targetSize: CGSize) -> UIImage? {
        let url = FileStore.url(for: fileRef)
        if fileRef.lowercased().hasSuffix(".pdf") {
            guard let document = PDFDocument(url: url),
                  let page = document.page(at: pdfPageIndex) else { return nil }
            return page.thumbnail(of: targetSize, for: .mediaBox)
        }
        return UIImage(contentsOfFile: url.path)
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
