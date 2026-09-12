import SwiftUI
import SwiftData
import PencilKit
#if canImport(UIKit)
import UIKit
#endif

/// Small preview image of a page, rendered on-demand from the PKDrawing on
/// disk plus any imported PDF page / photo behind it (no separate thumbnail
/// cache/store yet).
struct PageThumbnailView: View {
    let page: Page
    var isSelected: Bool = false

    #if canImport(UIKit)
    @State private var thumbnail: UIImage?
    #else
    @State private var thumbnail: Any? = nil
    #endif

    @Query private var allImportedDocuments: [ImportedDocument]

    private var importedDocument: ImportedDocument? {
        allImportedDocuments.first { $0.page?.id == page.id }
    }

    /// Re-renders when the ink, the imported file, its placement, or the
    /// page's own shape changes.
    private var contentKey: String {
        let doc = importedDocument
        let frame = [doc?.frameX, doc?.frameY, doc?.frameWidth, doc?.frameHeight]
            .map { $0.map { String(format: "%.4f", $0) } ?? "-" }
            .joined(separator: ",")
        return [
            page.drawingFileRef ?? "-",
            page.backgroundRef ?? "-",
            frame,
            String(format: "%.4f", page.aspectRatio ?? -1)
        ].joined(separator: "|")
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.white)
        #if canImport(UIKit)
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
            }
        #else
            // On macOS without UIKit, show a placeholder or implement alternative
            if thumbnail != nil {
                Rectangle()
                    .fill(Color.blue.opacity(0.3))
                    .frame(width: 52, height: 72) // inner padding of 4
            }
        #endif
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.gray.opacity(0.3),
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .frame(width: 60, height: 80)
        .task(id: contentKey) {
            loadThumbnail()
        }
    }

#if canImport(UIKit)
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

    private func loadThumbnail() {
        let drawing = loadDrawing()

        guard let backgroundImage = loadBackgroundImage() else {
            // Ink only: keep fitting to the ink's own bounds, which frames a
            // small sketch legibly instead of shrinking it into a mostly
            // empty page.
            guard let drawing else { thumbnail = nil; return }
            let bounds = drawing.bounds.isEmpty
                ? CGRect(x: 0, y: 0, width: 300, height: 400)
                : drawing.bounds.insetBy(dx: -10, dy: -10)
            thumbnail = drawing.image(from: bounds, scale: 0.5)
            return
        }

        // With a background, both layers must share one coordinate space, so
        // render the whole page area rather than cropping to the ink.
        let nominal = nominalPageSize
        let doc = importedDocument
        let artworkRect = ImportedArtwork.placedRect(
            x: doc?.frameX, y: doc?.frameY, width: doc?.frameWidth, height: doc?.frameHeight, in: nominal
        ) ?? ImportedArtwork.fittedRect(for: backgroundImage, in: nominal)

        let inkImage = drawing.map { $0.image(from: CGRect(origin: .zero, size: nominal), scale: 1) }

        let output = renderSize
        let renderer = UIGraphicsImageRenderer(size: output)
        thumbnail = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: output))

            let scaleX = output.width / nominal.width
            let scaleY = output.height / nominal.height
            context.cgContext.scaleBy(x: scaleX, y: scaleY)

            backgroundImage.draw(in: artworkRect)
            inkImage?.draw(in: CGRect(origin: .zero, size: nominal))
        }
    }

    private func loadDrawing() -> PKDrawing? {
        DrawingStore.live.load(pageID: page.id)
    }

    private func loadBackgroundImage() -> UIImage? {
        guard let ref = page.backgroundRef else { return nil }
        return ImportedArtwork.displayImage(
            fileRef: ref,
            document: importedDocument,
            targetSize: nominalPageSize
        )
    }
#else
    private func loadThumbnail() {
        // Not available on native macOS (no PencilKit/UIKit rendering).
        thumbnail = nil
    }
#endif
}