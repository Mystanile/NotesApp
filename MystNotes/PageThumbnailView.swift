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

    /// Re-renders when the ink, the imported file, or its placement changes.
    private var contentKey: String {
        let doc = importedDocument
        let frame = [doc?.frameX, doc?.frameY, doc?.frameWidth, doc?.frameHeight]
            .map { $0.map { String(format: "%.4f", $0) } ?? "-" }
            .joined(separator: ",")
        return [page.drawingFileRef ?? "-", page.backgroundRef ?? "-", frame].joined(separator: "|")
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
    /// Thumbnails are 60x80, so background placement (stored as fractions of
    /// the page) and ink (stored in page points) are composited through this
    /// shared nominal page rect to keep them aligned with each other.
    private static let nominalPageSize = CGSize(width: 780, height: 1040)
    private static let renderSize = CGSize(width: 120, height: 160)

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
        let nominal = Self.nominalPageSize
        let doc = importedDocument
        let artworkRect = ImportedArtwork.placedRect(
            x: doc?.frameX, y: doc?.frameY, width: doc?.frameWidth, height: doc?.frameHeight, in: nominal
        ) ?? ImportedArtwork.fittedRect(for: backgroundImage, in: nominal)

        let inkImage = drawing.map { $0.image(from: CGRect(origin: .zero, size: nominal), scale: 1) }

        let renderer = UIGraphicsImageRenderer(size: Self.renderSize)
        thumbnail = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: Self.renderSize))

            let scaleX = Self.renderSize.width / nominal.width
            let scaleY = Self.renderSize.height / nominal.height
            context.cgContext.scaleBy(x: scaleX, y: scaleY)

            backgroundImage.draw(in: artworkRect)
            inkImage?.draw(in: CGRect(origin: .zero, size: nominal))
        }
    }

    private func loadDrawing() -> PKDrawing? {
        guard let ref = page.drawingFileRef else { return nil }
        let url = FileStore.url(for: ref)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PKDrawing(data: data)
    }

    private func loadBackgroundImage() -> UIImage? {
        guard let ref = page.backgroundRef else { return nil }
        return ImportedArtwork.displayImage(
            fileRef: ref,
            document: importedDocument,
            targetSize: Self.nominalPageSize
        )
    }
#else
    private func loadThumbnail() {
        // Not available on native macOS (no PencilKit/UIKit rendering).
        thumbnail = nil
    }
#endif
}