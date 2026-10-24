import XCTest
import SwiftUI
import SwiftData
import PencilKit
import PDFKit
import UIKit
import UIKit.UIGestureRecognizerSubclass
@testable import Mystnotes

/// Simulator probes for items PLAN.md owes on the iPad (Oct 24, 2026): the
/// user had no iPad session, so these check what the simulator can show.
///
/// What the simulator can't do: there is no Apple Pencil, no finger (it
/// runs headless, so no mouse either) and public API cannot make a
/// `UITouch`. So nothing here is a real gesture. A probe calls what the
/// gesture or the button calls, as near to the real path as it can reach,
/// and each test says which part it could not reach.
///
/// The page strip's menu (Rotate Page, Delete Page) is a SwiftUI
/// `.contextMenu`. A test can't tap it, so `firePageStripMenuItem` asks the
/// window's `UIContextMenuInteraction` for the menu UIKit would show and
/// sends the item's `UIAction`. That goes through UIKit's private
/// `actionProvider`. When it can't be reached, the test is skipped, not
/// failed: that is a limit of the probe, not a bug in the app.
///
/// Pictures go to `/tmp/mystnotes-probes/` folder, or to the
/// app's temporary folder if the simulator can't write there. The test log
/// prints each path (`[probe]`).
@MainActor
final class SimProbePagesTests: XCTestCase {

    private static let schema = Schema([
        Folder.self, Notebook.self, Page.self, TypedTextBlock.self,
        ImportedDocument.self, Link.self, Sticker.self
    ])

    /// One container for the class: the notebook screen's `@Query`
    /// observers outlive a test (see `PageReloadTests`).
    private static var container: ModelContainer?
    private static func sharedContainer() throws -> ModelContainer {
        if let container { return container }
        let made = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        container = made
        return made
    }

    // MARK: - 1. Rotate Page, and Delete Page undo

    /// PLAN.md, owed on the iPad: "Rotate Page, and Delete Page undo"
    /// (the rotate half).
    ///
    /// `PageRotationTests` checks the geometry. This checks the flow the
    /// menu runs, `NotebookDetailView.rotatePage`, in the real notebook
    /// screen. The page has a PDF as its paper, ink, a text box and a
    /// sticker. After Rotate Page: the page takes the turned shape, the
    /// paper turns 90 degrees, and the ink, the box and the sticker all
    /// move with the same quarter turn. The ink keeps its stroke ids and is
    /// saved (read back from disk). The box and sticker are saved to the
    /// index (read back through a fresh context). The canvas is the same
    /// one, so its undo stack survives, and it refits to the new shape.
    /// Then one undo, the toolbar's `canvasView.undoManager?.undo()`, puts
    /// all of it back, on screen and on disk.
    ///
    /// Can't show: the long-press that opens the menu, and the menu's look.
    /// The item is sent through UIKit's private menu builder, and the test
    /// is skipped if that can't be reached.
    func testRotatePage_fromTheMenu_turnsInkTextAndStickerTogether_savesIt_andUndoTurnsItBack() async throws {
        let container = try Self.sharedContainer()
        let context = container.mainContext
        let notebook = Notebook(title: "Rotate probe")
        context.insert(notebook)
        let page = Page(index: 0, notebook: notebook)
        let other = Page(index: 1, notebook: notebook)
        context.insert(page); context.insert(other)
        notebook.pages = [page, other]
        page.aspectRatio = 0.75

        let pdfRef = try writePDF(size: CGSize(width: 780, height: 1040), black: CGRect(x: 100, y: 100, width: 200, height: 150))
        let pdfURL = FileStore.url(for: pdfRef)
        let paper = ImportedDocument(sourceType: "pdf", fileRef: pdfRef, pdfPageIndex: 0, page: page)
        (paper.frameX, paper.frameY, paper.frameWidth, paper.frameHeight) = (0, 0, 1, 1)
        context.insert(paper)
        page.backgroundRef = pdfRef

        let block = TypedTextBlock(content: "turn me", page: page)
        (block.frameX, block.frameY, block.frameWidth, block.frameHeight) = (380, 420, 240, 80)
        context.insert(block)
        page.textBlocks = [block]
        let sticker = Sticker(assetRef: "square.fill", page: page)
        (sticker.frameX, sticker.frameY, sticker.frameWidth, sticker.frameHeight) = (120, 420, 100, 100)
        context.insert(sticker)
        page.stickers = [sticker]

        let original = PKDrawing(strokes: [
            line(from: CGPoint(x: 420, y: 150), to: CGPoint(x: 640, y: 150), color: .red, index: 0),
            line(from: CGPoint(x: 150, y: 700), to: CGPoint(x: 500, y: 900), color: .black, index: 1)
        ])
        page.drawingFileRef = try DrawingStore.live.save(original, pageID: page.id)
        try context.save()

        let stripWasVisible = AppSettings.pageStripVisible
        AppSettings.pageStripVisible = true
        let window = try host(notebook, in: container)
        defer {
            close(window)
            AppSettings.pageStripVisible = stripWasVisible
            DrawingStore.live.trashDrawing(forPageID: page.id)
            try? FileManager.default.removeItem(at: pdfURL)
        }
        try await Task.sleep(for: .seconds(2))

        let canvas = try XCTUnwrap(canvases(in: window).first, "no canvas on screen")
        XCTAssertEqual(strokeIDs(canvas.drawing), strokeIDs(original), "precondition: the page's ink is on the canvas")

        let turn = PageRotation.quarterTurn(aspect: 0.75, clockwise: true).transform
        let blockBefore = CGRect(x: block.frameX, y: block.frameY, width: block.frameWidth, height: block.frameHeight)
        let stickerBefore = CGRect(x: sticker.frameX, y: sticker.frameY, width: sticker.frameWidth, height: sticker.frameHeight)
        let blockAfter = PageRotation.moved(blockBefore, by: turn)
        let stickerAfter = PageRotation.moved(stickerBefore, by: turn)
        let inkBefore = strokePoints(original)
        let inkAfter = inkBefore.map { $0.applying(turn) }
        let modifiedBefore = page.modifiedAt
        savePNG(snapshot(window), "rotate-1-before")

        switch firePageStripMenuItem("Rotate Page", in: window) {
        case .unreachable(let why): throw XCTSkip("Couldn't reach the page strip's menu headlessly: \(why)")
        case .disabled: return XCTFail("Rotate Page is in the menu but disabled on a page whose paper is a PDF")
        case .fired: break
        }
        try await Task.sleep(for: .seconds(1.5))

        if abs((page.aspectRatio ?? 0) - 0.75) < 1e-9, sticker.frameX == Double(stickerBefore.minX) {
            if let message = alertMessage(in: window) {
                return XCTFail("Rotate Page turned nothing and said: \"\(message)\"")
            }
            throw XCTSkip("The menu item was sent but nothing changed and no message showed. The SwiftUI button may not have run outside a presented menu, so this proves nothing either way.")
        }
        savePNG(snapshot(window), "rotate-2-after")

        XCTAssertEqual(page.aspectRatio ?? 0, 1 / 0.75, accuracy: 1e-9, "the page didn't take the turned shape")
        XCTAssertEqual(paper.rotationDegrees ?? 0, 90, "the PDF paper didn't turn")
        assertOrigin(block.frameX, block.frameY, blockAfter, "the text box didn't turn with the page")
        assertOrigin(sticker.frameX, sticker.frameY, stickerAfter, "the sticker didn't turn with the page")
        XCTAssertGreaterThan(page.modifiedAt ?? .distantPast, modifiedBefore ?? .distantPast, "the turn didn't mark the page modified")

        let shown = try XCTUnwrap(canvases(in: window).first)
        XCTAssertTrue(shown === canvas, "Rotate Page replaced the canvas: its undo stack is gone, so undo can't turn it back")
        assertPoints(strokePoints(shown.drawing), inkAfter, "the ink on screen didn't turn with the page")
        XCTAssertEqual(shown.contentSize.width / shown.zoomScale, PageGeometry.contentSize(aspectRatio: 1 / 0.75).width,
                       accuracy: 1, "the canvas didn't refit to the turned page's shape")

        let stored = try XCTUnwrap(DrawingStore.live.load(pageID: page.id), "no ink on disk after the turn")
        assertPoints(strokePoints(stored), inkAfter, "the turned ink wasn't saved: the file still has the old ink")
        XCTAssertEqual(strokeIDs(stored), strokeIDs(original), "the turn changed stroke ids (invariant 6)")

        let fresh = ModelContext(container)
        let savedBlock = try XCTUnwrap(try fresh.fetch(FetchDescriptor<TypedTextBlock>()).first { $0.id == block.id })
        assertOrigin(savedBlock.frameX, savedBlock.frameY, blockAfter, "the turned text box wasn't saved to the index")
        let savedSticker = try XCTUnwrap(try fresh.fetch(FetchDescriptor<Sticker>()).first { $0.id == sticker.id })
        assertOrigin(savedSticker.frameX, savedSticker.frameY, stickerAfter, "the turned sticker wasn't saved to the index")

        // The toolbar's undo button.
        XCTAssertTrue(shown.undoManager?.canUndo == true, "nothing to undo after Rotate Page")
        shown.undoManager?.undo()
        try await Task.sleep(for: .seconds(1.5))
        savePNG(snapshot(window), "rotate-3-undone")

        XCTAssertEqual(page.aspectRatio ?? 0, 0.75, accuracy: 1e-9, "undo didn't turn the page's shape back")
        XCTAssertEqual((paper.rotationDegrees ?? 0).truncatingRemainder(dividingBy: 360), 0, "undo didn't turn the paper back")
        assertOrigin(block.frameX, block.frameY, blockBefore, "undo didn't put the text box back")
        assertOrigin(sticker.frameX, sticker.frameY, stickerBefore, "undo didn't put the sticker back")
        let back = try XCTUnwrap(canvases(in: window).first)
        assertPoints(strokePoints(back.drawing), inkBefore, "undo didn't turn the ink on screen back")
        let storedBack = try XCTUnwrap(DrawingStore.live.load(pageID: page.id))
        assertPoints(strokePoints(storedBack), inkBefore, "undo turned the ink back on screen but not on disk")
        XCTAssertEqual(strokeIDs(storedBack), strokeIDs(original))
    }

