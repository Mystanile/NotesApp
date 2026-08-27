import SwiftUI
import SwiftData
#if targetEnvironment(macCatalyst) || canImport(UIKit)
import UIKit
import PDFKit
#elseif canImport(AppKit)
import AppKit
import PDFKit
#endif

/// Renders an imported PDF page or image as a page's background, in place
/// of the plain paper-template background, whenever the page has a
/// backgroundRef set. PDF pages are rasterized to a UIImage via PDFKit's
/// built-in thumbnail renderer rather than an embedded interactive
/// PDFView — simpler, and keeps the coordinate space straightforward to
/// combine with the PencilKit annotation layer sitting on top of it.
struct ImportedPageBackgroundView: View {
    let page: Page
    /// While the adjust handles are up, the in-progress rect (in page
    /// points) so the artwork moves and resizes live under the handles
    /// instead of only jumping once the placement is committed.
    var liveFrame: CGRect? = nil

    @Query private var allImportedDocuments: [ImportedDocument]
    #if targetEnvironment(macCatalyst) || canImport(UIKit)
    @State private var image: UIImage?
    #else
    @State private var image: Any? = nil
    #endif

    private var importedDocument: ImportedDocument? {
        allImportedDocuments.first { $0.page?.id == page.id }
    }

    /// Reload when the file, its crop, or its rotation changes - the frame
    /// isn't included, since resizing doesn't need a re-render.
    private var imageKey: String {
        let doc = importedDocument
        let values: [Double?] = [doc?.rotationDegrees, doc?.cropX, doc?.cropY, doc?.cropWidth, doc?.cropHeight]
        return ([page.backgroundRef ?? "-"] + values.map { $0.map { String(format: "%.4f", $0) } ?? "-" })
            .joined(separator: "|")
    }

    /// The artwork's placed rect. This is the image's *actual* on-page rect,
    /// not a box it's letterboxed inside - the image is drawn to exactly
    /// fill it, and resizing preserves aspect ratio, so the selection
    /// handles can hug the artwork the way Google Docs/Freeform do.
    private func artworkFrame(in size: CGSize) -> CGRect {
        if let liveFrame { return liveFrame }
        if let doc = importedDocument,
           let placed = ImportedArtwork.placedRect(
               x: doc.frameX, y: doc.frameY, width: doc.frameWidth, height: doc.frameHeight, in: size
           ) {
            return placed
        }
        // Never adjusted: aspect-fit centered on the page, which is exactly
        // what the old .scaledToFit() rendering produced - so existing
        // imports keep looking identical, just with an explicit frame.
        return ImportedArtwork.fittedRect(for: image, in: size)
    }

    var body: some View {
        GeometryReader { geometry in
            let frame = artworkFrame(in: geometry.size)
            ZStack(alignment: .topLeading) {
                Color.white
        #if targetEnvironment(macCatalyst) || canImport(UIKit)
                if let image {
                    // Fills the frame exactly (no .scaledToFit letterboxing
                    // inside it) - the frame IS the image's rect, and
                    // resizing keeps its aspect ratio, so this never
                    // distorts.
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
        #else
                // On macOS without UIKit, show a placeholder or implement alternative
                if image != nil {
                    Rectangle()
                        .fill(Color.blue.opacity(0.3))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
        #endif
            }
            .task(id: imageKey) {
                loadImage(targetSize: geometry.size)
            }
        }
    }

    private func loadImage(targetSize: CGSize) {
        guard let ref = page.backgroundRef else {
            image = nil
            return
        }
        #if targetEnvironment(macCatalyst) || canImport(UIKit)
        let renderSize = (targetSize.width > 0 && targetSize.height > 0)
            ? targetSize
            : CGSize(width: 1000, height: 1300)
        // Crop and rotation are applied here, by the same helper the
        // thumbnails and exports use.
        image = ImportedArtwork.displayImage(
            fileRef: ref,
            document: importedDocument,
            targetSize: renderSize
        )
        #else
        // Not available on native macOS (no UIKit image loading).
        image = nil
        #endif
    }
}