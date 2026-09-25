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
/// Every layer is a bitmap first (instant, cached, shared with the page
/// strip). A PDF layer is then redrawn over its bitmap as vectors by a
/// tiled layer, at the detail the page is zoomed to (`PDFVectorLayer`).
/// Not an interactive PDFView: the ink on top owns the touches, and one
/// page space for artwork and ink keeps them lined up.
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
                // A PDF page redrawn as vectors over its bitmap, at whatever
                // zoom the page is shown - the bitmap is 2.5x, soft past
                // that. The bitmap stays underneath as the instant picture
                // on a page turn. Not while the handles are moving it: a
                // live frame would redraw every tile every step.
                if layer.isPDF, liveFrame == nil {
                    PDFVectorLayer(artwork: layer)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                        .allowsHitTesting(false)
                }
            }
        }
        .task(id: LoadID(request: request, generation: store.generation)) {
            store.request(request)
        }
    }
}

/// Draws one PDF layer as vectors, tile by tile, at the detail it is shown
/// at. Verified in the simulator (Sept 25, 2026): a `CATiledLayer` under
/// the page's SwiftUI `.scaleEffect` draws its tiles at zoom x screen
/// scale, including when the zoom changes while it is on screen.
private struct PDFVectorLayer: UIViewRepresentable {
    let artwork: ArtworkLayer

    func makeUIView(context: Context) -> PDFLayerView { PDFLayerView() }

    func updateUIView(_ view: PDFLayerView, context: Context) {
        view.tiles.show(artwork)
    }
}

class PDFLayerView: UIView {
    override class var layerClass: AnyClass { PDFTileLayer.self }
    var tiles: PDFTileLayer { layer as! PDFTileLayer }

    init() {
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        // A new size redraws the tiles rather than stretching old ones.
        contentMode = .redraw
        // From a quarter of the page's size up to 16x: the canvas zooms to
        // 5x fit, and fit is itself ~1.5x on an iPad.
        tiles.levelsOfDetail = 7
        tiles.levelsOfDetailBias = 4
        tiles.tileSize = CGSize(width: 512, height: 512)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// The tiles are drawn on Core Animation's background threads, so this is
/// `nonisolated` (the project defaults to the main actor) and holds its
/// state behind a lock. The lock also serializes the tiles' PDFKit calls:
/// PDFKit is not documented as safe to draw from several threads at once.
nonisolated class PDFTileLayer: CATiledLayer, @unchecked Sendable {
    private let lock = NSLock()
    private var artwork: ArtworkLayer?
    private var document: PDFDocument?

    override init() { super.init() }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Called on the main thread on every SwiftUI update; redraws only
    /// when the artwork actually changed.
    func show(_ newArtwork: ArtworkLayer) {
        lock.lock()
        let changed = artwork != newArtwork
        if artwork?.fileRef != newArtwork.fileRef { document = nil }
        artwork = newArtwork
        lock.unlock()
        if changed { setNeedsDisplay() }
    }

    // ponytail: one lock per layer serializes its tiles; a page is fast to
    // draw, but a huge scanned page might fill in slowly at 16x. Per-thread
    // documents if that shows up.
    override func draw(in context: CGContext) {
        lock.lock()
        defer { lock.unlock() }
        guard let artwork else { return }
        if document == nil { document = PDFDocument(url: FileStore.url(for: artwork.fileRef)) }
        guard let page = document?.page(at: artwork.pdfPageIndex) else { return }
        ImportedArtwork.drawPDF(page, layer: artwork, in: bounds, context: context)
    }
}
#endif
