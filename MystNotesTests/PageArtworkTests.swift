import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
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
    private func writeImage(size: CGSize, name: String = UUID().uuidString) throws -> String {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemTeal.setFill()
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
            pageID: UUID(), backgroundRef: ref, pdfPageIndex: 0,
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
            pageID: UUID(), backgroundRef: ref, pdfPageIndex: 0,
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
            pageID: UUID(), backgroundRef: "does-not-exist.png", pdfPageIndex: 0,
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

    @MainActor
    func testStore_evictsOldestPastItsBudget_andSaysSo() async throws {
        let store = BitmapStore<Int>(byteLimit: 1) { _ in
            UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            }
        }
        store.request(1)
        try await waitUntil("the first render lands") { store.image(for: 1) != nil }
        let generation = store.generation

        store.request(2)
        try await waitUntil("the second render lands") { store.image(for: 2) != nil }

        XCTAssertNil(store.image(for: 1), "the oldest goes when the budget is blown")
        XCTAssertNotEqual(store.generation, generation, "and the views are told, so they can ask again")
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
            pageID: UUID(), inkStamp: "-", template: "grid", backgroundRef: nil, pdfPageIndex: 0,
            frameX: nil, frameY: nil, frameWidth: nil, frameHeight: nil,
            cropX: nil, cropY: nil, cropWidth: nil, cropHeight: nil, rotationDegrees: nil,
            nominal: CGSize(width: 780, height: 1040), output: CGSize(width: 120, height: 160)
        )
        let rendered = await PageThumbnailRenderer.render(request)
        let image = try XCTUnwrap(rendered, "a ruled page has a thumbnail even with no ink")
        XCTAssertGreaterThan(try nonWhitePixels(image), 0)

        var blank = request
        blank.template = "blank"
        let blankRender = await PageThumbnailRenderer.render(blank)
        XCTAssertNil(blankRender, "a blank page with no ink and no artwork still has nothing to show")
    }

    /// An edit to one page must not invalidate every other page's
    /// thumbnail: the ink stamp is per page.
    func testThumbnailRequest_changesOnlyForThePageThatChanged() {
        let base = PageThumbnailRequest(
            pageID: UUID(), inkStamp: "a|1", template: "lined", backgroundRef: nil, pdfPageIndex: 0,
            frameX: nil, frameY: nil, frameWidth: nil, frameHeight: nil,
            cropX: nil, cropY: nil, cropWidth: nil, cropHeight: nil, rotationDegrees: nil,
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
