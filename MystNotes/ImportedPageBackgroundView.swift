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
/// Rasterized page artwork, kept between page turns.
///
/// Rendering is a one-shot, asynchronous job per page visit: nothing
/// re-fires it, so anything that loses a result leaves the page white
/// forever (the thumbnails survive the same hazard only because their key
/// carries `modifiedAt` and so re-fires on every save). A cache means a
/// page you have already looked at paints from memory the moment it comes
/// back, before any task runs - and it takes a 2.5x PDF rasterization off
/// every single page turn.
///
/// `NSCache` is documented as thread-safe and evicts itself under memory
/// pressure; the cost is the bitmap's real byte size so the limit means
/// something.
nonisolated enum PageArtworkCache {
    nonisolated(unsafe) private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    static func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    static func store(_ image: UIImage, for key: String) {
        let bytes = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        cache.setObject(image, forKey: key as NSString, cost: bytes)
    }
}
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

    /// Reload when the page, the file, the PDF page inside it, its crop, or
    /// its rotation changes - the frame isn't included, since resizing
    /// doesn't need a re-render.
    ///
    /// The page id and `pdfPageIndex` are load-bearing. This view sits in a
    /// fixed spot in the detail view, so SwiftUI keeps the same instance
    /// (and its `@State image`) as you page through a notebook. Every page
    /// of a ten-page PDF import shares one `backgroundRef` with no crop and
    /// no rotation, so a key built from those alone was identical on all
    /// ten, `.task(id:)` never re-fired, and page 1's bitmap stayed up on
    /// every page.
    private var imageKey: String {
        let doc = importedDocument
        let values: [Double?] = [doc?.rotationDegrees, doc?.cropX, doc?.cropY, doc?.cropWidth, doc?.cropHeight]
        return ([page.id.uuidString, page.backgroundRef ?? "-", String(doc?.pdfPageIndex ?? 0)]
                + values.map { $0.map { String(format: "%.4f", $0) } ?? "-" })
            .joined(separator: "|")
    }

    #if targetEnvironment(macCatalyst) || canImport(UIKit)
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

    /// The cache key carries the pixel size the bitmap was made at, which
    /// `imageKey` deliberately doesn't: a resized window must not be served
    /// the old resolution.
    private func cacheKey(for targetSize: CGSize) -> String {
        let size = renderSize(for: targetSize)
        return "\(imageKey)|\(Int(size.width))x\(Int(size.height))"
    }
    #endif

    /// The artwork's placed rect. This is the image's *actual* on-page rect,
    /// not a box it's letterboxed inside - the image is drawn to exactly
    /// fill it, and resizing preserves aspect ratio, so the selection
    /// handles can hug the artwork the way Google Docs/Freeform do.
    #if targetEnvironment(macCatalyst) || canImport(UIKit)
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
    #endif

    var body: some View {
        GeometryReader { geometry in
        #if targetEnvironment(macCatalyst) || canImport(UIKit)
            // The cache is read here, not only in the task: coming back to a
            // page that has already been rendered paints it in the same
            // frame the page turn happens in, and a task that never lands
            // can't leave a white sheet behind.
            let shown = image ?? PageArtworkCache.image(for: cacheKey(for: geometry.size))
            let frame = artworkFrame(for: shown, in: geometry.size)
            ZStack(alignment: .topLeading) {
                Color.white
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
            .task(id: imageKey) {
                await loadImage(targetSize: geometry.size)
            }
        #else
            // On macOS without UIKit, show a placeholder or implement alternative
            ZStack(alignment: .topLeading) {
                Color.white
                if image != nil {
                    Rectangle()
                        .fill(Color.blue.opacity(0.3))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .task(id: imageKey) {
                await loadImage(targetSize: geometry.size)
            }
        #endif
        }
    }

    /// Everything the render needs, copied out of the model on the main
    /// actor so the rasterization itself can leave it (invariant 10; same
    /// shape as `PageThumbnailView.Inputs`). Rasterizing a PDF page at
    /// 2.5x on the main thread was a visible stall on every page turn.
    nonisolated struct Inputs: Sendable {
        var backgroundRef: String
        var pdfPageIndex: Int
        var cropX: Double?, cropY: Double?, cropWidth: Double?, cropHeight: Double?
        var rotationDegrees: Double?
        var renderSize: CGSize
    }

    private func loadImage(targetSize: CGSize) async {
        guard let ref = page.backgroundRef else {
            image = nil
            return
        }
        #if targetEnvironment(macCatalyst) || canImport(UIKit)
        let key = imageKey
        let cacheKey = cacheKey(for: targetSize)
        if let cached = PageArtworkCache.image(for: cacheKey) {
            image = cached
            return
        }
        let doc = importedDocument
        let inputs = Inputs(
            backgroundRef: ref,
            pdfPageIndex: doc?.pdfPageIndex ?? 0,
            cropX: doc?.cropX, cropY: doc?.cropY, cropWidth: doc?.cropWidth, cropHeight: doc?.cropHeight,
            rotationDegrees: doc?.rotationDegrees,
            renderSize: renderSize(for: targetSize)
        )
        let rendered = await Self.render(inputs).value
        // Staleness is decided by the key this render was started for, NOT
        // by Task.isCancelled. A page turn does cancel this task, but so
        // does anything else that takes the view out of the hierarchy for a
        // moment - and since nothing re-fires the render, treating
        // cancellation as "throw the bitmap away" left a correctly rendered
        // PDF page showing a blank white sheet until the app was relaunched.
        // The key still matching means this bitmap is the one the view
        // wants; if the view is gone, the assignment is a harmless no-op.
        guard key == imageKey else { return }
        if let rendered { PageArtworkCache.store(rendered, for: cacheKey) }
        image = rendered
        #else
        // Not available on native macOS (no UIKit image loading).
        image = nil
        #endif
    }

    #if targetEnvironment(macCatalyst) || canImport(UIKit)
    /// Capture-free: takes only the Sendable inputs. Crop and rotation are
    /// applied here, by the same helper the thumbnails and exports use.
    nonisolated static func render(_ inputs: Inputs) -> Task<UIImage?, Never> {
        Task.detached(priority: .userInitiated) {
            guard let raw = ImportedArtwork.rasterized(
                fileRef: inputs.backgroundRef,
                pdfPageIndex: inputs.pdfPageIndex,
                targetSize: inputs.renderSize
            ) else { return nil }
            return ImportedArtwork.transformed(
                raw,
                cropX: inputs.cropX, cropY: inputs.cropY,
                cropWidth: inputs.cropWidth, cropHeight: inputs.cropHeight,
                rotationDegrees: inputs.rotationDegrees
            )
        }
    }
    #endif
}
