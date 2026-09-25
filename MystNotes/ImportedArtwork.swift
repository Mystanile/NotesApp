import Foundation
import CoreGraphics
import SwiftData
#if targetEnvironment(macCatalyst) || canImport(UIKit)
import UIKit
import PDFKit
import ImageIO

/// Placement math shared by the view that renders imported artwork and the
/// overlay that lets you move/resize it, so both agree on exactly where the
/// image sits - which is what lets the selection handles hug the artwork
/// itself rather than some larger box around it.
nonisolated enum ImportedArtwork {
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
        fittedRect(for: image?.size ?? .zero, in: container)
    }

    /// Aspect-fit a picture of `natural`'s shape centered inside `container`.
    static func fittedRect(for natural: CGSize, in container: CGSize) -> CGRect {
        guard natural.width > 0, natural.height > 0,
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

    /// Applies a non-destructive crop and rotation to freshly loaded
    /// artwork. Both are baked into the returned image so every consumer
    /// (canvas, thumbnail, export) gets the same picture without each
    /// having to reimplement the transform.
    ///
    /// Order matters: rotation is applied FIRST, then the crop. The crop is
    /// recorded from handles drawn over the artwork as displayed - which is
    /// already rotated - so it's expressed in rotated space. Cropping before
    /// rotating would apply those fractions to the unrotated original and
    /// cut out the wrong region entirely.
    static func transformed(
        _ image: UIImage,
        cropX: Double?, cropY: Double?, cropWidth: Double?, cropHeight: Double?,
        rotationDegrees: Double?
    ) -> UIImage {
        let result = rotate(image, degrees: rotationDegrees)

        guard let cropX, let cropY, let cropWidth, let cropHeight,
              cropWidth > 0, cropHeight > 0,
              // Ignore nonsense values rather than produce an empty image.
              cropX >= 0, cropY >= 0, cropX + cropWidth <= 1.0001, cropY + cropHeight <= 1.0001,
              let cgImage = result.cgImage else { return result }

        let pixel = CGRect(
            x: cropX * Double(cgImage.width),
            y: cropY * Double(cgImage.height),
            width: cropWidth * Double(cgImage.width),
            height: cropHeight * Double(cgImage.height)
        ).integral
        guard let cropped = cgImage.cropping(to: pixel) else { return result }
        return UIImage(cgImage: cropped, scale: result.scale, orientation: result.imageOrientation)
    }

    /// Rotates a crop rect (fractions, rotated-display space) to stay over
    /// the same part of the picture after another quarter turn clockwise.
    /// A point (x, y) maps to (1 - y, x), so the rect's new origin comes
    /// from its old bottom-left corner and its dimensions swap.
    static func rotatingCropClockwise(x: Double, y: Double, width: Double, height: Double)
        -> (x: Double, y: Double, width: Double, height: Double) {
        (x: 1 - y - height, y: x, width: height, height: width)
    }

    private static func rotate(_ image: UIImage, degrees rotationDegrees: Double?) -> UIImage {
        let result = image
        let degrees = ((rotationDegrees ?? 0).truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        guard degrees != 0 else { return result }

        // Quarter turns swap width and height.
        let swapsAxes = degrees == 90 || degrees == 270
        let outputSize = swapsAxes
            ? CGSize(width: result.size.height, height: result.size.width)
            : result.size
        let renderer = UIGraphicsImageRenderer(size: outputSize)
        return renderer.image { context in
            let cg = context.cgContext
            cg.translateBy(x: outputSize.width / 2, y: outputSize.height / 2)
            cg.rotate(by: CGFloat(degrees) * .pi / 180)
            result.draw(in: CGRect(
                x: -result.size.width / 2, y: -result.size.height / 2,
                width: result.size.width, height: result.size.height
            ))
        }
    }

    /// Loads the artwork as an image at no more than `targetSize`,
    /// rasterizing a PDF page if needed.
    ///
    /// Photos are decoded *down* to the size asked for rather than in full.
    /// `UIImage(contentsOfFile:)` decodes every pixel the file has, so a
    /// 12-megapixel photo cost ~48 MB whether it was filling a page or a
    /// 60x80 thumbnail in the page strip - against a 96 MB artwork cache,
    /// which is why the cache thrashed and pages kept having to re-render
    /// their own background.
    static func rasterized(fileRef: String, pdfPageIndex: Int, targetSize: CGSize) -> UIImage? {
        let url = FileStore.url(for: fileRef)
        if fileRef.lowercased().hasSuffix(".pdf") {
            guard let document = PDFDocument(url: url),
                  let page = document.page(at: pdfPageIndex) else { return nil }
            return render(page, within: targetSize)
        }
        return downsampled(at: url, to: targetSize) ?? UIImage(contentsOfFile: url.path)
    }

    /// The largest dimension worth decoding for `targetSize`. Zero or
    /// nonsense means "no limit", and the full image is decoded.
    private static func maxPixelSize(for targetSize: CGSize) -> CGFloat? {
        let longest = max(targetSize.width, targetSize.height)
        guard longest.isFinite, longest >= 1 else { return nil }
        return longest.rounded()
    }

    /// ImageIO decodes straight to the requested size, so the full-size
    /// bitmap never exists. `WithTransform` applies the file's EXIF
    /// orientation, which `UIImage(contentsOfFile:)` did for us.
    private static func downsampled(at url: URL, to targetSize: CGSize) -> UIImage? {
        guard let limit = maxPixelSize(for: targetSize),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: limit
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// An image file's pixel size from its metadata, with the EXIF
    /// orientation applied - no decode at all.
    private static func imageFileSize(at url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
              width > 0, height > 0 else { return nil }
        // Orientations 5-8 are the quarter turns; they swap the axes.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }

    /// Draws a PDF page at the largest size that fits inside `bounding`,
    /// keeping its own aspect ratio exactly.
    ///
    /// `PDFPage.thumbnail(of:for:)` is the shorter way to do this, but it
    /// gives no guarantee about the size it hands back, and every caller
    /// here composites the result against a rect it computes itself - a page
    /// whose background is meant to be full bleed can't afford to be a few
    /// points off. Drawing it ourselves makes the output size exact.
    private static func render(_ page: PDFPage, within bounding: CGSize) -> UIImage? {
        let box = PDFDisplayBox.mediaBox
        guard let natural = naturalSize(of: page, box: box),
              natural.width > 0, natural.height > 0,
              bounding.width > 0, bounding.height > 0 else { return nil }

        let scale = min(bounding.width / natural.width, bounding.height / natural.height)
        let output = CGSize(width: max(natural.width * scale, 1),
                            height: max(natural.height * scale, 1))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1                      // output is already in pixels
        format.opaque = true
        return UIGraphicsImageRenderer(size: output, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: output))
            let cg = context.cgContext
            // PDFs are drawn bottom-up; PDFPage.draw applies the page's own
            // /Rotate and box origin on top of whatever transform is set.
            cg.translateBy(x: 0, y: output.height)
            cg.scaleBy(x: scale, y: -scale)
            page.draw(with: box, to: cg)
        }
    }

    /// The picture a long-press at `point` opens the handles on: the
    /// topmost one under the finger, or none. The PDF that is the page is
    /// paper and never picked (field report, Sept 25, 2026: a press
    /// anywhere on a PDF page selected all of it); its crop and rotation
    /// are in the page strip's menu instead.
    static func layerToAdjust(at point: CGPoint, in layers: [ArtworkLayer], pageSize: CGSize) -> UUID? {
        layers.reversed().first { !$0.isPaper && $0.rect(in: pageSize).contains(point) }?.id
    }

    /// Draws a PDF layer as vectors into `rect` (page points): the same
    /// picture `displayImage` bakes into a bitmap - white paper, the
    /// layer's rotation, then its crop, stretched to the rect - so it
    /// stays sharp at any zoom and an exported PDF keeps the page's real
    /// text. Every step mirrors `render`, `rotate` and `transformed`.
    static func drawPDF(_ page: PDFPage, layer: ArtworkLayer, in rect: CGRect, context cg: CGContext) {
        guard let natural = naturalSize(of: page), rect.width > 0, rect.height > 0 else { return }
        let degrees = ((layer.rotationDegrees ?? 0).truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        let rotated = displayedSize(natural: natural, rotationDegrees: degrees)
        let crop = cropRect(of: layer, in: rotated)

        cg.saveGState()
        defer { cg.restoreGState() }
        cg.clip(to: rect)
        // Rotated-and-cropped picture space onto the rect...
        cg.translateBy(x: rect.minX, y: rect.minY)
        cg.scaleBy(x: rect.width / crop.width, y: rect.height / crop.height)
        cg.translateBy(x: -crop.minX, y: -crop.minY)
        // ...the rotation about the picture's centre, as `rotate` does...
        cg.translateBy(x: rotated.width / 2, y: rotated.height / 2)
        cg.rotate(by: degrees * .pi / 180)
        cg.translateBy(x: -natural.width / 2, y: -natural.height / 2)
        // ...and the page itself, on white, bottom-up, as `render` does.
        cg.setFillColor(UIColor.white.cgColor)
        cg.fill(CGRect(origin: .zero, size: natural))
        cg.translateBy(x: 0, y: natural.height)
        cg.scaleBy(x: 1, y: -1)
        page.draw(with: .mediaBox, to: cg)
    }

    /// The shape a PDF layer shows in: its page with the layer's rotation
    /// and crop applied - what `displayImage`'s bitmap would measure.
    static func displayedSize(of page: PDFPage, layer: ArtworkLayer) -> CGSize? {
        guard let natural = naturalSize(of: page) else { return nil }
        let rotated = displayedSize(natural: natural, rotationDegrees: layer.rotationDegrees ?? 0)
        return cropRect(of: layer, in: rotated).size
    }

    /// Quarter turns swap the axes; any other angle keeps the page's
    /// size, clipping its corners, as `rotate` does.
    private static func displayedSize(natural: CGSize, rotationDegrees: Double) -> CGSize {
        let degrees = (rotationDegrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return degrees == 90 || degrees == 270 ? CGSize(width: natural.height, height: natural.width) : natural
    }

    /// The layer's crop in rotated picture space, or all of it - with the
    /// same sanity checks `transformed` applies.
    private static func cropRect(of layer: ArtworkLayer, in size: CGSize) -> CGRect {
        guard let x = layer.cropX, let y = layer.cropY, let width = layer.cropWidth, let height = layer.cropHeight,
              width > 0, height > 0, x >= 0, y >= 0, x + width <= 1.0001, y + height <= 1.0001 else {
            return CGRect(origin: .zero, size: size)
        }
        return CGRect(x: x * size.width, y: y * size.height, width: width * size.width, height: height * size.height)
    }

    /// A PDF page's size as displayed, i.e. with a 90/270-degree /Rotate
    /// already applied - the shape the page actually appears in.
    static func naturalSize(of page: PDFPage, box: PDFDisplayBox = .mediaBox) -> CGSize? {
        let bounds = page.bounds(for: box)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let quarterTurned = abs(page.rotation / 90) % 2 == 1
        return quarterTurned
            ? CGSize(width: bounds.height, height: bounds.width)
            : bounds.size
    }

    /// The artwork's natural pixel/point size, straight off disk - used to
    /// seed the initial placement before anything is rendered.
    static func naturalSize(fileRef: String, pdfPageIndex: Int) -> CGSize? {
        let url = FileStore.url(for: fileRef)
        if fileRef.lowercased().hasSuffix(".pdf") {
            guard let document = PDFDocument(url: url),
                  let page = document.page(at: pdfPageIndex) else { return nil }
            return naturalSize(of: page)
        }
        // Metadata only: this is called to seed a placement and to give an
        // imported page its shape, neither of which needs the pixels.
        return imageFileSize(at: url) ?? UIImage(contentsOfFile: url.path)?.size
    }

    /// The artwork's shape (width / height), used to give an imported page
    /// the same proportions as the document it came from.
    static func aspectRatio(fileRef: String, pdfPageIndex: Int) -> Double? {
        guard let size = naturalSize(fileRef: fileRef, pdfPageIndex: pdfPageIndex),
              size.width > 0, size.height > 0 else { return nil }
        return Double(size.width / size.height)
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


// MARK: - A page's artwork as values

/// One piece of artwork on a page, as plain values: what its
/// `ImportedDocument` says, without the model. A page's artwork is a
/// *stack* of these, bottom first - a PDF page as the paper with photos
/// placed over it - and every renderer (the live page, the thumbnails,
/// the exporter) takes the stack rather than one document. Being a value
/// type, it crosses to the render actors freely.
nonisolated struct ArtworkLayer: Hashable, Sendable, Identifiable {
    var id: UUID
    var fileRef: String
    var sourceType: String
    var pdfPageIndex: Int
    var frameX: Double?, frameY: Double?, frameWidth: Double?, frameHeight: Double?
    var cropX: Double?, cropY: Double?, cropWidth: Double?, cropHeight: Double?
    var rotationDegrees: Double?

    var isPDF: Bool { fileRef.lowercased().hasSuffix(".pdf") }

    /// A PDF page that is the page: placed edge to edge (how a PDF imports
    /// as pages), or never placed (a page from before placement existed).
    var isPaper: Bool {
        guard isPDF else { return false }
        guard let x = frameX, let y = frameY, let width = frameWidth, let height = frameHeight else { return true }
        return abs(x) < 0.001 && abs(y) < 0.001 && abs(width - 1) < 0.001 && abs(height - 1) < 0.001
    }

    /// Loads this layer at no more than `targetSize`, with its crop and
    /// rotation applied.
    func image(targetSize: CGSize) -> UIImage? {
        ImportedArtwork.displayImage(self, targetSize: targetSize)
    }

    /// Where this layer sits in `container`: its placed rect, or - never
    /// adjusted - aspect-fit centered, which is exactly where the old
    /// `.scaledToFit()` rendering put it, so existing imports keep looking
    /// identical.
    func rect(for image: UIImage?, in container: CGSize) -> CGRect {
        ImportedArtwork.placedRect(x: frameX, y: frameY, width: frameWidth, height: frameHeight, in: container)
            ?? ImportedArtwork.fittedRect(for: image, in: container)
    }

    /// The placed rect without a bitmap in hand, from the file's own
    /// proportions - for seeding the adjust handles.
    func rect(in container: CGSize) -> CGRect {
        ImportedArtwork.placedRect(x: frameX, y: frameY, width: frameWidth, height: frameHeight, in: container)
            ?? ImportedArtwork.fittedRect(fileRef: fileRef, pdfPageIndex: pdfPageIndex, in: container)
    }
}

extension ImportedArtwork {
    /// Loads a layer with its crop and rotation already applied - the
    /// single entry point the canvas, thumbnails and exports all use.
    nonisolated static func displayImage(_ layer: ArtworkLayer, targetSize: CGSize) -> UIImage? {
        guard let raw = rasterized(fileRef: layer.fileRef, pdfPageIndex: layer.pdfPageIndex,
                                   targetSize: targetSize) else { return nil }
        return transformed(
            raw,
            cropX: layer.cropX, cropY: layer.cropY,
            cropWidth: layer.cropWidth, cropHeight: layer.cropHeight,
            rotationDegrees: layer.rotationDegrees
        )
    }
}

/// Every stored field of one `ImportedDocument`, to put it back exactly -
/// undo and redo for the artwork handles.
struct ArtworkSnapshot: Equatable {
    var id: UUID
    var sourceType: String
    var fileRef: String
    var pdfPageIndex: Int
    var frameX: Double?, frameY: Double?, frameWidth: Double?, frameHeight: Double?
    var rotationDegrees: Double?
    var cropX: Double?, cropY: Double?, cropWidth: Double?, cropHeight: Double?
    var stackOrder: Int?

    init(_ doc: ImportedDocument) {
        id = doc.id; sourceType = doc.sourceType; fileRef = doc.fileRef; pdfPageIndex = doc.pdfPageIndex
        frameX = doc.frameX; frameY = doc.frameY; frameWidth = doc.frameWidth; frameHeight = doc.frameHeight
        rotationDegrees = doc.rotationDegrees
        cropX = doc.cropX; cropY = doc.cropY; cropWidth = doc.cropWidth; cropHeight = doc.cropHeight
        stackOrder = doc.stackOrder
    }

    func apply(to doc: ImportedDocument) {
        doc.sourceType = sourceType; doc.fileRef = fileRef; doc.pdfPageIndex = pdfPageIndex
        doc.frameX = frameX; doc.frameY = frameY; doc.frameWidth = frameWidth; doc.frameHeight = frameHeight
        doc.rotationDegrees = rotationDegrees
        doc.cropX = cropX; doc.cropY = cropY; doc.cropWidth = cropWidth; doc.cropHeight = cropHeight
        doc.stackOrder = stackOrder
    }
}

enum ArtworkEdits {
    /// Puts document `id` on `page` into `state`: gone (nil), or exactly
    /// the snapshot - edited in place, or re-inserted under the same id.
    /// Returns the file a removal left no document using, for the caller
    /// to trash once the change can no longer be undone - never here, or
    /// undo would bring back a picture with no file.
    @discardableResult
    static func apply(_ state: ArtworkSnapshot?, id: UUID, page: Page, in context: ModelContext) -> String? {
        let all = (try? context.fetch(FetchDescriptor<ImportedDocument>())) ?? []
        let existing = all.first { $0.id == id }
        guard let state else {
            guard let existing else { return nil }
            let ref = existing.fileRef
            context.delete(existing)
            let remaining = all.filter { $0.id != id }
            page.backgroundRef = remaining.first { $0.page?.id == page.id }?.fileRef
            return ref.isEmpty || remaining.contains { $0.fileRef == ref } ? nil : ref
        }
        if let existing {
            state.apply(to: existing)
        } else {
            let doc = ImportedDocument(sourceType: state.sourceType, fileRef: state.fileRef,
                                       pdfPageIndex: state.pdfPageIndex, page: page)
            doc.id = state.id
            state.apply(to: doc)
            context.insert(doc)
        }
        if page.backgroundRef == nil { page.backgroundRef = state.fileRef }
        return nil
    }
}

@MainActor
extension ArtworkLayer {
    init(_ doc: ImportedDocument) {
        self.init(
            id: doc.id, fileRef: doc.fileRef, sourceType: doc.sourceType, pdfPageIndex: doc.pdfPageIndex,
            frameX: doc.frameX, frameY: doc.frameY, frameWidth: doc.frameWidth, frameHeight: doc.frameHeight,
            cropX: doc.cropX, cropY: doc.cropY, cropWidth: doc.cropWidth, cropHeight: doc.cropHeight,
            rotationDegrees: doc.rotationDegrees
        )
    }

    /// The page's stack, bottom first, from the documents the caller
    /// already holds. A page from before `ImportedDocument` existed has
    /// only a `backgroundRef`; that is one unplaced layer, keyed by the
    /// page so it still has an identity to adjust by.
    static func stack(for page: Page, documents: [ImportedDocument]) -> [ArtworkLayer] {
        let docs = ImportedDocument.stack(on: page.id, in: documents)
        if !docs.isEmpty { return docs.map(ArtworkLayer.init) }
        guard let ref = page.backgroundRef, !ref.isEmpty else { return [] }
        return [ArtworkLayer(id: page.id, fileRef: ref, sourceType: ref.lowercased().hasSuffix(".pdf") ? "pdf" : "image",
                             pdfPageIndex: 0)]
    }

    /// Same, for a stack already grouped by `ImportedDocument.stacksByPage`.
    static func stack(for page: Page, stacked: [UUID: [ImportedDocument]]) -> [ArtworkLayer] {
        stack(for: page, documents: stacked[page.id] ?? [])
    }
}
#endif
