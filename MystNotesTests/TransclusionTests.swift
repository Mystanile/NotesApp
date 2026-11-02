import XCTest
import SwiftData
import PencilKit
import UIKit
@testable import Mystnotes

/// M2 task 9: a node's ink shown on another page (a "transclusion" link).
/// Model helpers, thumbnail invalidation, the cycle guard, the Markdown line.
/// Export pixels are in `PageElementsExportTests`; sync in `SyncTests`.
@MainActor
final class TransclusionTests: XCTestCase {
    private static var container: ModelContainer?
    private var directory: URL!
    private var store: DrawingStore!

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Folder.self, Notebook.self, Page.self, TypedTextBlock.self, Sticker.self, ImportedDocument.self, Link.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        Self.container = container
        return container.mainContext
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransclusionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = DrawingStore.inDirectory(directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Horizontal pen lines, 60pt apart, so each stroke is its own band.
    static func makeDrawing(strokes count: Int) -> PKDrawing {
        let ink = PKInk(.pen, color: .black)
        return PKDrawing(strokes: (0..<count).map { index in
            let points = (0..<12).map { point in
                PKStrokePoint(location: CGPoint(x: 40 + CGFloat(point) * 8, y: 100 + CGFloat(index) * 60),
                              timeOffset: TimeInterval(point) * 0.008, size: CGSize(width: 3, height: 3),
                              opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            let path = PKStrokePath(controlPoints: points,
                                    creationDate: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)))
            return PKStroke(ink: ink, path: path, randomSeed: UInt32(index + 1))
        })
    }

    /// A page with a saved drawing and a node over some of its strokes.
    private func ownerWithNode(in context: ModelContext, notebook: Notebook, index: Int = 0,
                               title: String = "Chain", selecting picked: [Int] = [1, 2]) throws
        -> (page: Page, node: Link, drawing: PKDrawing) {
        let page = Page(index: index, notebook: notebook)
        context.insert(page)
        notebook.pages = (notebook.pages ?? []) + [page]
        let drawing = Self.makeDrawing(strokes: 4)
        try store.save(drawing, pageID: page.id)
        let map = store.ids.map(for: page.id)
        let selected = picked.map { drawing.strokes[$0] }
        let ids = try selected.map { try XCTUnwrap(map.existingID(for: $0)).uuidString }
        let node = Links.makeNode(on: page, strokeIDs: ids, title: title,
                                  anchor: PKDrawing(strokes: selected).bounds, in: context)
        return (page, node, drawing)
    }

    private func notebook(_ title: String, in context: ModelContext) -> Notebook {
        let notebook = Notebook(title: title)
        context.insert(notebook)
        return notebook
    }

    private func inkedPixels(in rect: CGRect, of image: UIImage) throws -> Int {
        let cg = try XCTUnwrap(image.cgImage)
        let scale = CGFloat(cg.width) / image.size.width
        var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        px.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8,
                      bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                .draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        var count = 0
        for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
            for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                let i = (y * cg.width + x) * 4
                if px[i] < 200 || px[i + 1] < 200 || px[i + 2] < 200 { count += 1 }
            }
        }
        return count
    }

    private func render(_ elements: PageElements, size: CGSize = CGSize(width: 800, height: 1000)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            elements.draw(in: size, regionInk: { self.store.readRegionInk(pageID: $0, ids: $1) })
        }
    }

    // MARK: Model

    func testAddTransclusion_fillsTheFields_andMarksTheHost() throws {
        let context = try makeContext()
        let source = notebook("Source", in: context)
        let (owner, node, _) = try ownerWithNode(in: context, notebook: source)
        let host = Page(index: 0, notebook: notebook("Host", in: context))
        context.insert(host)

        let link = Links.addTransclusion(of: node, onto: host, frame: CGRect(x: 10, y: 20, width: 300, height: 120),
                                         in: context, now: Date(timeIntervalSince1970: 700))
        XCTAssertEqual(link.kind, "transclusion")
        XCTAssertEqual(link.destinationKind, "region")
        XCTAssertEqual(link.destinationID, node.id.uuidString)
        XCTAssertEqual(link.sourcePageID, host.id)
        XCTAssertEqual(link.destinationPageID, owner.id)
        XCTAssertNil(link.strokeIDs, "the node owns the stroke list")
        XCTAssertEqual(host.modifiedAt, Date(timeIntervalSince1970: 700))
        XCTAssertFalse(Links.isPlainLink(link))
        XCTAssertFalse(Links.isUnfinished(link))
        XCTAssertEqual(Links.node(for: link, in: [node, link])?.id, node.id)
    }

    func testMoveAndRemoveTransclusion_markTheHost_andRemoveIsUndoable() throws {
        let context = try makeContext()
        let (_, node, _) = try ownerWithNode(in: context, notebook: notebook("Source", in: context))
        let host = Page(index: 0, notebook: notebook("Host", in: context))
        context.insert(host)
        let link = Links.addTransclusion(of: node, onto: host, frame: CGRect(x: 0, y: 0, width: 100, height: 50),
                                         in: context, now: Date(timeIntervalSince1970: 100))

        Links.moveTransclusion(link, to: CGRect(x: 5, y: 6, width: 200, height: 100), in: context,
                               now: Date(timeIntervalSince1970: 200))
        XCTAssertEqual([link.anchorX, link.anchorY, link.anchorWidth, link.anchorHeight], [5, 6, 200, 100])
        XCTAssertEqual(host.modifiedAt, Date(timeIntervalSince1970: 200))

        let snapshot = Links.removeTransclusion(link, in: context, now: Date(timeIntervalSince1970: 300))
        XCTAssertEqual(host.modifiedAt, Date(timeIntervalSince1970: 300))
        XCTAssertTrue(try context.fetch(FetchDescriptor<Link>()).allSatisfy { !Links.isTransclusion($0) })
        XCTAssertNotNil(node.modelContext, "the node and its ink are untouched")

        let restored = try XCTUnwrap(Links.restoreTransclusion(snapshot, in: context, now: Date(timeIntervalSince1970: 400)))
        XCTAssertEqual(restored.id, snapshot.id, "same identity")
        XCTAssertEqual([restored.anchorX, restored.anchorWidth], [5, 200])
        XCTAssertEqual(host.modifiedAt, Date(timeIntervalSince1970: 400))
    }

    func testRemoveAllTouching_removesATransclusionWhoseOwnerPageIsDeleted() throws {
        let context = try makeContext()
        let (owner, node, _) = try ownerWithNode(in: context, notebook: notebook("Source", in: context))
        let host = Page(index: 0, notebook: notebook("Host", in: context))
        context.insert(host)
        Links.addTransclusion(of: node, onto: host, frame: CGRect(x: 0, y: 0, width: 100, height: 50), in: context,
                              now: Date(timeIntervalSince1970: 100))

        Links.removeAll(touching: [owner.id], in: context, now: Date(timeIntervalSince1970: 900))
        try context.save()
        XCTAssertTrue(try context.fetch(FetchDescriptor<Link>()).isEmpty)
        XCTAssertEqual(host.modifiedAt, Date(timeIntervalSince1970: 900), "the host ships the removal")
    }

    func testTransclusionFrame_followsTheNodesShape_andStaysOnThePage() {
        let node = Link()
        (node.anchorWidth, node.anchorHeight) = (100, 50)
        let frame = Links.transclusionFrame(for: node, centeredAt: CGPoint(x: 5, y: 5),
                                            pageSize: CGSize(width: 800, height: 1000), longSide: 300)
        XCTAssertEqual(frame.width / frame.height, 2, accuracy: 0.01)
        XCTAssertEqual(frame.width, 300, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(frame.minX, 0)
        XCTAssertGreaterThanOrEqual(frame.minY, 0)
    }

    // MARK: Invalidation

    func testHostThumbnailRequest_changesWhenTheOwnersModifiedAtChanges() throws {
        let context = try makeContext()
        let (owner, node, _) = try ownerWithNode(in: context, notebook: notebook("Source", in: context))
        let host = Page(index: 0, notebook: notebook("Host", in: context))
        context.insert(host)
        Links.addTransclusion(of: node, onto: host, frame: CGRect(x: 0, y: 0, width: 100, height: 50), in: context,
                              now: Date(timeIntervalSince1970: 100))

        func request() throws -> PageThumbnailRequest {
            let links = try context.fetch(FetchDescriptor<Link>())
            let resolved = PageElements.resolveTransclusions(hostedOn: host.id, links: links, owners: [owner.id: owner])
            XCTAssertEqual(resolved.count, 1)
            return PageThumbnailView(page: host, transclusions: resolved).thumbnailRequest
        }
        let before = try request()
        XCTAssertEqual(before, try request(), "stable while nothing changes")

        owner.markModified(at: Date(timeIntervalSince1970: 5_000))
        let after = try request()
        XCTAssertNotEqual(before, after)
        XCTAssertNotEqual(before.hashValue, after.hashValue)

        // The export-side initialiser sees the owner too.
        let fetched = PageElements(page: host)
        XCTAssertEqual(fetched.transclusions.count, 1)
        XCTAssertEqual(fetched.transclusions.first?.ownerStamp, PageElements.ownerStamp(of: owner))
        XCTAssertEqual(fetched.transclusions.first?.strokeIDs, (node.strokeIDs ?? []).sorted())
    }

    func testBitmapRequest_keysOnTheOwnersStamp_notOnSize() {
        let id = UUID()
        let a = TransclusionRequest(ownerPageID: id, ownerModifiedAt: Date(timeIntervalSince1970: 1),
                                    ownerDrawingFileRef: "x", strokeIDs: ["B", "A"])
        var b = a
        b.ownerModifiedAt = Date(timeIntervalSince1970: 2)
        XCTAssertNotEqual(a, b)
    }

    // MARK: Cycle guard

    /// A hosts B's node and B hosts A's. A transclusion draws only the owner's
    /// strokes, never the owner's elements, so neither render contains the
    /// other's transclusion and both finish.
    func testMutualTransclusion_rendersFinite_andEachShowsOnlyTheOtherOwnersStrokes() async throws {
        let context = try makeContext()
        let book = notebook("Loop", in: context)
        let (a, nodeA, _) = try ownerWithNode(in: context, notebook: book, index: 0, title: "A ink")
        let (b, nodeB, _) = try ownerWithNode(in: context, notebook: book, index: 1, title: "B ink")
        let frame = CGRect(x: 100, y: 200, width: 300, height: 200)
        Links.addTransclusion(of: nodeB, onto: a, frame: frame, in: context)
        Links.addTransclusion(of: nodeA, onto: b, frame: frame, in: context)
        let links = try context.fetch(FetchDescriptor<Link>())
        let owners = [a.id: a, b.id: b]

        for host in [a, b] {
            let elements = PageElements(texts: [], stickers: [], links: [],
                                        transclusions: PageElements.resolveTransclusions(hostedOn: host.id, links: links, owners: owners))
            XCTAssertEqual(elements.transclusions.count, 1)
            let image = render(elements)
            XCTAssertGreaterThan(try inkedPixels(in: frame.insetBy(dx: 10, dy: 10), of: image), 200,
                                 "the other page's ink is in the frame")
        }

        // The real thumbnail renderer, too (the live store has no such pages,
        // so these draw placeholders): it must come back, not recurse.
        for host in [a, b] {
            let resolved = PageElements.resolveTransclusions(hostedOn: host.id, links: links, owners: owners)
            var request = PageThumbnailView(page: host, transclusions: resolved).thumbnailRequest
            request.template = "lined"
            let image = await PageThumbnailRenderer.render(request)
            XCTAssertNotNil(image)
        }
    }

    // MARK: Markdown

    func testMarkdown_namesWhatAPageTranscludes() throws {
        let context = try makeContext()
        let source = notebook("Source", in: context)
        let (_, node, _) = try ownerWithNode(in: context, notebook: source, index: 1, title: "Chain rule")
        let hostBook = notebook("Host", in: context)
        let host = Page(index: 0, notebook: hostBook)
        context.insert(host)
        hostBook.pages = [host]
        Links.addTransclusion(of: node, onto: host, frame: CGRect(x: 0, y: 0, width: 100, height: 50), in: context)

        let links = try context.fetch(FetchDescriptor<Link>())
        let markdown = LibraryExport.markdown(for: hostBook, links: links)
        XCTAssertTrue(markdown.contains("Transcluded: Chain rule (Source \u{00B7} p. 2)"), markdown)
        // The source notebook says "Nodes:", not "Transcluded:".
        XCTAssertFalse(LibraryExport.markdown(for: source, links: links).contains("Transcluded:"))
    }
}
