import SwiftUI
import SwiftData
import PencilKit
#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit)
/// Everything one thumbnail is made of, and its cache key. `inkStamp`
/// carries the page's `modifiedAt` so a page that has just been drawn on
/// re-renders while every other thumbnail is served from memory.
nonisolated struct PageThumbnailRequest: Hashable, Sendable {
    var pageID: UUID
    var inkStamp: String
    var template: String
    var backgroundRef: String?
    var pdfPageIndex: Int
    var frameX: Double?, frameY: Double?, frameWidth: Double?, frameHeight: Double?
    var cropX: Double?, cropY: Double?, cropWidth: Double?, cropHeight: Double?
    var rotationDegrees: Double?
    var nominal: CGSize
    var output: CGSize
}

/// Composites one page - paper, imported artwork, ink - into a thumbnail.
///
/// Off the main actor (invariant 10): decoding a page's ink record,
/// rasterizing a PDF background and drawing the composite took seconds on
/// the main thread at launch for a real library.
nonisolated enum PageThumbnailRenderer {
    static func render(_ request: PageThumbnailRequest) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            let drawing = DrawingStore.live.load(pageID: request.pageID)

            let backgroundImage: UIImage? = request.backgroundRef.flatMap { ref in
                ImportedArtwork.rasterized(fileRef: ref, pdfPageIndex: request.pdfPageIndex,
                                           targetSize: request.nominal)
                    .map { ImportedArtwork.transformed($0, cropX: request.cropX, cropY: request.cropY,
                                                       cropWidth: request.cropWidth, cropHeight: request.cropHeight,
                                                       rotationDegrees: request.rotationDegrees) }
            }

            if backgroundImage == nil, PageTemplate.isEmpty(request.template) {
                // Ink only, on blank paper: keep fitting to the ink's own
                // bounds, which frames a small sketch legibly instead of
                // shrinking it into a mostly empty page.
                guard let drawing else { return nil }
                let bounds = drawing.bounds.isEmpty
                    ? CGRect(x: 0, y: 0, width: 300, height: 400)
                    : drawing.bounds.insetBy(dx: -10, dy: -10)
                return drawing.image(from: bounds, scale: 0.5)
            }

            // Ruled paper or a background means the layers have to share one
            // coordinate space, so render the whole page area rather than
            // cropping to the ink.
            let nominal = request.nominal
            let artworkRect = ImportedArtwork.placedRect(
                x: request.frameX, y: request.frameY,
                width: request.frameWidth, height: request.frameHeight, in: nominal
            ) ?? ImportedArtwork.fittedRect(for: backgroundImage, in: nominal)

            let inkImage = drawing.map { $0.image(from: CGRect(origin: .zero, size: nominal), scale: 1) }

            let output = request.output
            let renderer = UIGraphicsImageRenderer(size: output)
            return renderer.image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: output))

                let scaleX = output.width / nominal.width
                let scaleY = output.height / nominal.height
                context.cgContext.scaleBy(x: scaleX, y: scaleY)

                // Paper, then artwork, then ink - the same stack the editor
                // draws, so the thumbnail shows the ruling too.
                PageTemplate.draw(request.template, in: nominal, context: context.cgContext)
                backgroundImage?.draw(in: artworkRect)
                inkImage?.draw(in: CGRect(origin: .zero, size: nominal))
            }
        }.value
    }
}
#endif

/// Small preview image of a page - its paper, any imported PDF page or
/// photo on it, and its ink.
///
/// The imported document is handed in rather than looked up here. Each
/// thumbnail used to run its own `@Query` for *every* `ImportedDocument` in
/// the library and re-run it on every model change, which for a page strip
/// is one full fetch per visible page. The parent already has that list.
struct PageThumbnailView: View {
    let page: Page
    var importedDocument: ImportedDocument?
    var isSelected: Bool = false

    #if canImport(UIKit)
    private var store: BitmapStore<PageThumbnailRequest> { PageBitmaps.thumbnails }
    #endif

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.white)
        #if canImport(UIKit)
            let request = thumbnailRequest
            if let thumbnail = store.image(for: request) {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
            }
        #endif
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.gray.opacity(0.3),
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .frame(width: 60, height: 80)
        #if canImport(UIKit)
        .task(id: LoadID(request: thumbnailRequest, generation: store.generation)) {
            MainThreadWatchdog.checkpoint("Thumbnail.task")
            store.request(thumbnailRequest)
        }
        #endif
    }

#if canImport(UIKit)
    /// `.task(id:)` restarts on either of these changing: a different page
    /// state, or the store dropping what it had.
    private struct LoadID: Equatable {
        var request: PageThumbnailRequest
        var generation: Int
    }

    /// Background placement (stored as fractions of the page) and ink
    /// (stored in page points) are composited through the page's own
    /// coordinate space, the same one the editor and the exporter use.
    private var nominalPageSize: CGSize { PageGeometry.contentSize(for: page) }

    /// The thumbnail bitmap, at the page's own proportions so a portrait
    /// template and a landscape one don't both come back the same shape.
    private var renderSize: CGSize {
        let nominal = nominalPageSize
        let scale = 160 / max(nominal.height, 1)
        return CGSize(width: max((nominal.width * scale).rounded(), 1), height: 160)
    }

    private var thumbnailRequest: PageThumbnailRequest {
        let doc = importedDocument
        return PageThumbnailRequest(
            pageID: page.id,
            inkStamp: [page.drawingFileRef ?? "-",
                       page.modifiedAt.map { String($0.timeIntervalSince1970) } ?? "-"].joined(separator: "|"),
            template: page.template,
            backgroundRef: page.backgroundRef,
            pdfPageIndex: doc?.pdfPageIndex ?? 0,
            frameX: doc?.frameX, frameY: doc?.frameY, frameWidth: doc?.frameWidth, frameHeight: doc?.frameHeight,
            cropX: doc?.cropX, cropY: doc?.cropY, cropWidth: doc?.cropWidth, cropHeight: doc?.cropHeight,
            rotationDegrees: doc?.rotationDegrees,
            nominal: nominalPageSize, output: renderSize
        )
    }
#endif
}
