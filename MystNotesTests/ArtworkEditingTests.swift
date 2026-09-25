import XCTest
import SwiftData
import SwiftUI
import UIKit
@testable import Mystnotes

/// The artwork handles: live resize, what a long-press selects, and undo
/// (field report, Sept 25, 2026).
final class ArtworkEditingTests: XCTestCase {

    private var written: [URL] = []

    override func tearDown() {
        for url in written { try? FileManager.default.removeItem(at: url) }
        written = []
        super.tearDown()
    }

    private static let schema = Schema([
        Folder.self, Notebook.self, Page.self, TypedTextBlock.self,
        ImportedDocument.self, Link.self, Sticker.self
    ])

    private func writePNG(color: UIColor = .systemTeal) throws -> String {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
        }
        let ref = "\(UUID().uuidString).png"
        let url = FileStore.url(for: ref)
        try XCTUnwrap(image.pngData()).write(to: url)
        written.append(url)
        return ref
    }

    // MARK: - Live resize

    @Observable final class Live { var frame: CGRect? }

    private struct Host: View {
        let page: Page
        let layerID: UUID
        let live: Live
        let viewport: CanvasViewport
        var body: some View {
            // As the detail view hosts it: inside the page viewport, the
            // live frame read in the viewport's content closure.
            PageViewportLayer(viewport: viewport, pageSize: CGSize(width: 300, height: 400)) { _ in
                ImportedPageBackgroundView(page: page, liveFrame: live.frame, liveLayerID: layerID)
                    .id(page.id)
            }
            .frame(width: 600, height: 600, alignment: .topLeading)
            .background(Color.white)
        }
    }

    /// Field report: dragging a corner handle moved the handles but not the
    /// picture; it only took its new size after a page turn.
    @MainActor
    func testPicture_followsTheHandles_whileResizing() async throws {
        let container = try ModelContainer(for: Self.schema,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = container.mainContext
        let page = Page(index: 0)
        context.insert(page)
        let doc = ImportedDocument(sourceType: "image", fileRef: try writePNG(), page: page)
        doc.frameX = 0; doc.frameY = 0; doc.frameWidth = 1; doc.frameHeight = 1
        context.insert(doc)
        try context.save()

        let live = Live()
        let viewport = CanvasViewport()
        viewport.hasSynced = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 600, height: 600)
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView:
            Host(page: page, layerID: doc.id, live: live, viewport: viewport).modelContainer(container))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        func isTeal(_ point: CGPoint) async throws -> Bool {
            try await Task.sleep(for: .seconds(0.8))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let cg = try XCTUnwrap(image.cgImage)
            let scale = CGFloat(cg.width) / window.bounds.width
            var px = [UInt8](repeating: 0, count: 4)
            let ctx = try XCTUnwrap(CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(cg, in: CGRect(x: -point.x * scale, y: -(CGFloat(cg.height) - point.y * scale),
                                    width: CGFloat(cg.width), height: CGFloat(cg.height)))
            return px[2] > 150 && px[0] < 150      // teal, not white
        }

        let lowerRight = CGPoint(x: 250, y: 350)
        let before = try await isTeal(lowerRight)
        XCTAssertTrue(before, "picture not drawn at its placed frame")
        live.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let afterOld = try await isTeal(lowerRight)
        let afterNew = try await isTeal(CGPoint(x: 50, y: 50))
        XCTAssertFalse(afterOld, "picture didn't shrink with the handles")
        XCTAssertTrue(afterNew, "picture not at its live frame")

        // Done: the placement is written to the document and the live
        // frame cleared, in one step - as `finishAdjustingImage` does.
        doc.frameX = 0; doc.frameY = 0; doc.frameWidth = 100.0 / 300; doc.frameHeight = 100.0 / 400
        try context.save()
        live.frame = nil
        let doneOld = try await isTeal(lowerRight)
        let doneNew = try await isTeal(CGPoint(x: 50, y: 50))
        XCTAssertFalse(doneOld, "after Done, the picture snapped back to its old frame")
        XCTAssertTrue(doneNew, "after Done, the picture isn't at its new frame")
    }

    // MARK: - What a long-press selects

    private func layer(pdf: Bool, frame: CGRect?) -> ArtworkLayer {
        ArtworkLayer(id: UUID(), fileRef: pdf ? "a.pdf" : "a.png", sourceType: pdf ? "pdf" : "image", pdfPageIndex: 0,
                     frameX: frame.map { Double($0.minX) }, frameY: frame.map { Double($0.minY) },
                     frameWidth: frame.map { Double($0.width) }, frameHeight: frame.map { Double($0.height) })
    }

    /// Field report: a long-press anywhere on a PDF page selected the whole
    /// PDF. The PDF that is the page is paper, never picked by a press;
    /// a press picks the topmost photo under the finger, or nothing.
    func testLongPress_picksThePhotoUnderTheFinger_neverThePaper() {
        let pageSize = CGSize(width: 600, height: 800)
        let paper = layer(pdf: true, frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        let photo = layer(pdf: false, frame: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        let onTop = layer(pdf: false, frame: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3))
        let stack = [paper, photo, onTop]

        XCTAssertEqual(ImportedArtwork.layerToAdjust(at: CGPoint(x: 80, y: 100), in: stack, pageSize: pageSize), photo.id)
        XCTAssertEqual(ImportedArtwork.layerToAdjust(at: CGPoint(x: 200, y: 200), in: stack, pageSize: pageSize), onTop.id)
        XCTAssertNil(ImportedArtwork.layerToAdjust(at: CGPoint(x: 500, y: 700), in: stack, pageSize: pageSize),
                     "a press on the PDF paper selected it")
        XCTAssertNil(ImportedArtwork.layerToAdjust(at: CGPoint(x: 300, y: 400), in: [paper], pageSize: pageSize))
        XCTAssertNil(ImportedArtwork.layerToAdjust(at: CGPoint(x: 500, y: 700), in: [photo], pageSize: pageSize),
                     "a press on bare paper selected the top picture")
        // A PDF placed smaller on a page is a picture, not the paper.
        let placedPDF = layer(pdf: true, frame: CGRect(x: 0.5, y: 0.5, width: 0.4, height: 0.4))
        XCTAssertEqual(ImportedArtwork.layerToAdjust(at: CGPoint(x: 400, y: 500), in: [placedPDF], pageSize: pageSize), placedPDF.id)
    }

    // MARK: - Undo

    @MainActor
    private func contextWithPage() throws -> (ModelContext, Page) {
        let container = try ModelContainer(for: Self.schema,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let page = Page(index: 0)
        context.insert(page)
        return (context, page)
    }

    @MainActor
    private func documents(in context: ModelContext) throws -> [ImportedDocument] {
        try context.fetch(FetchDescriptor<ImportedDocument>())
    }

    /// Remove, undo, redo: the picture comes back as the same row with
    /// every field, and its file is only reported unused while it's gone.
    @MainActor
    func testRemoveThenUndo_bringsBackTheSameDocument() throws {
        let (context, page) = try contextWithPage()
        let doc = ImportedDocument(sourceType: "image", fileRef: "photo.png", pdfPageIndex: 0, page: page)
        doc.frameX = 0.1; doc.frameY = 0.2; doc.frameWidth = 0.3; doc.frameHeight = 0.4
        doc.cropX = 0.05; doc.cropY = 0.06; doc.cropWidth = 0.7; doc.cropHeight = 0.8
        doc.rotationDegrees = 90; doc.stackOrder = 3
        context.insert(doc)
        page.backgroundRef = "photo.png"
        try context.save()
        let before = ArtworkSnapshot(doc)

        let orphan = ArtworkEdits.apply(nil, id: before.id, page: page, in: context)
        try context.save()
        XCTAssertEqual(orphan, "photo.png", "the removed picture's file should be reported unused")
        XCTAssertTrue(try documents(in: context).isEmpty)
        XCTAssertNil(page.backgroundRef)

        let back = ArtworkEdits.apply(before, id: before.id, page: page, in: context)
        try context.save()
        XCTAssertNil(back)
        let restored = try XCTUnwrap(try documents(in: context).first)
        XCTAssertEqual(ArtworkSnapshot(restored), before)
        XCTAssertEqual(restored.page?.id, page.id)
        XCTAssertEqual(page.backgroundRef, "photo.png")

        XCTAssertEqual(ArtworkEdits.apply(nil, id: before.id, page: page, in: context), "photo.png", "redo")
    }

    /// A multi-page PDF import shares one file across pages: removing it
    /// from one page leaves the file in use.
    @MainActor
    func testRemovingASharedFile_reportsNoOrphan() throws {
        let (context, page) = try contextWithPage()
        let other = Page(index: 1)
        context.insert(other)
        let here = ImportedDocument(sourceType: "pdf", fileRef: "book.pdf", pdfPageIndex: 0, page: page)
        let there = ImportedDocument(sourceType: "pdf", fileRef: "book.pdf", pdfPageIndex: 1, page: other)
        context.insert(here); context.insert(there)
        try context.save()
        XCTAssertNil(ArtworkEdits.apply(nil, id: here.id, page: page, in: context))
    }

    /// Move, resize, rotate, crop: undo puts every field back.
    @MainActor
    func testUndoingAnAdjustment_restoresEveryField() throws {
        let (context, page) = try contextWithPage()
        let doc = ImportedDocument(sourceType: "image", fileRef: "photo.png", pdfPageIndex: 0, page: page)
        doc.frameX = 0; doc.frameY = 0; doc.frameWidth = 1; doc.frameHeight = 1
        context.insert(doc)
        try context.save()
        let before = ArtworkSnapshot(doc)

        doc.frameX = 0.25; doc.frameWidth = 0.5; doc.rotationDegrees = 90; doc.cropX = 0.1; doc.cropY = 0.1
        doc.cropWidth = 0.5; doc.cropHeight = 0.5
        let after = ArtworkSnapshot(doc)
        XCTAssertNotEqual(before, after)

        XCTAssertNil(ArtworkEdits.apply(before, id: doc.id, page: page, in: context))
        XCTAssertEqual(ArtworkSnapshot(doc), before)
        XCTAssertEqual(try documents(in: context).count, 1, "undo must edit the row in place, not add one")
    }
}
