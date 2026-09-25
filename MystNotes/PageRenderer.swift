import Foundation
import SwiftUI
import CoreGraphics
#if targetEnvironment(macCatalyst) || canImport(UIKit)
import UIKit
import PencilKit
import Photos
import PDFKit

/// Flattens a page - its paper, the imported PDF pages and photos on it,
/// plus the PencilKit ink on top - into an image or a PDF, for export.
///
/// Placement is stored as fractions of the page and ink in page points, so
/// both layers composite cleanly onto any output size. The page space they
/// share is `PageGeometry.contentSize(for:)` - the same space the editor
/// draws in - so an export is exactly what was on screen.
enum PageRenderer {
    /// The default page, for callers with no specific page in hand.
    static let nominalPageSize = PageGeometry.contentSize(aspectRatio: PageGeometry.defaultAspectRatio)

    /// 2x the nominal page - readable when exported without producing
    /// enormous files for a multi-page notebook.
    static let exportScale: CGFloat = 2

    /// `artwork` is the page's stack, bottom first (`ArtworkLayer.stack`).
    static func image(for page: Page, artwork: [ArtworkLayer], scale: CGFloat = exportScale) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: PageGeometry.contentSize(for: page), format: format).image { context in
            draw(page, artwork: artwork, scale: scale, in: context.cgContext)
        }
    }

    /// The page, bottom up, into `context` in page points: paper, ruling,
    /// artwork, ink, text. PDF artwork is drawn as vectors - into a PDF
    /// context that keeps its real text, where flattening it to a bitmap
    /// used to leave the export with none. Photos and ink are bitmaps at
    /// `scale`; PencilKit has no vector output.
    static func draw(_ page: Page, artwork: [ArtworkLayer], scale: CGFloat,
                     documents: inout [String: PDFDocument], in context: CGContext) {
        let nominal = PageGeometry.contentSize(for: page)
        let targetSize = CGSize(width: nominal.width * scale, height: nominal.height * scale)
        // Pinned to light, like the canvas, `FillTool` and the recognizer:
        // PencilKit inverts ink for a dark appearance, and this render has
        // no view to take its traits from - on an iPad in dark mode every
        // export came out with black handwriting drawn white on white
        // paper (Sept 19, 2026).
        var inkImage: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            inkImage = drawing(for: page).map {
                $0.image(from: CGRect(origin: .zero, size: nominal), scale: scale)
            }
        }

        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        UIColor.white.setFill()
        context.fill(CGRect(origin: .zero, size: nominal))
        // The paper's own ruling, under everything - an export of a
        // lined page used to come out blank whether or not anything had
        // been imported onto it.
        PageTemplate.draw(page.template, in: nominal, context: context)

        for layer in artwork {
            if layer.isPDF, let pdfPage = document(layer.fileRef, in: &documents)?.page(at: layer.pdfPageIndex),
               let shape = ImportedArtwork.displayedSize(of: pdfPage, layer: layer) {
                let rect = ImportedArtwork.placedRect(x: layer.frameX, y: layer.frameY,
                                                      width: layer.frameWidth, height: layer.frameHeight, in: nominal)
                    ?? ImportedArtwork.fittedRect(for: CGSize(width: shape.width, height: shape.height), in: nominal)
                ImportedArtwork.drawPDF(pdfPage, layer: layer, in: rect, context: context)
            } else if let image = layer.image(targetSize: targetSize) {
                image.draw(in: layer.rect(for: image, in: nominal))
            }
        }
        inkImage?.draw(in: CGRect(origin: .zero, size: nominal))
        drawTextBlocks(of: page, in: nominal)
    }

    static func draw(_ page: Page, artwork: [ArtworkLayer], scale: CGFloat, in context: CGContext) {
        var documents: [String: PDFDocument] = [:]
        draw(page, artwork: artwork, scale: scale, documents: &documents, in: context)
    }

    /// One open document per file for a whole export: a 300-page import is
    /// one file, and re-opening it per page would parse it 300 times.
    private static func document(_ fileRef: String, in documents: inout [String: PDFDocument]) -> PDFDocument? {
        if let open = documents[fileRef] { return open }
        let opened = PDFDocument(url: FileStore.url(for: fileRef))
        documents[fileRef] = opened
        return opened
    }

    /// Typed text blocks, laid out the way `TextBlockView` shows them: the
    /// stored frame is the box, with the same 6 pt padding inside it, the
    /// width is the wrap width, and the height is a floor the text may grow
    /// past. Drawn after the ink, as on screen.
    static func drawTextBlocks(of page: Page, in pageSize: CGSize) {
        for block in page.textBlocks ?? [] where !block.content.isEmpty {
            let inset: CGFloat = 6
            let box = CGRect(x: block.frameX, y: block.frameY, width: block.frameWidth, height: block.frameHeight)
            let textRect = CGRect(
                x: box.minX + inset,
                y: box.minY + inset,
                width: max(box.width - inset * 2, 1),
                height: max(pageSize.height - box.minY - inset, 1)
            )
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            let attributes: [NSAttributedString.Key: Any] = [
                .font: uiFont(for: block),
                .foregroundColor: Color(hex: block.textColorHex).fixedUIColor,
                .paragraphStyle: paragraph
            ]
            NSAttributedString(string: block.content, attributes: attributes)
                .draw(with: textRect, options: [.usesLineFragmentOrigin], context: nil)
        }
    }

    /// The UIKit font matching `TextBlockView`'s SwiftUI one, so an export
    /// wraps at the same places the editor does.
    static func uiFont(for block: TypedTextBlock) -> UIFont {
        let size = CGFloat(block.fontSize)
        let base = UIFont.systemFont(ofSize: size, weight: block.isBold ? .bold : .regular)
        var descriptor = base.fontDescriptor
        let design: UIFontDescriptor.SystemDesign
        switch TextBlockFontDesign.from(block.fontDesign) {
        case .default: design = .default
        case .serif: design = .serif
        case .rounded: design = .rounded
        case .monospaced: design = .monospaced
        }
        if design != .default, let designed = descriptor.withDesign(design) {
            descriptor = designed
        }
        var traits: UIFontDescriptor.SymbolicTraits = []
        if block.isBold { traits.insert(.traitBold) }
        if block.isItalic { traits.insert(.traitItalic) }
        if !traits.isEmpty, let styled = descriptor.withSymbolicTraits(traits) {
            descriptor = styled
        }
        return UIFont(descriptor: descriptor, size: size)
    }

    /// One PDF page per notebook page, in the order given. Each output page
    /// takes the shape of the notebook page it came from, so a notebook that
    /// mixes an imported portrait template with a landscape one exports as
    /// exactly those pages rather than squeezing both into one shape.
    static func pdfData(for pages: [(page: Page, artwork: [ArtworkLayer])]) -> Data {
        let firstBounds = CGRect(
            origin: .zero,
            size: pages.first.map { PageGeometry.contentSize(for: $0.page) } ?? nominalPageSize
        )
        var documents: [String: PDFDocument] = [:]
        return UIGraphicsPDFRenderer(bounds: firstBounds).pdfData { context in
            for entry in pages {
                let bounds = CGRect(origin: .zero, size: PageGeometry.contentSize(for: entry.page))
                context.beginPage(withBounds: bounds, pageInfo: [:])
                draw(entry.page, artwork: entry.artwork, scale: exportScale, documents: &documents, in: context.cgContext)
            }
        }
    }

    static func drawing(for page: Page) -> PKDrawing? {
        DrawingStore.live.load(pageID: page.id)
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
