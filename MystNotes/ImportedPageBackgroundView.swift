import SwiftUI
import SwiftData
#if targetEnvironment(macCatalyst) || canImport(UIKit)
import UIKit
import PDFKit
#elseif canImport(AppKit)
import AppKit
import PDFKit
#endif

#if targetEnvironment(macCatalyst) || canImport(UIKit)

/// Everything a page's artwork bitmap depends on. Used as the cache key
/// directly - a struct with a `renderSize` in it is exactly "this picture at
/// this resolution", and there is no string to get subtly wrong.
nonisolated struct ArtworkRequest: Hashable, Sendable {
    var pageID: UUID
    var backgroundRef: String
    var pdfPageIndex: Int
    var cropX: Double?, cropY: Double?, cropWidth: Double?, cropHeight: Double?
    var rotationDegrees: Double?
    /// In pixels, already rounded, so a layout pass that reports a size a
    /// hair different doesn't invent a second entry for the same picture.
    var renderSize: CGSize
}

/// Rasterizes one page's imported artwork. Capture-free and off the main
/// actor (invariant 10): rasterizing a PDF page at 2.5x was a visible stall
/// on every page turn. `PageBitmaps.artwork` owns the caching.
nonisolated enum ArtworkRenderer {
    static func render(_ request: ArtworkRequest) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let raw = ImportedArtwork.rasterized(
                fileRef: request.backgroundRef,
                pdfPageIndex: request.pdfPageIndex,
                targetSize: request.renderSize
            ) else { return nil }
            return ImportedArtwork.transformed(
                raw,
                cropX: request.cropX, cropY: request.cropY,
                cropWidth: request.cropWidth, cropHeight: request.cropHeight,
                rotationDegrees: request.rotationDegrees
            )
        }.value
    }
}
#endif

/// Renders an imported PDF page or photo **on top of** the page's paper,
/// whenever the page has a `backgroundRef` set. It used to render *instead*
/// of the paper, with its own white fill - which is why importing a photo
/// made a lined or grid page go blank. The paper (`PageBackgroundView`) is
/// drawn underneath by the detail view; this layer is transparent except
/// where the artwork is.
///
/// PDF pages are rasterized to a UIImage via PDFKit rather than an embedded
/// interactive PDFView - simpler, and it keeps the coordinate space
/// straightforward to combine with the PencilKit annotation layer on top.
struct ImportedPageBackgroundView: View {
    let page: Page
    /// While the adjust handles are up, the in-progress rect (in page
    /// points) so the artwork moves and resizes live under the handles
    /// instead of only jumping once the placement is committed.
    var liveFrame: CGRect? = nil

    @Query private var allImportedDocuments: [ImportedDocument]

    private var importedDocument: ImportedDocument? {
        allImportedDocuments.first { $0.page?.id == page.id }
    }

    #if targetEnvironment(macCatalyst) || canImport(UIKit)
    private var store: BitmapStore<ArtworkRequest> { PageBitmaps.artwork }

    /// The background is laid out in page points and then scaled up by the
    /// canvas zoom, so it has to be rasterized above 1:1 or an imported PDF
    /// template turns to mush the moment you pinch in to write on it.
    private static let oversampling: CGFloat = 2.5

    private func renderSize(for targetSize: CGSize) -> CGSize {
        let pageSize = (targetSize.width > 0 && targetSize.height > 0)
            ? targetSize
            : PageGeometry.contentSize(for: page)
        return CGSize(width: (pageSize.width * Self.oversampling).rounded(),
                      height: (pageSize.height * Self.oversampling).rounded())
    }

    /// What this page's artwork is, at the size it needs to be drawn.
    ///
    /// The page id and `pdfPageIndex` are load-bearing: every page of a
    /// ten-page PDF import shares one `backgroundRef` with no crop and no
    /// rotation, so a key built from those alone was identical on all ten
    /// and page 1's bitmap showed up on every one of them.
    private func artworkRequest(for targetSize: CGSize) -> ArtworkRequest? {
        guard let ref = page.backgroundRef else { return nil }
        let doc = importedDocument
        return ArtworkRequest(
            pageID: page.id,
            backgroundRef: ref,
            pdfPageIndex: doc?.pdfPageIndex ?? 0,
            cropX: doc?.cropX, cropY: doc?.cropY,
            cropWidth: doc?.cropWidth, cropHeight: doc?.cropHeight,
            rotationDegrees: doc?.rotationDegrees,
            renderSize: renderSize(for: targetSize)
        )
    }

    /// The artwork's placed rect. This is the image's *actual* on-page rect,
    /// not a box it's letterboxed inside - the image is drawn to exactly
    /// fill it, and resizing preserves aspect ratio, so the selection
    /// handles can hug the artwork the way Google Docs/Freeform do.
    private func artworkFrame(for image: UIImage?, in size: CGSize) -> CGRect {
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

    /// `.task(id:)` restarts on either of these changing: a different
    /// picture, or the store dropping what it had.
    private struct LoadID: Equatable {
        var request: ArtworkRequest?
        var generation: Int
    }
    #endif

    var body: some View {
        GeometryReader { geometry in
        #if targetEnvironment(macCatalyst) || canImport(UIKit)
            let request = artworkRequest(for: geometry.size)
            // Read through the store, not a view-local @State: whoever
            // rendered this bitmap, this view gets it, and it appears the
            // frame it lands rather than only after something else happens
            // to re-evaluate the body.
            let shown = request.flatMap { store.image(for: $0) }
            let frame = artworkFrame(for: shown, in: geometry.size)
            ZStack(alignment: .topLeading) {
                // Deliberately no paper here - see the type's comment.
                Color.clear
                if let shown {
                    // Fills the frame exactly (no .scaledToFit letterboxing
                    // inside it) - the frame IS the image's rect, and
                    // resizing keeps its aspect ratio, so this never
                    // distorts.
                    Image(uiImage: shown)
                        .resizable()
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
            .task(id: LoadID(request: request, generation: store.generation)) {
                if let request { store.request(request) }
            }
        #else
            // On macOS without UIKit there is no rasterizer; the paper
            // underneath still renders.
            Color.clear
        #endif
        }
    }
}