    /// PLAN.md, owed on the iPad: "Rotate Page, and Delete Page undo"
    /// (the delete half).
    ///
    /// `PageDeletionTests` checks the real deletion. This checks the flow
    /// the menu runs, `requestDeletePage`, then undo. The open page is
    /// deleted from the menu. While the delete is pending you land on the
    /// next page, but the page, its ink file and its links are all still
    /// there. Then the toolbar's undo, on the canvas now shown, brings back
    /// the page: its ink on screen and on disk (never moved to `trash/`),
    /// the order 0, 1, 2, and the links in and out. After that, turning
    /// the page (the swipe, sent to its recognizer) must not delete it.
    /// That last step catches a delete still pending after the undo.
    ///
    /// Can't show: the long-press and the menu, as for rotate; the
    /// banner's own Undo button (a SwiftUI button: only the toolbar's undo
    /// path is sent here); and how the strip animates.
    func testDeletePage_fromTheMenu_thenUndo_bringsBackThePageItsInkOrderAndLinks() async throws {
        let container = try Self.sharedContainer()
        let context = container.mainContext
        let notebook = Notebook(title: "Delete probe")
        context.insert(notebook)
        let pages = (0..<3).map { Page(index: $0, notebook: notebook) }
        pages.forEach(context.insert)
        notebook.pages = pages
        let (doomed, next) = (pages[0], pages[1])

        let doomedInk = PKDrawing(strokes: [line(from: CGPoint(x: 100, y: 200), to: CGPoint(x: 600, y: 200), color: .red, index: 10)])
        let nextInk = PKDrawing(strokes: [line(from: CGPoint(x: 100, y: 500), to: CGPoint(x: 600, y: 800), color: .blue, index: 11)])
        doomed.drawingFileRef = try DrawingStore.live.save(doomedInk, pageID: doomed.id)
        next.drawingFileRef = try DrawingStore.live.save(nextInk, pageID: next.id)
        let incoming = Link(sourcePageID: next.id, destinationPageID: doomed.id)
        let outgoing = Link(sourcePageID: doomed.id, destinationPageID: pages[2].id)
        context.insert(incoming); context.insert(outgoing)
        try context.save()
        let inkFile = DrawingStore.live.fileURL(for: doomed.id)

        let stripWasVisible = AppSettings.pageStripVisible
        AppSettings.pageStripVisible = true
        let window = try host(notebook, in: container)
        defer {
            close(window)
            AppSettings.pageStripVisible = stripWasVisible
            pages.forEach { DrawingStore.live.trashDrawing(forPageID: $0.id) }
        }
        try await Task.sleep(for: .seconds(2))
        let first = try XCTUnwrap(canvases(in: window).first)
        XCTAssertEqual(strokeIDs(first.drawing), strokeIDs(doomedInk), "precondition: the notebook opens on its first page")

        switch firePageStripMenuItem("Delete Page", in: window) {
        case .unreachable(let why): throw XCTSkip("Couldn't reach the page strip's menu headlessly: \(why)")
        case .disabled: return XCTFail("Delete Page is disabled in a notebook of three pages")
        case .fired: break
        }
        try await Task.sleep(for: .seconds(1.5))

        let landed = try XCTUnwrap(canvases(in: window).first)
        if landed === first, strokeIDs(landed.drawing) == strokeIDs(doomedInk) {
            throw XCTSkip("The menu item was sent but the open page didn't change. The SwiftUI button may not have run outside a presented menu, so this proves nothing either way.")
        }
        savePNG(snapshot(window), "delete-1-pending")
        XCTAssertEqual(strokeIDs(landed.drawing), strokeIDs(nextInk), "deleting the open page didn't land on the next page")
        XCTAssertTrue((notebook.pages ?? []).contains { $0.id == doomed.id } && !doomed.isDeleted,
                      "the page was deleted for real while its delete could still be undone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: inkFile.path), "the ink went to trash/ while the delete could still be undone")
        XCTAssertEqual(try links(in: context).filter { [incoming.id, outgoing.id].contains($0.id) }.count, 2,
                       "links were removed while the delete could still be undone")

        // The toolbar's undo button acts on the canvas on screen.
        XCTAssertTrue(landed.undoManager?.canUndo == true, "the canvas shown after Delete Page has nothing to undo")
        landed.undoManager?.undo()
        try await Task.sleep(for: .seconds(1.5))
        savePNG(snapshot(window), "delete-2-undone")

        let restored = try XCTUnwrap(canvases(in: window).first)
        XCTAssertEqual(strokeIDs(restored.drawing), strokeIDs(doomedInk), "undo didn't bring the deleted page back on screen")
        let order = (notebook.pages ?? []).sorted { $0.index < $1.index }
        XCTAssertEqual(order.map(\.id), pages.map(\.id), "undo didn't put the pages back in their order")
        XCTAssertEqual(order.map(\.index), [0, 1, 2])
        XCTAssertTrue(FileManager.default.fileExists(atPath: inkFile.path), "the page came back without its ink file")
        XCTAssertEqual(strokeIDs(DrawingStore.live.load(pageID: doomed.id) ?? PKDrawing()), strokeIDs(doomedInk),
                       "the page's ink on disk isn't the ink it had")
        let trash = inkFile.deletingLastPathComponent().appendingPathComponent("trash")
        let trashed = (try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []
        XCTAssertFalse(trashed.contains { $0.hasPrefix(doomed.id.uuidString) }, "a copy of the page's ink went to trash/")
        XCTAssertEqual(try links(in: context).filter { [incoming.id, outgoing.id].contains($0.id) }.count, 2,
                       "undo didn't keep the links in and out")

        // Turning the page commits any delete still pending. After an undo
        // there must be none.
        try await Task.sleep(for: .seconds(4.5))
        let canvasHost = try XCTUnwrap(window.probeFirst(PagedCanvasHostView.self))
        let swipe = try XCTUnwrap(canvasHost.gestureRecognizers?.compactMap { $0 as? UISwipeGestureRecognizer }
            .first { $0.direction == .left }, "no page swipe on the canvas host")
        swipe.state = .ended
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(strokeIDs(canvases(in: window).first?.drawing ?? PKDrawing()), strokeIDs(nextInk), "precondition: the swipe turned the page")
        XCTAssertTrue((notebook.pages ?? []).contains { $0.id == doomed.id } && !doomed.isDeleted,
                      "the page was deleted on the next page turn, after its delete had been undone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: inkFile.path), "the ink went to trash/ on the next page turn after the undo")
    }

    // MARK: - 2. Imported PDF pages zoomed to 5x stay sharp

    /// PLAN.md, owed on the iPad: "Imported PDF pages zoomed to 5x stay
    /// sharp". Also the Oct 22 note "Imported PDFs stay sharp at full zoom
    /// on a 13" iPad" (`fb583c0`).
    ///
    /// `PDFVectorTests` checks the tiles draw at the zoomed detail at 4x
    /// and off the main thread. It doesn't reach full zoom on a 13" iPad:
    /// 5x the fit, which the commit puts at about 1.7, so 8.5x the page. On
    /// a 2x screen that is 17 pixels per page point, past the 16x the tiles
    /// used to stop at. This hosts the real `PDFLayerView` under the same
    /// `.scaleEffect` the page uses, at 1x and at 8.5x, and measures one
    /// black-on-white edge in screen pixels. The 2.5x bitmap shown at
    /// 8.5x is measured too, to prove the measure can tell sharp from soft.
    ///
    /// Can't show: the iPad's own screen and GPU (the simulator's screen is
    /// also 2x, so the pixel numbers are the same), how fast tiles fill in
    /// during a real pinch, and a 13" window: 8.5x is reached by the scale,
    /// not by a 13" fit.
    func testImportedPDF_atFullZoomOnA13InchIPad_staysSharp() async throws {
        let ref = try writePDF(size: CGSize(width: 400, height: 600), black: CGRect(x: 160, y: 120, width: 240, height: 120),
                               text: "Entropy is disorder")
        let url = FileStore.url(for: ref)
        defer { try? FileManager.default.removeItem(at: url) }
        let artwork = ArtworkLayer(id: UUID(), fileRef: ref, sourceType: "pdf", pdfPageIndex: 0,
                                   frameX: 0, frameY: 0, frameWidth: 1, frameHeight: 1,
                                   cropX: nil, cropY: nil, cropWidth: nil, cropHeight: nil, rotationDegrees: nil)
        // The page layer is 100 x 150 points here; the edge is at x = 40,
        // and the row measured is y = 45.
        let fullZoom: CGFloat = 1.7 * PageGeometry.maximumZoomFactor

        ProbeTileLayer.reset()
        let atOne = try await edgeWidth(of: vectorLayer(artwork), zoom: 1, name: "pdf-1x-vector")
        let oneScales = ProbeTileLayer.draws()
        ProbeTileLayer.reset()
        let atFull = try await edgeWidth(of: vectorLayer(artwork), zoom: fullZoom, name: "pdf-8.5x-vector")
        let tileScale = ProbeTileLayer.draws().max() ?? 0
        // What the page shows under the tiles: the bitmap at 2.5 pixels per
        // page point (`ImportedPageBackgroundView.oversampling`).
        let raster = try XCTUnwrap(artwork.image(targetSize: CGSize(width: 250, height: 375)))
        let bitmapOnly = try await edgeWidth(of: AnyView(Image(uiImage: raster).resizable()), zoom: fullZoom, name: "pdf-8.5x-bitmap")

        let screenScale = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.scale }.first ?? 2
        let report = "edge width in screen pixels: vector 1x \(atOne.map { "\($0)" } ?? "none"), vector \(fullZoom)x \(atFull.map { "\($0)" } ?? "none"), bitmap \(fullZoom)x \(bitmapOnly.map { "\($0)" } ?? "none"); 1x tile scales \(oneScales); largest tile scale \(tileScale), needed \(fullZoom * screenScale)"
        print("[probe] \(report)")
        let attachment = XCTAttachment(string: report)
        attachment.lifetime = .keepAlways
        add(attachment)

        let one = try XCTUnwrap(atOne, "the PDF's vector tiles drew nothing at 1x")
        let full = try XCTUnwrap(atFull, "the PDF's vector tiles drew nothing at \(fullZoom)x")
        // Only the bitmap decides whether the measure works: if the vectors
        // are as soft as the bitmap, that is the bug, not a reason to skip.
        guard let soft = bitmapOnly, soft >= 4 else {
            throw XCTSkip("The measure can't tell the bitmap from the vectors (\(report)), so it proves nothing about sharpness.")
        }
        XCTAssertLessThanOrEqual(full, max(3, one + 2), "the PDF is soft at full zoom: \(report)")
        XCTAssertGreaterThanOrEqual(tileScale, fullZoom * screenScale * 0.9,
                                    "the tiles drew below the detail full zoom needs: \(report)")
    }

    // MARK: - 3. Convert to Text on real handwriting

    /// PLAN.md, owed on the iPad: "Convert to Text on real handwriting".
    ///
    /// `LassoActionsTests` reads block capitals drawn as straight lines.
    /// This is nearer to a hand: lowercase joined cursive, slanted, with a
    /// wobbling baseline, letters of uneven size, jitter, and pressure and
    /// tilt that change along the stroke. Two lines, "lunch time" and
    /// "until then", read by the same call Convert to Text makes
    /// (`HandwritingRecognizer.text(in:separator: "\n")`). It fails only if
    /// nothing at all is read. What was read goes to the log and to an
    /// attachment, with how many of the four words came back. The image
    /// Vision is given is saved as a PNG.
    ///
    /// Can't show: real handwriting. These strokes are made by a program,
    /// and a person's are messier in ways a program doesn't copy. A wrong
    /// reading here is Vision's limit, not proof of an app bug, so it is
    /// reported and doesn't fail the test.
    func testConvertToText_readsSlantedJoinedCursive() async throws {
        let drawing = PKDrawing(strokes: cursiveLines(["lunch time", "until then"], at: CGPoint(x: 40, y: 100)))
        savePNG(visionImage(of: drawing), "cursive-what-vision-sees")

        let read = await HandwritingRecognizer.text(in: drawing, separator: "\n")
        let words = (read ?? "").lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        let expected = ["lunch", "time", "until", "then"]
        let hits = expected.filter { words.contains($0) }
        let report = "Convert to Text read \(read.map { "\"\($0)\"" } ?? "nothing") from \"lunch time / until then\": \(hits.count)/4 words, \(read?.split(separator: "\n").count ?? 0) line(s)"
        print("[probe] \(report)")
        let attachment = XCTAttachment(string: report)
        attachment.lifetime = .keepAlways
        add(attachment)

        let text = read?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertFalse(text.isEmpty, "Convert to Text read nothing at all in two lines of cursive; it would say \"Couldn't read any handwriting\"")
    }

