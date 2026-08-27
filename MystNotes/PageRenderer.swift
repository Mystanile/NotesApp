import Foundation
import CoreGraphics
#if targetEnvironment(macCatalyst) || canImport(UIKit)
import UIKit
import PencilKit
import Photos

/// Flattens a page - imported PDF page or photo behind it, plus the
/// PencilKit ink on top - into an image or a PDF, for export.
///
/// Placement is stored as fractions of the page, so it maps cleanly onto
/// any output size. Ink, though, is stored in the canvas's own points, and
/// nothing records how big that canvas was; `nominalPageSize` is the assumed
/// page space both layers are composited through so they line up with each
/// other (and with what the page thumbnails show).
enum PageRenderer {
    static let nominalPageSize = CGSize(width: 780, height: 1040)

    /// 2x the nominal page - readable when exported without producing
    /// enormous files for a multi-page notebook.
    static let exportScale: CGFloat = 2

    static func image(for page: Page, importedDocument: ImportedDocument?, scale: CGFloat = exportScale) -> UIImage {
        let nominal = nominalPageSize
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true

        let backgroundImage = page.backgroundRef.flatMap { ref in
            ImportedArtwork.displayImage(
                fileRef: ref,
                document: importedDocument,
                targetSize: CGSize(width: nominal.width * scale, height: nominal.height * scale)
            )
        }
        let inkImage = drawing(for: page).map {
            $0.image(from: CGRect(origin: .zero, size: nominal), scale: scale)
        }

        return UIGraphicsImageRenderer(size: nominal, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: nominal))

            if let backgroundImage {
                let rect = ImportedArtwork.placedRect(
                    x: importedDocument?.frameX, y: importedDocument?.frameY,
                    width: importedDocument?.frameWidth, height: importedDocument?.frameHeight,
                    in: nominal
                ) ?? ImportedArtwork.fittedRect(for: backgroundImage, in: nominal)
                backgroundImage.draw(in: rect)
            }
            inkImage?.draw(in: CGRect(origin: .zero, size: nominal))
        }
    }

    /// One PDF page per notebook page, in the order given.
    static func pdfData(for pages: [(page: Page, document: ImportedDocument?)]) -> Data {
        let bounds = CGRect(origin: .zero, size: nominalPageSize)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for entry in pages {
                context.beginPage()
                image(for: entry.page, importedDocument: entry.document)
                    .draw(in: bounds)
            }
        }
    }

    static func drawing(for page: Page) -> PKDrawing? {
        guard let ref = page.drawingFileRef else { return nil }
        let url = FileStore.url(for: ref)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PKDrawing(data: data)
    }

    // MARK: - Destinations

    enum ExportError: LocalizedError {
        case photoLibraryDenied

        var errorDescription: String? {
            switch self {
            case .photoLibraryDenied:
                return "Mystnotes needs permission to add photos. You can grant it in Settings > Privacy > Photos."
            }
        }
    }

    /// Add-only access is enough to save an export, and asks for far less
    /// than full library access.
    static func saveToPhotos(_ image: UIImage) async throws {
        let status = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { continuation.resume(returning: $0) }
        }
        guard status == .authorized || status == .limited else {
            throw ExportError.photoLibraryDenied
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }

    /// Writes to a temporary file for the share sheet to hand off. Named
    /// after the notebook so the shared file arrives with a useful name.
    static func writeTemporaryPDF(_ data: Data, named name: String) throws -> URL {
        let safeName = name.isEmpty ? "Notebook" : name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName).pdf")
        try data.write(to: url, options: .atomic)
        return url
    }
}
#endif
