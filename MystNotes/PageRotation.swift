import Foundation
import CoreGraphics
#if targetEnvironment(macCatalyst) || canImport(UIKit)
import PencilKit

/// Rotate Page, from the page strip's menu: a PDF page that came in
/// sideways turns upright, and everything written on it turns with it.
///
/// Pages are a fixed height (`PageGeometry.nominalHeight`), so a quarter
/// turn of a W x N page lands on an N/a x N page (a = W/N) - scaled by
/// exactly 1/a both ways. Four turns multiply back to 1 with no rounding.
enum PageRotation {
    /// The quarter turn of a page of aspect `aspect` (width/height), in
    /// page points, and the aspect it lands on.
    static func quarterTurn(aspect: CGFloat, clockwise: Bool) -> (transform: CGAffineTransform, newAspect: CGFloat) {
        let height = PageGeometry.nominalHeight
        let width = height * aspect
        let scale = 1 / aspect
        // Clockwise: (x, y) -> (s(H - y), s x). Counter-clockwise:
        // (x, y) -> (s y, s(W - x)). CGAffineTransform: x' = ax + cy + tx.
        let transform = clockwise
            ? CGAffineTransform(a: 0, b: scale, c: -scale, d: 0, tx: scale * height, ty: 0)
            : CGAffineTransform(a: 0, b: -scale, c: scale, d: 0, tx: 0, ty: scale * width)
        return (transform, scale)
    }

    /// A box on the page keeps its size and stays upright; its centre
    /// moves with the page. Text, stickers and link anchors are read the
    /// right way up, whichever way the paper under them turned.
    static func moved(_ rect: CGRect, by transform: CGAffineTransform) -> CGRect {
        let center = CGPoint(x: rect.midX, y: rect.midY).applying(transform)
        return CGRect(x: center.x - rect.width / 2, y: center.y - rect.height / 2,
                      width: rect.width, height: rect.height)
    }

    /// Turns `page` a quarter and returns its ink turned with it, for the
    /// caller to save. The PDF that is the page rotates; the page takes the
    /// turned shape; photos, text, stickers and link anchors move with it.
    /// Ink goes through `PKDrawing.transformed`, which keeps each stroke's
    /// creation date and seed - its id (invariant 6).
    static func rotate(_ page: Page, clockwise: Bool, documents: [ImportedDocument], links: [Link],
                       drawing: PKDrawing) -> PKDrawing {
        let aspect = PageGeometry.aspectRatio(page.aspectRatio)
        let oldSize = CGSize(width: PageGeometry.nominalHeight * aspect, height: PageGeometry.nominalHeight)
        let (transform, newAspect) = quarterTurn(aspect: aspect, clockwise: clockwise)
        let newSize = CGSize(width: PageGeometry.nominalHeight * newAspect, height: PageGeometry.nominalHeight)

        for doc in ImportedDocument.stack(on: page.id, in: documents) {
            if ArtworkLayer(doc).isPaper {
                doc.rotationDegrees = (((doc.rotationDegrees ?? 0) + (clockwise ? 90 : 270))
                    .truncatingRemainder(dividingBy: 360))
                if let x = doc.cropX, let y = doc.cropY, let w = doc.cropWidth, let h = doc.cropHeight {
                    var crop = (x: x, y: y, width: w, height: h)
                    for _ in 0..<(clockwise ? 1 : 3) {
                        crop = ImportedArtwork.rotatingCropClockwise(x: crop.x, y: crop.y, width: crop.width, height: crop.height)
                    }
                    (doc.cropX, doc.cropY, doc.cropWidth, doc.cropHeight) = (crop.x, crop.y, crop.width, crop.height)
                }
            } else if let rect = ImportedArtwork.placedRect(x: doc.frameX, y: doc.frameY, width: doc.frameWidth,
                                                            height: doc.frameHeight, in: oldSize),
                      let fractions = ImportedArtwork.fractions(of: moved(rect, by: transform), in: newSize) {
                (doc.frameX, doc.frameY, doc.frameWidth, doc.frameHeight) =
                    (fractions.x, fractions.y, fractions.width, fractions.height)
            }
        }
        for block in page.textBlocks ?? [] {
            let rect = moved(CGRect(x: block.frameX, y: block.frameY, width: block.frameWidth, height: block.frameHeight), by: transform)
            (block.frameX, block.frameY) = (rect.minX, rect.minY)
        }
        for sticker in page.stickers ?? [] {
            let rect = moved(CGRect(x: sticker.frameX, y: sticker.frameY, width: sticker.frameWidth, height: sticker.frameHeight), by: transform)
            (sticker.frameX, sticker.frameY) = (rect.minX, rect.minY)
        }
        for link in links where link.sourcePageID == page.id {
            let rect = moved(CGRect(x: link.anchorX, y: link.anchorY, width: link.anchorWidth, height: link.anchorHeight), by: transform)
            (link.anchorX, link.anchorY) = (rect.minX, rect.minY)
        }
        page.aspectRatio = Double(newAspect)
        return drawing.transformed(using: transform)
    }
}
#endif
