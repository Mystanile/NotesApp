import XCTest
import SwiftData
import UIKit
import PDFKit
import PencilKit
import ImageIO
import UniformTypeIdentifiers
import SQLite3
@testable import Mystnotes

/// The paper, the imported artwork on top of it, and how that artwork is
/// loaded. Three reported bugs live here: a photo import wiped the page's
/// template, images vanished on page turns until you moved the page, and a
/// photo was decoded at full resolution however small it was being drawn.
final class PageArtworkTests: XCTestCase {

    private var written: [URL] = []

    override func tearDown() {
        for url in written { try? FileManager.default.removeItem(at: url) }
        written = []
        super.tearDown()
    }

    // MARK: - Helpers

    /// Writes a solid-colour PNG of `size` into the library and returns its
    /// file ref, the way an import would.
    @discardableResult
    private func writeImage(size: CGSize, name: String = UUID().uuidString,
                            color: UIColor = .systemTeal) throws -> String {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let data = try XCTUnwrap(image.pngData())
        let ref = "\(name).png"
        let url = FileStore.url(for: ref)
        try data.write(to: url)
        written.append(url)
        return ref
    }

    /// How many pixels differ from white, which is how "did the ruling get
    /// drawn" is answered without pinning exact pixel positions.
    private func nonWhitePixels(_ image: UIImage) throws -> Int {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var count = 0
        for pixel in stride(from: 0, to: bytes.count, by: 4) where
            bytes[pixel] < 250 || bytes[pixel + 1] < 250 || bytes[pixel + 2] < 250 {
            count += 1
        }
        return count
    }

