import SwiftUI
import SwiftData
import PencilKit
#if canImport(UIKit)
import UIKit
#endif

/// The page sidebar's sizes, in one place because the view that draws it,
/// the preference that persists its width and the cells inside it all have
/// to agree. `width` means the whole sidebar, grabber included.
nonisolated enum PageSidebarMetrics {
    static let defaultWidth: CGFloat = 128
    static let minimumWidth: CGFloat = 96
    static let maximumWidth: CGFloat = 220
    /// The grab area on the right edge.
    static let grabberWidth: CGFloat = 12
    /// Space either side of a thumbnail.
    static let horizontalPadding: CGFloat = 8

    static func clamped(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumWidth), maximumWidth)
    }

    /// The width a thumbnail may take in a sidebar this wide.
    static func thumbnailWidth(sidebarWidth: CGFloat) -> CGFloat {
        clamped(sidebarWidth) - grabberWidth - 2 * horizontalPadding
    }

    /// The height of a page of this shape (width / height) at that width.
    static func thumbnailHeight(sidebarWidth: CGFloat, aspect: CGFloat) -> CGFloat {
        (thumbnailWidth(sidebarWidth: sidebarWidth) / max(aspect, 0.1)).rounded()
    }
}

#if canImport(UIKit)
/// Everything one thumbnail is made of, and its cache key. `inkStamp`
/// carries the page's `modifiedAt` so a page that has just been drawn on
/// re-renders while every other thumbnail is served from memory.
nonisolated struct PageThumbnailRequest: Hashable, Sendable {
    var pageID: UUID
    var inkStamp: String
    var template: String
    /// The page's artwork, bottom first.
    var artwork: [ArtworkLayer]
    /// Text and stickers, drawn over the ink as on the page.
    var elements: PageElements = PageElements()
    var nominal: CGSize
    var output: CGSize
    /// Part of the cache key, so a change of paper re-renders. Thumbnails
    /// render `paper.outputStyle` (dark paper shows white).
    var paper: PaperStyle = .standard
}

/// Composites one page - paper, imported artwork, ink - into a thumbnail.
///
/// Off the main actor (invariant 10): decoding a page's ink record,
/// rasterizing a PDF background and drawing the composite took seconds on
/// the main thread at launch for a real library.
nonisolated enum PageThumbnailRenderer {
    static func render(_ request: PageThumbnailRequest) async -> UIImage? {
        // On the ink render queue, not the cooperative pool: see
        // `InkRenderQueue` for the deadlock that blanked every page.
        await InkRenderQueue.run {
            let drawing = DrawingStore.live.load(pageID: request.pageID)
            // Ink renders through the current traits; pinned to light so a
            // dark-mode iPad doesn't get white-on-white thumbnails (see
            // `PageRenderer`).
            func inkImage(_ render: () -> UIImage) -> UIImage {
                var image: UIImage?
                UITraitCollection(userInterfaceStyle: .light).performAsCurrent { image = render() }
                return image!
            }

            let artwork: [(layer: ArtworkLayer, image: UIImage)] = request.artwork.compactMap { layer in
                layer.image(targetSize: request.nominal).map { (layer: layer, image: $0) }
            }

            if artwork.isEmpty, PageTemplate.isEmpty(request.template), request.elements.isEmpty {
                // Ink only, on blank paper: keep fitting to the ink's own
                // bounds, which frames a small sketch legibly instead of
                // shrinking it into a mostly empty page.
                guard let drawing else { return nil }
                let bounds = drawing.bounds.isEmpty
                    ? CGRect(x: 0, y: 0, width: 300, height: 400)
                    : drawing.bounds.insetBy(dx: -10, dy: -10)
                return inkImage { drawing.image(from: bounds, scale: 0.5) }
            }

            // Ruled paper or a background means the layers have to share one
            // coordinate space, so render the whole page area rather than
            // cropping to the ink.
            let nominal = request.nominal
            let ink = drawing.map { drawing in inkImage { drawing.image(from: CGRect(origin: .zero, size: nominal), scale: 1) } }

            // Rendered at the screen's scale on top of `output`, which is
            // already 2x the displayed size. That is deliberate, if dear:
            // a page's 1pt ruling is well under a pixel at the sidebar's
            // scale, and at anything less than this it fades out of the
            // thumbnail altogether (`testThumbnail_showsTheTemplate`).
            let output = request.output
            let renderer = UIGraphicsImageRenderer(size: output)
            return renderer.image { context in
                let paper = request.paper.outputStyle
                context.cgContext.setFillColor(paper.fillCGColor)
                context.fill(CGRect(origin: .zero, size: output))

                let scaleX = output.width / nominal.width
                let scaleY = output.height / nominal.height
                context.cgContext.scaleBy(x: scaleX, y: scaleY)

                // Paper, then artwork, then ink - the same stack the editor
                // draws, so the thumbnail shows the ruling too.
                PageTemplate.draw(request.template, in: nominal, context: context.cgContext, paper: paper)
                for entry in artwork {
                    entry.image.draw(in: entry.layer.rect(for: entry.image, in: nominal))
                }
                ink?.draw(in: CGRect(origin: .zero, size: nominal))
                request.elements.draw(in: nominal)
            }
        }
    }
}
#endif

