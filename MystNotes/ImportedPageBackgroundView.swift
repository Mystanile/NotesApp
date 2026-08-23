import SwiftUI
import SwiftData
#if targetEnvironment(macCatalyst) || canImport(UIKit)
import UIKit
import PDFKit
#elseif canImport(AppKit)
import AppKit
import PDFKit
#endif

/// Renders an imported PDF page or image as a page's background, in place
/// of the plain paper-template background, whenever the page has a
/// backgroundRef set. PDF pages are rasterized to a UIImage via PDFKit's
/// built-in thumbnail renderer rather than an embedded interactive
/// PDFView — simpler, and keeps the coordinate space straightforward to
/// combine with the PencilKit annotation layer sitting on top of it.
struct ImportedPageBackgroundView: View {
    let page: Page

    @Query private var allImportedDocuments: [ImportedDocument]
    #if targetEnvironment(macCatalyst) || canImport(UIKit)
    @State private var image: UIImage?
    #else
    @State private var image: Any? = nil
    #endif

    private var importedDocument: ImportedDocument? {
        allImportedDocuments.first { $0.page?.id == page.id }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.white
        #if targetEnvironment(macCatalyst) || canImport(UIKit)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
        #else
                // On macOS without UIKit, show a placeholder or implement alternative
                if image != nil {
                    Rectangle()
                        .fill(Color.blue.opacity(0.3))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
        #endif
            }
            .task(id: page.backgroundRef) {
                loadImage(targetSize: geometry.size)
            }
        }
    }

    private func loadImage(targetSize: CGSize) {
        guard let ref = page.backgroundRef else {
        #if targetEnvironment(macCatalyst) || canImport(UIKit)
            image = nil
        #else
            image = nil
        #endif
            return
        }
        let directory = FileStore.baseDirectory()
        let url = directory.appendingPathComponent(ref)

        if ref.lowercased().hasSuffix(".pdf") {
            guard let document = PDFDocument(url: url) else {
        #if targetEnvironment(macCatalyst) || canImport(UIKit)
                image = nil
        #else
                image = nil
        #endif
                return
            }
            let pageIndex = importedDocument?.pdfPageIndex ?? 0
            guard let pdfPage = document.page(at: pageIndex) else {
        #if targetEnvironment(macCatalyst) || canImport(UIKit)
                image = nil
        #else
                image = nil
        #endif
                return
            }
            let renderSize = (targetSize.width > 0 && targetSize.height > 0)
                ? targetSize
                : CGSize(width: 1000, height: 1300)
        #if targetEnvironment(macCatalyst) || canImport(UIKit)
            image = pdfPage.thumbnail(of: renderSize, for: .mediaBox)
        #else
            // On macOS without UIKit, we can't create UIImage from PDF thumbnail
            // For now, we'll skip image loading or implement an alternative approach
            image = nil
        #endif
        } else {
        #if targetEnvironment(macCatalyst) || canImport(UIKit)
            image = UIImage(contentsOfFile: url.path)
        #else
            // On macOS without UIKit, we can't load images via UIImage
            // Implement alternative approach if needed (e.g., using NSImage)
            image = nil
        #endif
        }
    }
}