    /// PLAN.md, owed on the iPad: "Convert to Text on real handwriting"
    /// (the flow around the reading).
    ///
    /// `convertSelectionToText` can't be called from a test: it is a method
    /// of the notebook screen, run by a SwiftUI button on the lasso
    /// toolbar, and that toolbar only shows with the lasso picked on the
    /// drawing toolbar, another SwiftUI button. So this runs its steps on
    /// the real controller and canvas instead. Lasso the cursive, read it
    /// as the button does, then `delete(exactly:)` the strokes that were
    /// read. The rect it returns, where the app puts the box, must be on
    /// the ink. Only the lassoed strokes go: a stroke outside the loop
    /// stays. One undo brings the ink back with the same stroke ids.
    ///
    /// Can't show: the text box itself, and that the box goes away in the
    /// same undo step (`setTextBlock` and the undo grouping are in the
    /// view). Also not the button, and not the Pencil drawing the loop.
    func testConvertToTextFlow_removesExactlyTheReadInk_andUndoBringsItBack() async throws {
        let cursive = cursiveLines(["lunch time", "until then"], at: CGPoint(x: 40, y: 100))
        let bystander = line(from: CGPoint(x: 40, y: 600), to: CGPoint(x: 300, y: 600), color: .black, index: 90)
        let canvas = PageCanvasView(frame: CGRect(x: 0, y: 0, width: 780, height: 1040))
        canvas.drawing = PKDrawing(strokes: cursive + [bystander])
        let controller = InkSelectionController()
        controller.canvas = canvas
        controller.isActive = true

        controller.select(lasso: InkSelection.corners(of: CGRect(x: 0, y: 0, width: 760, height: 400)))
        let selection = try XCTUnwrap(controller.selectedStrokes, "the lasso selected nothing")
        XCTAssertEqual(selection.strokes.count, cursive.count, "the lasso should take the cursive and nothing else")

        let read = await HandwritingRecognizer.text(in: PKDrawing(strokes: selection.strokes), separator: "\n")
        print("[probe] Convert to Text flow read: \(read ?? "nothing")")

        let removed = try XCTUnwrap(controller.delete(exactly: selection.strokes), "the read strokes couldn't be removed")
        XCTAssertEqual(removed.minX, selection.bounds.minX, accuracy: 0.5, "the box wouldn't go where the ink was")
        XCTAssertEqual(removed.minY, selection.bounds.minY, accuracy: 0.5, "the box wouldn't go where the ink was")
        for stroke in cursive {
            let center = CGPoint(x: stroke.renderBounds.midX, y: stroke.renderBounds.midY)
            XCTAssertTrue(removed.insetBy(dx: -1, dy: -1).contains(center), "a converted word lies outside where its box would go")
        }
        XCTAssertEqual(strokeIDs(canvas.drawing), strokeIDs(PKDrawing(strokes: [bystander])), "Convert to Text removed ink it didn't read")

        XCTAssertTrue(canvas.undoManager?.canUndo == true)
        canvas.undoManager?.undo()
        XCTAssertEqual(strokeIDs(canvas.drawing), strokeIDs(PKDrawing(strokes: cursive + [bystander])),
                       "undo didn't bring the converted ink back as the same strokes")
    }