/// Small preview image of a page - its paper, whatever PDF pages and
/// photos are on it, and its ink.
///
/// The imported documents are handed in rather than looked up here. Each
/// thumbnail used to run its own `@Query` for *every* `ImportedDocument` in
/// the library and re-run it on every model change, which for a page strip
/// is one full fetch per visible page. The parent already has that list.
struct PageThumbnailView: View {
    let page: Page
    /// This page's artwork, bottom first (`ImportedDocument.stack`).
    var importedDocuments: [ImportedDocument] = []
    var isSelected: Bool = false
    /// How tall to draw it. The sidebar is resizable, so this is whatever the
    /// user has dragged it to; the width follows the page's own shape.
    var height: CGFloat = 80
    /// The height to *render* for, when that isn't `height`: while the
    /// sidebar is being dragged the parent holds this at the height the drag
    /// started from, so the bitmap is scaled rather than re-rendered every
    /// 80 px of the drag - each of those re-renders decoded every visible
    /// page's ink and rasterized its PDF, and the strip stuttered. One
    /// render at the final size, when the finger lifts.
    var renderHeight: CGFloat? = nil

    /// Observed only so the body (and the request's paper) refreshes when Settings changes.
    @AppStorage(AppSettings.Keys.paperColor) private var paperColorRaw = PaperColor.white.rawValue
    @AppStorage(AppSettings.Keys.lineSpacing) private var lineSpacingRaw = LineSpacingOption.normal.rawValue

    #if canImport(UIKit)
    private var store: BitmapStore<PageThumbnailRequest> { PageBitmaps.thumbnails }
    /// The last bitmap this cell showed, kept while its replacement (a
    /// different size, newer ink) renders. Without it a cell went blank
    /// for a frame or two on every change, which read as flicker.
    @State private var lastShown: UIImage?
    #endif

    /// The cell takes the page's own shape rather than a fixed portrait
    /// box, so a landscape page reads as landscape in the sidebar instead of
    /// being letterboxed inside a tall one.
    private var cellSize: CGSize {
        CGSize(width: (height * PageGeometry.aspectRatio(page.aspectRatio)).rounded(), height: height)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(PaperStyle.resolve(colorRaw: paperColorRaw, spacingRaw: lineSpacingRaw).outputStyle.fillColor)
        #if canImport(UIKit)
            if let thumbnail = store.image(for: thumbnailRequest) ?? lastShown {
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
        .frame(width: cellSize.width, height: cellSize.height)
        #if canImport(UIKit)
        .task(id: LoadID(request: thumbnailRequest, generation: store.generation)) {
            MainThreadWatchdog.checkpoint("Thumbnail.task")
            store.request(thumbnailRequest)
        }
        .onChange(of: store.image(for: thumbnailRequest)) { _, image in
            if let image { lastShown = image }
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
    ///
    /// The pixel height follows the displayed height at 2x, but in steps of
    /// 80: dragging the sidebar wider has to re-render, and without the
    /// quantisation every intermediate height during the drag would be its
    /// own cache key and its own render.
    private var renderSize: CGSize {
        let nominal = nominalPageSize
        let wanted = max((renderHeight ?? height) * 2, 160)
        let output = min((wanted / 80).rounded(.up) * 80, 560)
        let scale = output / max(nominal.height, 1)
        return CGSize(width: max((nominal.width * scale).rounded(), 1), height: output)
    }

    var thumbnailRequest: PageThumbnailRequest {
        PageThumbnailRequest(
            pageID: page.id,
            inkStamp: [page.drawingFileRef ?? "-",
                       page.modifiedAt.map { String($0.timeIntervalSince1970) } ?? "-"].joined(separator: "|"),
            template: page.template,
            artwork: ArtworkLayer.stack(for: page, documents: importedDocuments),
            // No links: an anchor is a speck at this size, and fetching them
            // here would be a query per cell.
            elements: PageElements(page: page, links: []),
            nominal: nominalPageSize, output: renderSize,
            paper: PaperStyle.resolve(colorRaw: paperColorRaw, spacingRaw: lineSpacingRaw)
        )
    }
#endif
}
