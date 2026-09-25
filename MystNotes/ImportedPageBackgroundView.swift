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

/// Everything one artwork bitmap depends on. Used as the cache key
/// directly - a struct with a `renderSize` in it is exactly "this picture at
/// this resolution", and there is no string to get subtly wrong.
nonisolated struct ArtworkRequest: Hashable, Sendable {
    var pageID: UUID
    var fileRef: String
    var pdfPageIndex: Int
    var cropX: Double?, cropY: Double?, cropWidth: Double?, cropHeight: Double?
    var rotationDegrees: Double?
    /// In pixels, already rounded, so a layout pass that reports a size a
    /// hair different doesn't invent a second entry for the same picture.
    var renderSize: CGSize

    init(pageID: UUID, fileRef: String, pdfPageIndex: Int,
         cropX: Double?, cropY: Double?, cropWidth: Double?, cropHeight: Double?,
         rotationDegrees: Double?, renderSize: CGSize) {
        self.pageID = pageID
        self.fileRef = fileRef
        self.pdfPageIndex = pdfPageIndex
        self.cropX = cropX; self.cropY = cropY; self.cropWidth = cropWidth; self.cropHeight = cropHeight
        self.rotationDegrees = rotationDegrees
        self.renderSize = renderSize
    }

    /// The bitmap for one layer of a page's stack. Placement is not part
    /// of the key: moving a picture doesn't re-render it.
    init(pageID: UUID, layer: ArtworkLayer, renderSize: CGSize) {
        self.init(pageID: pageID, fileRef: layer.fileRef, pdfPageIndex: layer.pdfPageIndex,
                  cropX: layer.cropX, cropY: layer.cropY, cropWidth: layer.cropWidth, cropHeight: layer.cropHeight,
                  rotationDegrees: layer.rotationDegrees, renderSize: renderSize)
    }
}

/// Rasterizes one piece of imported artwork. Capture-free and off the main
/// actor (invariant 10): rasterizing a PDF page at 2.5x was a visible stall
/// on every page turn. `PageBitmaps.artwork` owns the caching.
nonisolated enum ArtworkRenderer {
    static func render(_ request: ArtworkRequest) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let raw = ImportedArtwork.rasterized(
                fileRef: request.fileRef,
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

/// Renders a page's imported artwork - PDF pages and photos, any number of
/// them, bottom first - **on top of** the page's paper. It used to render
/// *instead* of the paper, with its own white fill - which is why importing
/// a photo made a lined or grid page go blank. The paper
/// (`PageBackgroundView`) is drawn underneath by the detail view; this layer
/// is transparent except where the artwork is.
///
/// PDF pages are rasterized to a UIImage via PDFKit rather than an embedded
/// interactive PDFView - simpler, and it keeps the coordinate space
/// straightforward to combine with the PencilKit annotation layer on top.
struct ImportedPageBackgroundView: View {
    let page: Page
    /// While the adjust handles are up, the in-progress rect (in page
    /// points) of the layer being adjusted, so it moves and resizes live
    /// under the handles instead of only jumping once the placement is
    /// committed. The other layers hold still.
    var liveFrame: CGRect? = nil
    var liveLayerID: UUID? = nil

    @Query private var allImportedDocuments: [ImportedDocument]

    private var layers: [ArtworkLayer] {
        ArtworkLayer.stack(for: page, documents: allImportedDocuments)
    }

    #if targetEnvironment(macCatalyst) || canImport(UIKit)
    /// The background is laid out in page points and then scaled up by the
    /// canvas zoom, so it has to be rasterized above 1:1 or an imported PDF
    /// template turns to mush the moment you pinch in to write on it.
    private static let oversampling: CGFloat = 2.5

    /// Every layer is decoded to the page's size, whatever its frame: a
    /// picture never needs more pixels than the page it sits on, and one
    /// size means one cache entry however often it is moved or resized.
    private func renderSize(for targetSize: CGSize) -> CGSize {
        let pageSize = (targetSize.width > 0 && targetSize.height > 0)
            ? targetSize
            : PageGeometry.contentSize(for: page)
        return CGSize(width: (pageSize.width * Self.oversampling).rounded(),
                      height: (pageSize.height * Self.oversampling).rounded())
    }
    #endif

    var body: some View {
        GeometryReader { geometry in
        #if targetEnvironment(macCatalyst) || canImport(UIKit)
            let renderSize = renderSize(for: geometry.size)
            ZStack(alignment: .topLeading) {
                // Deliberately no paper here - see the type's comment.
                Color.clear
                ForEach(layers) { layer in
                    ArtworkLayerView(
                        pageID: page.id,
                        layer: layer,
                        renderSize: renderSize,
                        containerSize: geometry.size,
                        liveFrame: liveLayerID == layer.id ? liveFrame : nil
                    )
                }
            }
        #else
            // On macOS without UIKit there is no rasterizer; the paper
            // underneath still renders.
            Color.clear
        #endif
        }
    }
}

#if targetEnvironment(macCatalyst) || canImport(UIKit)
/// One layer of the stack: its bitmap, read through the shared store, at
/// its placed rect.
private struct ArtworkLayerView: View {
    let pageID: UUID
    let layer: ArtworkLayer
    let renderSize: CGSize
    let containerSize: CGSize
    var liveFrame: CGRect?

    private var store: BitmapStore<ArtworkRequest> { PageBitmaps.artwork }

    /// The page id and `pdfPageIndex` are load-bearing: every page of a
    /// ten-page PDF import shares one file with no crop and no rotation,
    /// so a key built from those alone was identical on all ten and page
    /// 1's bitmap showed up on every one of them.
    private var request: ArtworkRequest {
        ArtworkRequest(pageID: pageID, layer: layer, renderSize: renderSize)
    }

    /// `.task(id:)` restarts on either of these changing: a different
    /// picture, or the store dropping what it had.
    private struct LoadID: Equatable {
        var request: ArtworkRequest
        var generation: Int
    }

    var body: some View {
        let request = request
        // Read through the store, not a view-local @State: whoever
        // rendered this bitmap, this view gets it, and it appears the
        // frame it lands rather than only after something else happens
        // to re-evaluate the body.
        let shown = store.image(for: request)
        // The layer's *actual* on-page rect, not a box it's letterboxed
        // inside - the image is drawn to exactly fill it, and resizing
        // preserves aspect ratio, so the selection handles can hug the
        // artwork the way Google Docs/Freeform do.
        let frame = liveFrame ?? layer.rect(for: shown, in: containerSize)
        ZStack(alignment: .topLeading) {
            Color.clear
            if let shown {
                Image(uiImage: shown)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .task(id: LoadID(request: request, generation: store.generation)) {
            store.request(request)
        }
    }
}
#endif