    // MARK: - 4. Zoom fixes, Oct 22

    /// PLAN.md, Oct 22, [not tested]: "Zoom fixes: text boxes, stickers,
    /// PDF and lasso layers no longer stay off the ink after a layout pass
    /// during a pinch (the queued viewport update read old values)."
    ///
    /// In the real notebook screen, a page with a PDF (a black block), red
    /// ink, a yellow sticker and a blue text box. A pinch is played as
    /// steps of `setZoomScale` and `setContentOffset`, the calls a pinch
    /// makes on the scroll view. A forced layout pass between steps queues
    /// a deferred publish. The last step comes after the last layout pass,
    /// so before the fix the queued publish landed later with the old zoom.
    /// Then the published viewport must equal the canvas. In a picture of
    /// the window, each layer must be drawn where the canvas puts that page
    /// rect (the ink's own mapping), and not around it.
    ///
    /// Can't show: a two-finger pinch (no touches), and the lasso layer.
    /// That layer only shows with the lasso picked on the toolbar, a SwiftUI
    /// button this test can't press; it rides the same `PageViewportLayer`
    /// and viewport as the layers checked here (the whiteboard's is in
    /// `WhiteboardLassoTests`).
    func testZoom_aLayoutPassMidPinch_leavesPDFStickerTextAndInkTogether() async throws {
        let container = try Self.sharedContainer()
        let context = container.mainContext
        let notebook = Notebook(title: "Zoom probe")
        context.insert(notebook)
        let page = Page(index: 0, notebook: notebook)
        context.insert(page)
        notebook.pages = [page]
        page.aspectRatio = 0.75

        let pdfBlock = CGRect(x: 100, y: 100, width: 200, height: 150)
        let pdfRef = try writePDF(size: CGSize(width: 780, height: 1040), black: pdfBlock)
        let pdfURL = FileStore.url(for: pdfRef)
        let paper = ImportedDocument(sourceType: "pdf", fileRef: pdfRef, pdfPageIndex: 0, page: page)
        (paper.frameX, paper.frameY, paper.frameWidth, paper.frameHeight) = (0, 0, 1, 1)
        context.insert(paper)
        page.backgroundRef = pdfRef

        let sticker = Sticker(assetRef: "square.fill", page: page)
        (sticker.frameX, sticker.frameY, sticker.frameWidth, sticker.frameHeight) = (120, 420, 100, 100)
        context.insert(sticker)
        page.stickers = [sticker]
        let block = TypedTextBlock(content: "MMMM", page: page)
        (block.frameX, block.frameY, block.frameWidth, block.frameHeight) = (380, 420, 240, 80)
        block.fontSize = 40
        block.textColorHex = "#0000FF"
        context.insert(block)
        page.textBlocks = [block]
        let ink = PKDrawing(strokes: [line(from: CGPoint(x: 420, y: 150), to: CGPoint(x: 640, y: 150), color: .red, width: 10, index: 20)])
        page.drawingFileRef = try DrawingStore.live.save(ink, pageID: page.id)
        try context.save()

        let window = try host(notebook, in: container)
        defer {
            close(window)
            DrawingStore.live.trashDrawing(forPageID: page.id)
            try? FileManager.default.removeItem(at: pdfURL)
        }
        try await Task.sleep(for: .seconds(2))
        let canvasHost = try XCTUnwrap(window.probeFirst(PagedCanvasHostView.self), "no canvas host on screen")
        let canvas = try XCTUnwrap(canvasHost.canvas)
        let viewport = try XCTUnwrap(canvasHost.viewport)

        let fit = canvas.minimumZoomScale
        let focus = CGPoint(x: 370, y: 310)
        func pinchStep(_ factor: CGFloat) {
            let zoom = fit * factor
            canvas.setZoomScale(zoom, animated: false)
            canvas.setContentOffset(CGPoint(x: focus.x * zoom - canvas.bounds.width / 2,
                                            y: focus.y * zoom - canvas.bounds.height / 2), animated: false)
        }
        for factor: CGFloat in [1.25, 1.5, 1.8, 2.0] {
            pinchStep(factor)
            canvasHost.setNeedsLayout()
            canvasHost.layoutIfNeeded()      // queues a deferred publish
        }
        pinchStep(1.6)                       // the pinch goes on before it lands
        try await Task.sleep(for: .milliseconds(600))

        XCTAssertEqual(viewport.zoomScale, canvas.zoomScale, accuracy: 0.0001,
                       "the layers' zoom is stale after a layout pass mid-pinch: \(viewport.zoomScale) vs the canvas's \(canvas.zoomScale)")
        XCTAssertEqual(viewport.contentOffset.x, canvas.contentOffset.x, accuracy: 0.5, "the layers' pan is stale after a layout pass mid-pinch")
        XCTAssertEqual(viewport.contentOffset.y, canvas.contentOffset.y, accuracy: 0.5, "the layers' pan is stale after a layout pass mid-pinch")

        let shot = snapshot(window)
        savePNG(shot, "zoom-after-layout-mid-pinch")
        let pixels = try Pixels(shot)
        // Where the canvas draws a page rect: the ink's own mapping.
        func onScreen(_ rect: CGRect) -> CGRect {
            let zoom = canvas.zoomScale
            return canvas.convert(CGRect(x: rect.minX * zoom, y: rect.minY * zoom,
                                         width: rect.width * zoom, height: rect.height * zoom), to: window)
        }
        func assertDrawn(_ name: String, at rect: CGRect, minimumFill: Double, _ match: (Int, Int, Int) -> Bool) {
            let expected = onScreen(rect)
            let inside = pixels.count(in: expected, match)
            let ring = pixels.count(in: expected.insetBy(dx: -24, dy: -24), match) - pixels.count(in: expected.insetBy(dx: -4, dy: -4), match)
            let area = Double(expected.width * expected.height * pixels.scale * pixels.scale)
            XCTAssertGreaterThan(Double(inside), area * minimumFill,
                                 "the \(name) isn't drawn where the canvas puts it (\(inside) matching pixels in \(expected))")
            XCTAssertLessThanOrEqual(ring, max(25, inside / 20),
                                     "the \(name) is drawn off its place: \(ring) matching pixels just outside \(expected)")
        }
        assertDrawn("red ink", at: ink.strokes[0].renderBounds, minimumFill: 0.25) { r, g, b in r > 180 && g < 90 && b < 90 }
        assertDrawn("PDF's black block", at: pdfBlock, minimumFill: 0.6) { r, g, b in r < 60 && g < 60 && b < 60 }
        assertDrawn("yellow sticker", at: CGRect(x: 120, y: 420, width: 100, height: 100), minimumFill: 0.4) { r, g, b in
            r > 200 && g > 150 && b < 90
        }
        assertDrawn("blue text", at: CGRect(x: 380, y: 420, width: 240, height: 80), minimumFill: 0.03) { r, g, b in
            b > 180 && r < 90 && g < 120
        }
    }