    private func renderTemplate(_ template: String, size: CGSize = CGSize(width: 200, height: 260)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            PageTemplate.draw(template, in: size, context: context.cgContext)
        }
    }

    // MARK: - The paper

    func testBlankTemplate_drawsNothing() throws {
        XCTAssertEqual(try nonWhitePixels(renderTemplate("blank")), 0)
        XCTAssertTrue(PageTemplate.isEmpty("blank"))
        XCTAssertTrue(PageTemplate.isEmpty("whatever-this-is"))
    }

    func testRuledTemplates_drawTheirRuling() throws {
        let lined = try nonWhitePixels(renderTemplate("lined"))
        let grid = try nonWhitePixels(renderTemplate("grid"))
        let dotted = try nonWhitePixels(renderTemplate("dotted"))

        XCTAssertGreaterThan(lined, 0, "a lined page has lines")
        XCTAssertGreaterThan(grid, lined, "a grid is the lines plus the columns")
        XCTAssertGreaterThan(dotted, 0)
        XCTAssertLessThan(dotted, lined, "dots cover less of the page than rules do")
        for template in ["lined", "grid", "dotted"] {
            XCTAssertFalse(PageTemplate.isEmpty(template))
        }
    }

    /// The reported bug: the ruling came from a SwiftUI view that was drawn
    /// *instead of* imported artwork, so a photo import erased it - and the
    /// exporter and the thumbnails never drew it at all. Everything now goes
    /// through one routine, so a page with artwork still has its paper.
    func testArtworkDrawnOverATemplate_leavesTheRulingVisible() throws {
        let size = CGSize(width: 200, height: 260)
        let ruledOnly = try nonWhitePixels(renderTemplate("lined", size: size))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let composited = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            PageTemplate.draw("lined", in: size, context: context.cgContext)
            // A photo placed on part of the page, as an import that isn't
            // full bleed is.
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 20, y: 20, width: 80, height: 80))
        }

        let covered = try nonWhitePixels(composited)
        XCTAssertGreaterThan(covered, ruledOnly, "the artwork is on the page")
        // The ruling outside the artwork survives: the picture covers about
        // an eighth of the sheet, so most of the rules are still there.
        let artworkPixels = 80 * 80
        XCTAssertGreaterThan(covered - artworkPixels, ruledOnly / 2,
                             "importing a picture must not wipe the template")
    }

    // MARK: - Loading artwork

    func testRasterized_decodesDownToTheSizeAskedFor() throws {
        let ref = try writeImage(size: CGSize(width: 2000, height: 1000))

        let small = try XCTUnwrap(ImportedArtwork.rasterized(fileRef: ref, pdfPageIndex: 0,
                                                            targetSize: CGSize(width: 200, height: 200)))
        XCTAssertLessThanOrEqual(max(small.size.width, small.size.height), 200,
                                 "a thumbnail must not decode the whole photo")
        XCTAssertEqual(small.size.width / small.size.height, 2, accuracy: 0.05, "aspect ratio is kept")

        let large = try XCTUnwrap(ImportedArtwork.rasterized(fileRef: ref, pdfPageIndex: 0,
                                                            targetSize: CGSize(width: 4000, height: 4000)))
        XCTAssertEqual(large.size.width, 2000, accuracy: 1, "and it is never blown up past its own size")
    }

    func testNaturalSize_isTheFilesRealSize_notTheDecodedOne() throws {
        let ref = try writeImage(size: CGSize(width: 1600, height: 900))
        XCTAssertEqual(ImportedArtwork.naturalSize(fileRef: ref, pdfPageIndex: 0), CGSize(width: 1600, height: 900))
        XCTAssertEqual(try XCTUnwrap(ImportedArtwork.aspectRatio(fileRef: ref, pdfPageIndex: 0)),
                       1600.0 / 900.0, accuracy: 0.001)
    }

    func testFittedRect_isTheSameWhateverResolutionTheBitmapCameBackAt() throws {
        let ref = try writeImage(size: CGSize(width: 1200, height: 600))
        let page = CGSize(width: 780, height: 1040)
        let small = try XCTUnwrap(ImportedArtwork.rasterized(fileRef: ref, pdfPageIndex: 0,
                                                            targetSize: CGSize(width: 120, height: 120)))
        let big = try XCTUnwrap(ImportedArtwork.rasterized(fileRef: ref, pdfPageIndex: 0,
                                                          targetSize: CGSize(width: 1200, height: 1200)))
        // Placement is computed from the bitmap's aspect, so downsampling
        // must not move the artwork on the page.
        XCTAssertEqual(ImportedArtwork.fittedRect(for: small, in: page),
                       ImportedArtwork.fittedRect(for: big, in: page))
    }

    // MARK: - The artwork store

    /// The reported bug, at its root: a render could land and be dropped,
    /// leaving the page white with nothing to re-fire the load. The store
    /// keeps every render it completes, and hands it to whoever asks.
    @MainActor
    func testStore_rendersOnceAndServesTheResult() async throws {
        let ref = try writeImage(size: CGSize(width: 400, height: 400))
        let store = BitmapStore<ArtworkRequest>(byteLimit: 64 * 1024 * 1024) { await ArtworkRenderer.render($0) }
        let request = ArtworkRequest(
            pageID: UUID(), fileRef: ref, pdfPageIndex: 0,
            cropX: nil, cropY: nil, cropWidth: nil, cropHeight: nil,
            rotationDegrees: nil, renderSize: CGSize(width: 200, height: 200)
        )
        XCTAssertNil(store.image(for: request))

        // Asking repeatedly is safe - a view's task may re-run at any time.
        store.request(request)
        store.request(request)
        store.request(request)

        let image = try await waitForImage(of: request, in: store)
        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), 200)
        XCTAssertNotNil(store.image(for: request), "and it stays available for the next view that asks")
    }

    /// A purge must not be able to strand a page on a blank sheet: it bumps
    /// the generation, which is what re-fires the views' load tasks.
    @MainActor
    func testStore_purgeBumpsTheGeneration_andTheImageComesBack() async throws {
        let ref = try writeImage(size: CGSize(width: 300, height: 300))
        let store = BitmapStore<ArtworkRequest>(byteLimit: 64 * 1024 * 1024) { await ArtworkRenderer.render($0) }
        let request = ArtworkRequest(
            pageID: UUID(), fileRef: ref, pdfPageIndex: 0,
            cropX: nil, cropY: nil, cropWidth: nil, cropHeight: nil,
            rotationDegrees: nil, renderSize: CGSize(width: 150, height: 150)
        )
        store.request(request)
        _ = try await waitForImage(of: request, in: store)
        let generationBefore = store.generation

        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        try await waitUntil("the store purges") { store.generation != generationBefore }
        XCTAssertNil(store.image(for: request), "memory pressure drops the bitmaps")

        // What a view does when its task re-fires on the new generation.
        store.request(request)
        _ = try await waitForImage(of: request, in: store)
    }

    @MainActor
    func testStore_missingFileDoesNotWedgeTheRequest() async throws {
        let store = BitmapStore<ArtworkRequest>(byteLimit: 64 * 1024 * 1024) { await ArtworkRenderer.render($0) }
        let request = ArtworkRequest(
            pageID: UUID(), fileRef: "does-not-exist.png", pdfPageIndex: 0,
            cropX: nil, cropY: nil, cropWidth: nil, cropHeight: nil,
            rotationDegrees: nil, renderSize: CGSize(width: 100, height: 100)
        )
        store.request(request)
        // It finishes (nothing cached) rather than staying in flight
        // forever, so a later request for the same key can still run.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(store.image(for: request))
        store.request(request)
    }

    // MARK: - The bitmap store's contract

    /// Three views asking for the same bitmap at once must cost one render,
    /// and the result must outlive whoever asked for it.
    @MainActor
    func testStore_collapsesConcurrentRequests() async throws {
        let renders = RenderCounter()
        let store = BitmapStore<Int>(byteLimit: 1024 * 1024) { _ in
            await renders.increment()
            try? await Task.sleep(nanoseconds: 50_000_000)
            return UIImage(systemName: "star")
        }

        store.request(1)
        store.request(1)
        store.request(1)
        try await waitUntil("the render lands") { store.image(for: 1) != nil }

        // And a later ask is served without rendering again.
        store.request(1)
        try await Task.sleep(nanoseconds: 100_000_000)
        let count = await renders.count
        XCTAssertEqual(count, 1, "one render for one key, however many views want it")
    }

    private func squareStore(byteLimit: Int) -> BitmapStore<Int> {
        BitmapStore<Int>(byteLimit: byteLimit) { _ in
            UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            }
        }
    }

    @MainActor
    func testStore_evictsLeastRecentlyReadPastItsBudget_andSaysSo() async throws {
        let store = squareStore(byteLimit: 1)
        store.recentWindow = 0   // nothing counts as on screen
        store.request(1)
        try await waitUntil("the first render lands") { store.contains(1) }
        let generation = store.generation

        store.request(2)
        try await waitUntil("the second render lands") { store.contains(2) }

        XCTAssertFalse(store.contains(1), "the least recently read goes when the budget is blown")
        XCTAssertNotEqual(store.generation, generation, "and the views are told, so they can ask again")
    }

    /// The strip on the iPad cycled forever, one thumbnail visible at a
    /// time (Sept 19, 2026): five on screen needed more than the budget,
    /// so landing each one evicted another and told its view to ask again.
    /// Anything read a moment ago is on screen and stays, budget or not.
    @MainActor
    func testStore_neverEvictsWhatWasJustRead_soAStripCannotCycle() async throws {
        let store = squareStore(byteLimit: 1)
        for key in 1...5 {
            store.request(key)
            try await waitUntil("render \(key) lands") { store.contains(key) }
            // What the strip does: every visible cell reads its bitmap
            // whenever the store changes.
            for shown in 1...key { XCTAssertNotNil(store.image(for: shown), "\(shown) must still be there") }
        }
        let generation = store.generation
        XCTAssertEqual((1...5).filter { store.contains($0) }.count, 5, "all five stay, over budget")

        // Time passes, the strip scrolls on: the stale ones can go.
        store.recentWindow = 0
        store.request(6)
        try await waitUntil("render 6 lands") { store.contains(6) }
        XCTAssertTrue(store.contains(6))
        XCTAssertLessThan((1...5).filter { store.contains($0) }.count, 5)
        XCTAssertNotEqual(store.generation, generation)
    }

    /// A body that reads a bitmap the store doesn't have gets it rendered -
    /// so a view whose entry was evicted heals on its next draw, without
    /// anything having to re-fire its task.
    @MainActor
    func testStore_readingAMissingBitmap_asksForIt() async throws {
        let store = squareStore(byteLimit: 1024 * 1024)
        XCTAssertNil(store.image(for: 7))
        try await waitUntil("the read started a render") { store.contains(7) }
        XCTAssertNotNil(store.image(for: 7))
    }

    private actor RenderCounter {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    // MARK: - Thumbnails

    /// A page's strip thumbnail draws the same stack the editor does, so a
    /// lined page looks lined in the strip. Nothing drew a template into a
    /// thumbnail at all before.
    func testThumbnail_showsTheTemplate() async throws {
        let request = PageThumbnailRequest(
            pageID: UUID(), inkStamp: "-", template: "grid", artwork: [],
            nominal: CGSize(width: 780, height: 1040), output: CGSize(width: 120, height: 160)
        )
        let rendered = await PageThumbnailRenderer.render(request)
        let image = try XCTUnwrap(rendered, "a ruled page has a thumbnail even with no ink")
        XCTAssertGreaterThan(try nonWhitePixels(image), 0, "the ruling survives at the strip's scale")

        var blank = request
        blank.template = "blank"
        let blankRender = await PageThumbnailRenderer.render(blank)
        XCTAssertNil(blankRender, "a blank page with no ink and no artwork still has nothing to show")
    }

    /// An edit to one page must not invalidate every other page's
    /// thumbnail: the ink stamp is per page.
    func testThumbnailRequest_changesOnlyForThePageThatChanged() {
        let base = PageThumbnailRequest(
            pageID: UUID(), inkStamp: "a|1", template: "lined", artwork: [],
            nominal: CGSize(width: 780, height: 1040), output: CGSize(width: 120, height: 160)
        )
        var edited = base
        edited.inkStamp = "a|2"
        XCTAssertNotEqual(base, edited)

        var otherPage = base
        otherPage.pageID = UUID()
        XCTAssertNotEqual(base, otherPage)
        XCTAssertEqual(base, base, "an unchanged page keeps its cached thumbnail")
    }

    // MARK: - The page sidebar's sizing (see PageSidebarTests)

    /// Resizing must re-render the bitmap, or a strip dragged large shows
    /// blurry thumbnails - but in steps, or every intermediate height
    /// during a drag would be its own cache entry and its own render.
    func testThumbnailRequest_renderSizeStepsWithTheHeight() {
        func request(atHeight height: CGFloat) -> PageThumbnailRequest {
            PageThumbnailRequest(
                pageID: UUID(), inkStamp: "-", template: "blank", artwork: [],
                nominal: CGSize(width: 780, height: 1040),
                output: CGSize(width: (height * 2 / 80).rounded(.up) * 80 * 0.75,
                               height: min((max(height * 2, 160) / 80).rounded(.up) * 80, 560))
            )
        }
        // Nudging the drag by a point doesn't invalidate the cache...
        XCTAssertEqual(request(atHeight: 100).output, request(atHeight: 104).output)
        // ...but dragging it properly bigger does.
        XCTAssertNotEqual(request(atHeight: 100).output, request(atHeight: 200).output)
        XCTAssertGreaterThan(request(atHeight: 300).output.height, request(atHeight: 100).output.height)
        // And it is bounded, so a huge strip can't ask for a huge bitmap.
        XCTAssertEqual(request(atHeight: 5000).output.height, 560)
    }

    // MARK: - A page's artwork stack

    /// The colour at one point of an image, for checking which layer is on
    /// top there.
    private func pixel(of image: UIImage, at point: CGPoint) throws -> (r: UInt8, g: UInt8, b: UInt8) {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Top-left origin, in points; the bitmap may be 2x.
        let scale = CGFloat(width) / image.size.width
        let x = min(max(Int(point.x * scale), 0), width - 1)
        let y = min(max(Int(point.y * scale), 0), height - 1)
        let offset = (y * width + x) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }

    private func isRed(_ p: (r: UInt8, g: UInt8, b: UInt8)) -> Bool { p.r > 200 && p.g < 80 && p.b < 80 }
    private func isBlue(_ p: (r: UInt8, g: UInt8, b: UInt8)) -> Bool { p.b > 200 && p.r < 80 && p.g < 80 }

    private func layer(_ ref: String, frame: CGRect?) -> ArtworkLayer {
        ArtworkLayer(id: UUID(), fileRef: ref, sourceType: "image", pdfPageIndex: 0,
                     frameX: frame.map { $0.minX }, frameY: frame.map { $0.minY },
                     frameWidth: frame.map { $0.width }, frameHeight: frame.map { $0.height })
    }

    /// A page can hold several pieces of artwork - a PDF page as its paper
    /// with photos placed over it - and a thumbnail draws all of them,
    /// bottom first, each at its own placement. Importing a PDF onto a page
    /// with a photo on it used to throw the photo away.
    func testThumbnail_drawsEveryLayer_bottomFirst() async throws {
        let paper = try writeImage(size: CGSize(width: 400, height: 400), color: .red)
        let photo = try writeImage(size: CGSize(width: 200, height: 200), color: .blue)
        let stack = [
            layer(paper, frame: CGRect(x: 0, y: 0, width: 1, height: 1)),
            layer(photo, frame: CGRect(x: 0.5, y: 0.5, width: 0.4, height: 0.4)),
        ]
        let request = PageThumbnailRequest(
            pageID: UUID(), inkStamp: "-", template: "blank", artwork: stack,
            nominal: CGSize(width: 400, height: 400), output: CGSize(width: 200, height: 200)
        )
        let rendered = await PageThumbnailRenderer.render(request)
        let image = try XCTUnwrap(rendered)
        XCTAssertTrue(isRed(try pixel(of: image, at: CGPoint(x: 20, y: 20))), "the paper shows where nothing covers it")
        XCTAssertTrue(isBlue(try pixel(of: image, at: CGPoint(x: 140, y: 140))), "the photo sits on top of the paper")

        // The same two the other way up: the order is the stack's, not
        // the import's.
        var flipped = request
        flipped.artwork = stack.reversed()
        let overRendered = await PageThumbnailRenderer.render(flipped)
        let over = try XCTUnwrap(overRendered)
        XCTAssertTrue(isRed(try pixel(of: over, at: CGPoint(x: 140, y: 140))), "the paper now covers the photo")
    }

    /// Placement is not part of a layer's bitmap key: moving a picture on a
    /// page with three of them re-renders none of them.
    func testArtworkRequest_ignoresPlacement() {
        let ref = "same.png"
        var moved = layer(ref, frame: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        let request = ArtworkRequest(pageID: UUID(), layer: moved, renderSize: CGSize(width: 100, height: 100))
        moved.frameX = 0.4
        XCTAssertEqual(ArtworkRequest(pageID: request.pageID, layer: moved, renderSize: request.renderSize), request)
        moved.rotationDegrees = 90
        XCTAssertNotEqual(ArtworkRequest(pageID: request.pageID, layer: moved, renderSize: request.renderSize), request,
                          "but a rotation is a different picture")
    }

    /// Where a new import lands in the stack: a full-bleed PDF is the
    /// page's paper and goes under whatever is there; a picture goes on
    /// top. Records from before ordering existed sit at 0 and keep a
    /// stable order between themselves.
    @MainActor
    func testStack_pdfGoesUnder_photoGoesOver_andNothingIsReplaced() throws {
        let container = try ModelContainer(
            for: Folder.self, Notebook.self, Page.self, TypedTextBlock.self, ImportedDocument.self, Link.self, Sticker.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let notebook = Notebook(title: "T")
        context.insert(notebook)
        let page = Page(index: 0, notebook: notebook)
        context.insert(page)
        let other = Page(index: 1, notebook: notebook)
        context.insert(other)

        func add(_ ref: String, on target: Page, order: Int?) -> ImportedDocument {
            let doc = ImportedDocument(sourceType: ref.hasSuffix(".pdf") ? "pdf" : "image", fileRef: ref, page: target)
            doc.stackOrder = order
            context.insert(doc)
            return doc
        }
        let first = add("a.png", on: page, order: nil)
        let second = add("b.png", on: page, order: nil)
        _ = add("elsewhere.png", on: other, order: nil)
        try context.save()

        let all = try context.fetch(FetchDescriptor<ImportedDocument>())
        let legacy = ImportedDocument.stack(on: page.id, in: all)
        XCTAssertEqual(Set(legacy.map(\.id)), [first.id, second.id], "only this page's artwork")
        XCTAssertEqual(legacy.map(\.id), [first.id, second.id].sorted { $0.uuidString < $1.uuidString })

        let paper = add("paper.pdf", on: page, order: ImportedDocument.stackOrder(under: legacy))
        let stackWithPaper = ImportedDocument.stack(on: page.id, in: try context.fetch(FetchDescriptor<ImportedDocument>()))
        XCTAssertEqual(stackWithPaper.first?.id, paper.id, "the PDF is the paper: under the photos")
        XCTAssertEqual(stackWithPaper.count, 3, "and the photos are still there")

        let sticker = add("c.png", on: page, order: ImportedDocument.stackOrder(over: stackWithPaper))
        let full = ImportedDocument.stack(on: page.id, in: try context.fetch(FetchDescriptor<ImportedDocument>()))
        XCTAssertEqual(full.map(\.id), [paper.id] + legacy.map(\.id) + [sticker.id])

        // As layers, in the same order - and a page from before
        // `ImportedDocument` existed is one unplaced layer keyed by the page.
        XCTAssertEqual(ArtworkLayer.stack(for: page, documents: full).map(\.id), full.map(\.id))
        let old = Page(index: 2, notebook: notebook)
        old.backgroundRef = "old.pdf"
        let oldLayers = ArtworkLayer.stack(for: old, documents: full)
        XCTAssertEqual(oldLayers.map(\.id), [old.id])
        XCTAssertEqual(oldLayers.first?.sourceType, "pdf")
        XCTAssertEqual(ArtworkLayer.stack(for: other, documents: []), [], "no artwork, no layers")
    }

    /// Dragging the strip taller doesn't re-render until the finger lifts:
    /// the request follows `renderHeight`, the cell size follows `height`.
    @MainActor
    func testThumbnail_midDragScalesTheBitmapItHas() throws {
        let container = try ModelContainer(
            for: Folder.self, Notebook.self, Page.self, TypedTextBlock.self, ImportedDocument.self, Link.self, Sticker.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let notebook = Notebook(title: "T")
        container.mainContext.insert(notebook)
        let page = Page(index: 0, notebook: notebook)
        container.mainContext.insert(page)

        let resting = PageThumbnailView(page: page, height: 100)
        let dragging = PageThumbnailView(page: page, height: 260, renderHeight: 100)
        let released = PageThumbnailView(page: page, height: 260)
        XCTAssertEqual(dragging.thumbnailRequest, resting.thumbnailRequest, "same bitmap while the drag is on")
        XCTAssertNotEqual(released.thumbnailRequest, resting.thumbnailRequest, "one new render once it's released")
    }

    // MARK: - Export

    /// "Export All Pages as PDF" is every page, one PDF page each, in
    /// order and at each page's own shape.
    @MainActor
    func testNotebookExport_hasEveryPage() throws {
        let container = try ModelContainer(
            for: Folder.self, Notebook.self, Page.self, TypedTextBlock.self, ImportedDocument.self, Link.self, Sticker.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let notebook = Notebook(title: "T")
        container.mainContext.insert(notebook)
        let pages = (0..<3).map { index -> Page in
            let page = Page(index: index, notebook: notebook)
            container.mainContext.insert(page)
            return page
        }
        pages[1].aspectRatio = 1.5   // a landscape page in the middle

        let data = PageRenderer.pdfData(for: pages.map { (page: $0, artwork: []) })
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(document.pageCount, 3)
        let sizes = (0..<3).compactMap { document.page(at: $0)?.bounds(for: .mediaBox).size }
        XCTAssertGreaterThan(sizes[1].width, sizes[1].height, "the landscape page exports landscape")
        XCTAssertLessThan(sizes[0].width, sizes[0].height)
    }

    /// The export draws what the editor shows: a cropped, placed PDF page
    /// and the page's ink from the store. Reported Sept 19, 2026 as an
    /// export with the PDF uncropped and none of the handwriting.
    @MainActor
    func testExport_drawsTheCroppedArtworkAndTheInk() throws {
        let container = try ModelContainer(
            for: Folder.self, Notebook.self, Page.self, TypedTextBlock.self, ImportedDocument.self, Link.self, Sticker.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let notebook = Notebook(title: "T")
        container.mainContext.insert(notebook)
        let page = Page(index: 0, notebook: notebook)
        container.mainContext.insert(page)

        // A PDF page: red letterhead band across the top 15%, white below.
        let pdfBounds = CGRect(x: 0, y: 0, width: 400, height: 520)
        let pdf = UIGraphicsPDFRenderer(bounds: pdfBounds).pdfData { context in
            context.beginPage()
            UIColor.white.setFill(); context.fill(pdfBounds)
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 400, height: 78))
        }
        let ref = "\(UUID().uuidString).pdf"
        let url = FileStore.url(for: ref)
        try pdf.write(to: url)
        written.append(url)
        page.backgroundRef = ref
        let doc = ImportedDocument(sourceType: "pdf", fileRef: ref, pdfPageIndex: 0, page: page)
        doc.cropX = 0; doc.cropY = 0.15; doc.cropWidth = 1; doc.cropHeight = 0.85   // letterhead cropped away
        doc.frameX = 0; doc.frameY = 0; doc.frameWidth = 1; doc.frameHeight = 1
        container.mainContext.insert(doc)
        try container.mainContext.save()

        // Blue ink low on the page, saved the way the editor saves it.
        let points = stride(from: CGFloat(100), through: 600, by: 5).map { x in
            PKStrokePoint(location: CGPoint(x: x, y: 800), timeOffset: 0, size: CGSize(width: 10, height: 10),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let stroke = PKStroke(ink: PKInk(.pen, color: .blue), path: PKStrokePath(controlPoints: points, creationDate: Date()))
        let store = DrawingStore.live
        _ = try store.save(PKDrawing(strokes: [stroke]), pageID: page.id)
        written.append(store.fileURL(for: page.id))

        let all = try container.mainContext.fetch(FetchDescriptor<ImportedDocument>())
        let artwork = ArtworkLayer.stack(for: page, documents: all)
        XCTAssertEqual(artwork.first?.cropY, 0.15, "the export is handed the crop")
        let image = PageRenderer.image(for: page, artwork: artwork, scale: 1)
        let nominal = PageGeometry.contentSize(for: page)

        let top = try pixel(of: image, at: CGPoint(x: nominal.width / 2, y: 4))
        XCTAssertFalse(isRed(top), "the letterhead was cropped away in the editor; it must be in the export too")
        let ink = try pixel(of: image, at: CGPoint(x: 300, y: 800))
        XCTAssertTrue(isBlue(ink), "the page's ink is in the export (got \(ink))")
    }

    /// The iPad was in dark mode. `PKDrawing.image(from:)` renders through
    /// the current traits and PencilKit inverts ink for a dark appearance,
    /// so every export - and every thumbnail - came out with the black
    /// handwriting drawn white on white paper (Sept 19, 2026). The canvas
    /// is pinned to light for exactly this reason; the off-screen renders
    /// have to be too.
    @MainActor
    func testExport_keepsInkDarkInDarkMode() async throws {
        let container = try ModelContainer(
            for: Folder.self, Notebook.self, Page.self, TypedTextBlock.self, ImportedDocument.self, Link.self, Sticker.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let notebook = Notebook(title: "T")
        container.mainContext.insert(notebook)
        let page = Page(index: 0, notebook: notebook)
        container.mainContext.insert(page)

        let points = stride(from: CGFloat(100), through: 600, by: 5).map { x in
            PKStrokePoint(location: CGPoint(x: x, y: 500), timeOffset: 0, size: CGSize(width: 12, height: 12),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))
        let store = DrawingStore.live
        _ = try store.save(PKDrawing(strokes: [stroke]), pageID: page.id)
        written.append(store.fileURL(for: page.id))

        func isDark(_ p: (r: UInt8, g: UInt8, b: UInt8)) -> Bool { p.r < 80 && p.g < 80 && p.b < 80 }

        var exported: UIImage?
        UITraitCollection(userInterfaceStyle: .dark).performAsCurrent {
            exported = PageRenderer.image(for: page, artwork: [], scale: 1)
        }
        let export = try XCTUnwrap(exported)
        XCTAssertTrue(isDark(try pixel(of: export, at: CGPoint(x: 350, y: 500))),
                      "black ink exports black whatever the system appearance")

        // The thumbnail renderer runs detached, where "current" traits are
        // the thread's own and can't be set from here; it pins light the
        // same way, and this at least proves the render itself.
        let request = PageThumbnailRequest(
            pageID: page.id, inkStamp: "-", template: "lined", artwork: [],
            nominal: PageGeometry.contentSize(for: page), output: CGSize(width: 390, height: 520)
        )
        let renderedThumbnail = await PageThumbnailRenderer.render(request)
        let thumbnail = try XCTUnwrap(renderedThumbnail)
        XCTAssertTrue(isDark(try pixel(of: thumbnail, at: CGPoint(x: 175, y: 250))))
    }

    // MARK: - Sniffing imports

    func testFileType_readsTheHeaderNotTheLabel() throws {
        let png = try XCTUnwrap(UIImage(systemName: "star")?.pngData())
        XCTAssertEqual(ImportedFileType.of(png), .png)

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let jpeg = try XCTUnwrap(renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.jpegData(compressionQuality: 0.8))
        XCTAssertEqual(ImportedFileType.of(jpeg), .jpeg)

        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 10, height: 10)).pdfData { context in
            context.beginPage()
        }
        XCTAssertEqual(ImportedFileType.of(pdf), .pdf)
        XCTAssertTrue(try XCTUnwrap(ImportedFileType.of(pdf)).isPDF,
                      "a pasted PDF goes down the PDF path, not the image one")

        XCTAssertNil(ImportedFileType.of(Data("not a picture at all".utf8)))
        XCTAssertNil(ImportedFileType.of(Data()))
    }

    // MARK: - Waiting

    @MainActor
    private func waitForImage(of request: ArtworkRequest, in store: BitmapStore<ArtworkRequest>,
                              file: StaticString = #filePath, line: UInt = #line) async throws -> UIImage {
        try await waitUntil("the render lands", file: file, line: line) { store.image(for: request) != nil }
        return try XCTUnwrap(store.image(for: request), file: file, line: line)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }
}

// MARK: - Deleting a notebook that holds artwork

extension PageArtworkTests {
    /// Deleting a notebook cascades to its pages, but `ImportedDocument`
    /// hung off `Page` one-way, so its rows survived pointing at pages
    /// that were gone. The next notebook to open scanned every document
    /// in the library, hit the dangling row and crashed. The store is
    /// closed and reopened so nothing is served from memory.
    @MainActor
    func testDeleteNotebook_takesItsImportedDocumentsWithIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        written.append(directory)
        let storeURL = directory.appendingPathComponent("store.sqlite")
        let schema = Schema([Folder.self, Notebook.self, Page.self, TypedTextBlock.self,
                             ImportedDocument.self, Link.self, Sticker.self])
        func open() throws -> ModelContainer {
            try ModelContainer(for: schema, configurations: [
                ModelConfiguration("t", schema: schema, url: storeURL, cloudKitDatabase: .none)
            ])
        }

        let doomed = Notebook(title: "Doomed")
        let survivor = Notebook(title: "Survivor")
        do {
            let context = ModelContext(try open())
            context.insert(doomed)
            context.insert(survivor)
            let page = Page(index: 0, notebook: doomed)
            context.insert(page)
            context.insert(ImportedDocument(sourceType: "image", fileRef: "a.png", page: page))
            let kept = Page(index: 0, notebook: survivor)
            context.insert(kept)
            context.insert(ImportedDocument(sourceType: "image", fileRef: "b.png", page: kept))
            try context.save()

            let id = doomed.id
            let notebook = try XCTUnwrap(context.fetch(FetchDescriptor<Notebook>(predicate: #Predicate { $0.id == id })).first)
            context.delete(notebook)
            try context.save()
        }

        let context = ModelContext(try open())
        let docs = try context.fetch(FetchDescriptor<ImportedDocument>())
        XCTAssertEqual(docs.map(\.fileRef), ["b.png"], "the deleted notebook's artwork rows are gone")
        let keptID = try XCTUnwrap(context.fetch(FetchDescriptor<Page>()).first?.id)
        XCTAssertEqual(ImportedDocument.stacksByPage(docs)[keptID]?.count, 1)
    }

    /// A store from before the cascade already holds rows pointing at
    /// pages that are gone. The launch sweep drops them without touching
    /// `doc.page` (which is the crash). The dangling row is planted
    /// through SQLite because the model can no longer produce one.
    @MainActor
    func testDropOrphanedArtwork_removesRowsWhosePageIsGone() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        written.append(directory)
        let storeURL = directory.appendingPathComponent("store.sqlite")
        let schema = Schema([Folder.self, Notebook.self, Page.self, TypedTextBlock.self,
                             ImportedDocument.self, Link.self, Sticker.self])
        func open() throws -> ModelContainer {
            try ModelContainer(for: schema, configurations: [
                ModelConfiguration("t", schema: schema, url: storeURL, cloudKitDatabase: .none)
            ])
        }

        do {
            let context = ModelContext(try open())
            let notebook = Notebook(title: "T")
            context.insert(notebook)
            let page = Page(index: 0, notebook: notebook)
            context.insert(page)
            context.insert(ImportedDocument(sourceType: "image", fileRef: "orphan.png", page: page))
            let kept = Page(index: 1, notebook: notebook)
            context.insert(kept)
            context.insert(ImportedDocument(sourceType: "image", fileRef: "kept.png", page: kept))
            try context.save()
        }

        // Point orphan.png's foreign key at a page row that does not exist.
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(storeURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "UPDATE ZIMPORTEDDOCUMENT SET ZPAGE = 999999 WHERE ZFILEREF = 'orphan.png'", nil, nil, nil), SQLITE_OK,
                       String(cString: sqlite3_errmsg(db)))
        XCTAssertEqual(sqlite3_changes(db), 1, "the fixture row was rewritten")

        let container = try open()
        XCTAssertEqual(try LibraryRebuild.dropOrphanedArtwork(container: container), 1)

        let context = ModelContext(container)
        let docs = try context.fetch(FetchDescriptor<ImportedDocument>())
        XCTAssertEqual(docs.map(\.fileRef), ["kept.png"])
        XCTAssertEqual(ImportedDocument.stacksByPage(docs).count, 1, "and the survivors still resolve their page")
        XCTAssertEqual(try LibraryRebuild.dropOrphanedArtwork(container: container), 0, "nothing left to drop")
    }
}