    // MARK: - Hosting

    private func host(_ notebook: Notebook, in container: ModelContainer) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        window.rootViewController = UIHostingController(rootView:
            NavigationStack { NotebookDetailView(notebook: notebook) }.modelContainer(container))
        window.makeKeyAndVisible()
        return window
    }

    /// Takes the notebook screen down with the test (see `PageReloadTests`).
    private func close(_ window: UIWindow) {
        window.rootViewController = nil
        window.isHidden = true
    }

    private func canvases(in view: UIView) -> [PKCanvasView] {
        (view as? PKCanvasView).map { [$0] } ?? view.subviews.flatMap(canvases(in:))
    }

    private func links(in context: ModelContext) throws -> [Mystnotes.Link] {
        try context.fetch(FetchDescriptor<Mystnotes.Link>())
    }

    private func alertMessage(in window: UIWindow) -> String? {
        var shown = window.rootViewController?.presentedViewController
        while let current = shown {
            if let alert = current as? UIAlertController { return alert.message ?? alert.title }
            shown = current.presentedViewController
        }
        return nil
    }

    // MARK: - The page strip's menu, without a touch

    private enum MenuReach { case fired, disabled, unreachable(String) }
    private typealias ActionProvider = @convention(block) ([UIMenuElement]) -> UIMenu?

    /// Sends the menu item `title` of the first page's cell in the page
    /// strip. The strip is under the canvas and starts at its first page,
    /// so the first cell is the first point, scanning from the left, whose
    /// menu has that item. Point by point, each context-menu interaction in
    /// the window is asked for the configuration UIKit would show there. Its
    /// menu is built through the private `actionProvider` (checked before it
    /// is read, so a missing key is "unreachable", not a crash), and the
    /// item's `UIAction` is sent with `UIControl.sendAction`.
    private func firePageStripMenuItem(_ title: String, in window: UIWindow) -> MenuReach {
        guard let canvasHost = window.probeFirst(PagedCanvasHostView.self) else { return .unreachable("no canvas host") }
        let interactions = contextMenuInteractions(in: window)
        guard !interactions.isEmpty else { return .unreachable("no UIContextMenuInteraction in the window") }
        let top = canvasHost.convert(canvasHost.bounds, to: window).maxY
        var asked = 0
        for y in stride(from: window.bounds.maxY - 12, through: top + 4, by: -8) {
            for x: CGFloat in [28, 40, 52, 64] {
                for interaction in interactions {
                    guard let menu = self.menu(of: interaction, at: CGPoint(x: x, y: y), in: window, asked: &asked),
                          let action = self.action(titled: title, in: menu) else { continue }
                    if action.attributes.contains(.disabled) { return .disabled }
                    UIButton().sendAction(action)
                    return .fired
                }
            }
        }
        return .unreachable("\(interactions.count) context-menu interaction(s), \(asked) menu(s) built under the canvas, none with \"\(title)\"")
    }

    private func contextMenuInteractions(in view: UIView) -> [UIContextMenuInteraction] {
        view.interactions.compactMap { $0 as? UIContextMenuInteraction } + view.subviews.flatMap(contextMenuInteractions(in:))
    }

    private func menu(of interaction: UIContextMenuInteraction, at point: CGPoint, in window: UIWindow, asked: inout Int) -> UIMenu? {
        guard let view = interaction.view, let delegate = interaction.delegate else { return nil }
        let local = window.convert(point, to: view)
        guard view.bounds.contains(local),
              let configuration = delegate.contextMenuInteraction(interaction, configurationForMenuAtLocation: local) else { return nil }
        let key = "actionProvider"
        guard configuration.responds(to: NSSelectorFromString(key)),
              let value = configuration.value(forKey: key) else { return nil }
        let raw = value as AnyObject
        guard String(describing: type(of: raw)).contains("Block") else { return nil }
        asked += 1
        return unsafeBitCast(raw, to: ActionProvider.self)([])
    }

    private func action(titled title: String, in element: UIMenuElement) -> UIAction? {
        if let action = element as? UIAction { return action.title == title ? action : nil }
        guard let menu = element as? UIMenu else { return nil }
        for child in menu.children {
            if let found = self.action(titled: title, in: child) { return found }
        }
        return nil
    }

    // MARK: - Ink

    /// A straight stroke with a fixed creation date and seed: its id
    /// (invariant 6), so a test can follow it through saves and undo.
    private func line(from a: CGPoint, to b: CGPoint, color: UIColor, width: CGFloat = 8, index: Int) -> PKStroke {
        let points = (0...20).map { step -> PKStrokePoint in
            let t = CGFloat(step) / 20
            return PKStrokePoint(location: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t),
                                 timeOffset: Double(step) * 0.01, size: CGSize(width: width, height: width),
                                 opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSinceReferenceDate: 710_000_000 + Double(index)))
        return PKStroke(ink: PKInk(.pen, color: color), path: path, randomSeed: UInt32(4200 + index))
    }

    /// Creation date and seed: what survives a transform, the eraser and a
    /// save (CLAUDE.md, invariant 6).
    private func strokeIDs(_ drawing: PKDrawing) -> [String] {
        drawing.strokes.map { "\($0.path.creationDate.timeIntervalSinceReferenceDate)/\($0.randomSeed)" }
    }

    private func strokePoints(_ drawing: PKDrawing) -> [CGPoint] {
        drawing.strokes.flatMap { stroke in stroke.path.map { $0.location.applying(stroke.transform) } }
    }

    private func assertPoints(_ actual: [CGPoint], _ expected: [CGPoint], _ message: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        guard actual.count == expected.count else {
            return XCTFail("\(message): \(actual.count) points, expected \(expected.count)", file: file, line: line)
        }
        let worst = zip(actual, expected).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 0
        XCTAssertLessThan(worst, 0.05, "\(message): off by up to \(worst) pt", file: file, line: line)
    }

    private func assertOrigin(_ x: Double, _ y: Double, _ expected: CGRect, _ message: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(x, Double(expected.minX), accuracy: 0.01, message, file: file, line: line)
        XCTAssertEqual(y, Double(expected.minY), accuracy: 0.01, message, file: file, line: line)
    }

    // MARK: - Cursive

    /// One letter of joined cursive in x-height units, y up from the
    /// baseline. Each starts and ends low on the right, so letters join.
    private struct Glyph {
        var advance: CGFloat
        var path: [CGPoint]
        var marks: [[CGPoint]] = []      // i dots and t crosses: strokes of their own
    }

    private static func points(_ pairs: [(CGFloat, CGFloat)]) -> [CGPoint] { pairs.map { CGPoint(x: $0.0, y: $0.1) } }

    private static let loopUp: [(CGFloat, CGFloat)] = [(0, 0.15), (0.28, 0.6), (0.48, 1.25), (0.55, 1.75), (0.47, 2.02),
                                                         (0.32, 1.95), (0.25, 1.6)]
    private static let glyphs: [Character: Glyph] = [
        "i": Glyph(advance: 0.6, path: points([(0, 0.15), (0.2, 0.55), (0.32, 1.0), (0.3, 0.55), (0.28, 0.15), (0.38, 0), (0.6, 0.15)]),
                   marks: [points([(0.36, 1.45), (0.4, 1.5), (0.44, 1.47)])]),
        "e": Glyph(advance: 0.75, path: points([(0, 0.15), (0.3, 0.38), (0.52, 0.62), (0.52, 0.88), (0.38, 0.97), (0.2, 0.82),
                                                (0.13, 0.5), (0.2, 0.18), (0.38, 0), (0.56, 0.03), (0.75, 0.18)])),
        "l": Glyph(advance: 0.65, path: points(loopUp + [(0.24, 1.0), (0.25, 0.4), (0.32, 0.05), (0.48, 0), (0.65, 0.15)])),
        "t": Glyph(advance: 0.6, path: points([(0, 0.15), (0.22, 0.55), (0.36, 1.05), (0.45, 1.55), (0.38, 1.05), (0.32, 0.5),
                                               (0.33, 0.1), (0.45, 0), (0.6, 0.15)]),
                   marks: [points([(0.12, 1.02), (0.4, 1.06), (0.7, 1.08)])]),
        "n": Glyph(advance: 0.95, path: points([(0, 0.15), (0.12, 0.6), (0.18, 0.95), (0.2, 0.5), (0.2, 0), (0.25, 0.45),
                                                (0.38, 0.82), (0.52, 0.95), (0.64, 0.82), (0.66, 0.4), (0.68, 0.1), (0.8, 0),
                                                (0.95, 0.15)])),
        "m": Glyph(advance: 1.3, path: points([(0, 0.15), (0.12, 0.6), (0.18, 0.95), (0.2, 0.5), (0.2, 0), (0.24, 0.45),
                                               (0.36, 0.85), (0.48, 0.95), (0.58, 0.8), (0.6, 0.4), (0.6, 0), (0.64, 0.45),
                                               (0.76, 0.85), (0.88, 0.95), (0.98, 0.8), (1.0, 0.4), (1.02, 0.1), (1.14, 0),
                                               (1.3, 0.15)])),
        "u": Glyph(advance: 0.95, path: points([(0, 0.15), (0.12, 0.6), (0.17, 0.95), (0.15, 0.5), (0.18, 0.12), (0.3, 0),
                                                (0.48, 0.15), (0.6, 0.55), (0.66, 0.95), (0.64, 0.5), (0.66, 0.12), (0.78, 0),
                                                (0.95, 0.15)])),
        "c": Glyph(advance: 0.75, path: points([(0, 0.15), (0.3, 0.55), (0.55, 0.85), (0.48, 0.97), (0.3, 0.9), (0.15, 0.6),
                                                (0.14, 0.25), (0.3, 0.02), (0.52, 0.02), (0.75, 0.18)])),
        "h": Glyph(advance: 1.0, path: points(loopUp + [(0.23, 1.0), (0.22, 0), (0.27, 0.45), (0.4, 0.82), (0.55, 0.95),
                                                        (0.67, 0.82), (0.69, 0.4), (0.71, 0.1), (0.83, 0), (1.0, 0.15)]))
    ]

    /// Lines of words, each word one joined stroke plus its dots and
    /// crosses. Slanted, uneven, jittered, with pressure and tilt that vary
    /// along the stroke, from a fixed seed so every run draws the same.
    private func cursiveLines(_ lines: [String], at origin: CGPoint) -> [PKStroke] {
        var random = SeededRandom(state: 0x5EED_CAFE)
        let xHeight: CGFloat = 26, slant: CGFloat = 0.28
        var strokes: [PKStroke] = []
        for (row, text) in lines.enumerated() {
            let baseline = origin.y + CGFloat(row) * xHeight * 3.4
            var penX: CGFloat = 0
            for word in text.split(separator: " ") {
                var path: [CGPoint] = []
                var marks: [[CGPoint]] = []
                for letter in word {
                    guard let glyph = Self.glyphs[letter] else { continue }
                    let sx = CGFloat.random(in: 0.9...1.1, using: &random), sy = CGFloat.random(in: 0.88...1.12, using: &random)
                    let place = { (p: CGPoint) in CGPoint(x: penX + p.x * sx, y: p.y * sy) }
                    let joined = path.isEmpty ? 0 : 1      // the join point is already there
                    path += glyph.path.dropFirst(joined).map(place)
                    marks += glyph.marks.map { $0.map(place) }
                    penX += glyph.advance * sx
                }
                let phase = CGFloat.random(in: 0...6, using: &random)
                let toPage = { (u: CGPoint) in
                    CGPoint(x: origin.x + (u.x + slant * u.y) * xHeight,
                            y: baseline - u.y * xHeight + 2.5 * sin(u.x * 1.3 + phase))
                }
                for points in [path] + marks {
                    let stroke = handStroke(smooth(points.map(toPage)), index: strokes.count, random: &random)
                    strokes.append(stroke)
                }
                penX += 1.0 + CGFloat.random(in: -0.15...0.2, using: &random)
            }
        }
        return strokes
    }

    private func handStroke(_ points: [CGPoint], index: Int, random: inout SeededRandom) -> PKStroke {
        let (p1, p2, p3) = (CGFloat.random(in: 0...6, using: &random), CGFloat.random(in: 0...6, using: &random),
                            CGFloat.random(in: 0...6, using: &random))
        let controlPoints = points.enumerated().map { i, p -> PKStrokePoint in
            let t = CGFloat(i)
            let jittered = CGPoint(x: p.x + 1.0 * sin(t * 0.21 + p1) + CGFloat.random(in: -0.35...0.35, using: &random),
                                   y: p.y + 1.0 * cos(t * 0.17 + p2) + CGFloat.random(in: -0.35...0.35, using: &random))
            let width = 2.9 + 0.7 * sin(t * 0.05 + p3)
            return PKStrokePoint(location: jittered, timeOffset: Double(i) * 0.006, size: CGSize(width: width, height: width),
                                 opacity: 1, force: 0.5 + 0.3 * sin(t * 0.07 + p1), azimuth: .pi / 4 + 0.2 * sin(t * 0.03),
                                 altitude: 1.0 + 0.15 * cos(t * 0.04 + p2))
        }
        let path = PKStrokePath(controlPoints: controlPoints, creationDate: Date(timeIntervalSinceReferenceDate: 720_000_000 + Double(index)))
        return PKStroke(ink: PKInk(.pen, color: .black), path: path, randomSeed: UInt32(7000 + index))
    }

    /// Catmull-Rom through the glyph's points, so the pen's spline follows
    /// curves rather than cutting corners.
    private func smooth(_ points: [CGPoint], samples: Int = 6) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var out: [CGPoint] = []
        for i in 0..<(points.count - 1) {
            let (a, b, c, d) = (points[max(i - 1, 0)], points[i], points[i + 1], points[min(i + 2, points.count - 1)])
            for s in 0..<samples {
                let t = CGFloat(s) / CGFloat(samples)
                func blend(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
                    0.5 * (2 * b + (c - a) * t + (2 * a - 5 * b + 4 * c - d) * t * t + (3 * b - a - 3 * c + d) * t * t * t)
                }
                out.append(CGPoint(x: blend(a.x, b.x, c.x, d.x), y: blend(a.y, b.y, c.y, d.y)))
            }
        }
        out.append(points[points.count - 1])
        return out
    }

    /// What `HandwritingRecognizer` hands Vision: the ink at 2x, light
    /// trait, on opaque white. Rendered on the main thread, never the
    /// cooperative pool (CLAUDE.md).
    private func visionImage(of drawing: PKDrawing) -> UIImage {
        let bounds = drawing.bounds.insetBy(dx: -20, dy: -20)
        var ink = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = drawing.image(from: bounds, scale: 2)
        }
        return UIGraphicsImageRenderer(size: ink.size).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: ink.size))
            ink.draw(at: .zero)
        }
    }

    // MARK: - PDF

    /// A PDF page with a black block on it, and optionally a line of text.
    private func writePDF(size: CGSize, black: CGRect, text: String? = nil) throws -> String {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { context in
            context.beginPage()
            UIColor.black.setFill()
            context.fill(black)
            if let text {
                NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 24)])
                    .draw(at: CGPoint(x: 20, y: size.height * 2 / 3))
            }
        }
        let ref = "\(UUID().uuidString).pdf"
        try data.write(to: FileStore.url(for: ref))
        return ref
    }

    private func vectorLayer(_ artwork: ArtworkLayer) -> AnyView {
        let view = ProbeLayerView()
        view.tiles.show(artwork)
        return AnyView(ProbeHostedView(view: view))
    }

    /// Hosts `content` as a 100 x 150 page layer under `.scaleEffect(zoom)`,
    /// as `PageViewportLayer` does, and measures the black block's left
    /// edge (page x = 40) along rows near page y = 45: how many screen
    /// pixels are neither paper nor ink. nil if no edge was drawn.
    private func edgeWidth(of content: AnyView, zoom: CGFloat, name: String) async throws -> Int? {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 800, height: 800)
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView:
            content.frame(width: 100, height: 150)
                .scaleEffect(zoom, anchor: .topLeading)
                .frame(width: 800, height: 800, alignment: .topLeading)
                .background(Color.white)
                // Otherwise the status bar's inset moves the page down and
                // the measured row misses the block at 1x.
                .ignoresSafeArea())
        window.makeKeyAndVisible()
        defer { close(window) }
        // Tiles draw in the background and fade in; let them settle.
        try await Task.sleep(for: .seconds(2.5))

        var measured: Int?
        for attempt in 0..<6 {
            let shot = snapshot(window, scale: window.screen.scale)
            let pixels = try Pixels(shot)
            let edgeX = Int(40 * zoom * pixels.scale)
            let reach = Int((6 + 2 * zoom) * pixels.scale)
            let widths = (-2...2).compactMap { offset -> Int? in
                pixels.transitionWidth(row: Int(45 * zoom * pixels.scale) + offset, from: edgeX - reach, to: edgeX + reach)
            }
            if widths.count == 5 || attempt == 5 { savePNG(shot, name) }
            if widths.count == 5 {
                measured = widths.max()
                break
            }
            try await Task.sleep(for: .seconds(0.5))
        }
        return measured
    }

    // MARK: - Pictures

    private static let probeDirectory: URL = {
        let scratch = URL(fileURLWithPath: "/tmp/mystnotes-probes",
                          isDirectory: true)
        if (try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)) != nil { return scratch }
        return FileManager.default.temporaryDirectory
    }()

    private func savePNG(_ image: UIImage, _ name: String) {
        guard let data = image.pngData() else { return print("[probe] \(name): no PNG data") }
        for directory in [Self.probeDirectory, FileManager.default.temporaryDirectory] {
            let url = directory.appendingPathComponent("\(name).png")
            if (try? data.write(to: url)) != nil { return print("[probe] \(name): \(url.path)") }
        }
        print("[probe] \(name): couldn't write the PNG")
    }

    private func snapshot(_ window: UIWindow, scale: CGFloat = 1) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }
}

/// RGBA pixels of a picture, read in points through its scale.
nonisolated private struct Pixels {
    let width: Int, height: Int, scale: CGFloat
    private let bytes: [UInt8]

    init(_ image: UIImage) throws {
        let cg = try XCTUnwrap(image.cgImage)
        width = cg.width
        height = cg.height
        scale = image.scale
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                              bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        self.bytes = bytes
    }

    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * width + x) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }

    /// Pixels inside `rect` (points) that match.
    func count(in rect: CGRect, _ match: (Int, Int, Int) -> Bool) -> Int {
        let x0 = max(0, Int(rect.minX * scale)), x1 = min(width, Int(rect.maxX * scale))
        let y0 = max(0, Int(rect.minY * scale)), y1 = min(height, Int(rect.maxY * scale))
        guard x0 < x1, y0 < y1 else { return 0 }
        var total = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let (r, g, b) = rgb(x, y)
                if match(r, g, b) { total += 1 }
            }
        }
        return total
    }

    /// Along one row, the pixels between paper and ink: the blur across
    /// one edge. nil unless the span has both paper and ink in it.
    func transitionWidth(row y: Int, from x0: Int, to x1: Int) -> Int? {
        guard y >= 0, y < height else { return nil }
        let lums = (max(0, x0)..<min(width, x1)).map { x -> Int in
            let (r, g, b) = rgb(x, y)
            return (r * 299 + g * 587 + b * 114) / 1000
        }
        guard lums.contains(where: { $0 < 50 }), lums.contains(where: { $0 > 205 }) else { return nil }
        return lums.filter { $0 >= 50 && $0 <= 205 }.count
    }
}

/// SplitMix64: the same strokes every run.
nonisolated private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private struct ProbeHostedView: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// The real `PDFLayerView`, with tiles that note the scale they draw at.
private final class ProbeLayerView: PDFLayerView {
    override class var layerClass: AnyClass { ProbeTileLayer.self }
}

nonisolated private final class ProbeTileLayer: PDFTileLayer, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var scales: [CGFloat] = []

    static func reset() { lock.lock(); scales = []; lock.unlock() }
    static func draws() -> [CGFloat] { lock.lock(); defer { lock.unlock() }; return scales }

    override func draw(in context: CGContext) {
        Self.lock.lock()
        Self.scales.append(context.userSpaceToDeviceSpaceTransform.a)
        Self.lock.unlock()
        super.draw(in: context)
    }
}

private extension UIView {
    func probeFirst<T: UIView>(_ type: T.Type) -> T? {
        if let match = self as? T { return match }
        for sub in subviews { if let found = sub.probeFirst(type) { return found } }
        return nil
    }
}
