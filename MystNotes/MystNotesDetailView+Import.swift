import SwiftUI
import SwiftData
#if targetEnvironment(macCatalyst) || canImport(UIKit)
import PencilKit
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import PDFKit
import PhotosUI

extension NotebookDetailView {
    /// Opens the move/resize handles on the picture under a long-press:
    /// the topmost one under the finger, or none - never the PDF that is
    /// the page (`ImportedArtwork.layerToAdjust`).
    #if targetEnvironment(macCatalyst) || canImport(UIKit)
    func beginAdjustingImage(on page: Page, at point: CGPoint) {
        guard let pressed = ImportedArtwork.layerToAdjust(at: point, in: artwork(for: page),
                                                          pageSize: PageGeometry.contentSize(for: page)) else { return }
        beginAdjustingImage(on: page, layerID: pressed)
    }

    /// Page strip menu: a quarter turn of the page and everything on it
    /// (`PageRotation`). Undo turns it back, and registers redo.
    ///
    /// The ink comes from the record, never the canvas: a canvas can be
    /// blank only because its ink hasn't arrived, and a turned blank saved
    /// now would out-date the real ink in the merge.
    func rotatePage(_ page: Page, clockwise: Bool = true) {
        jumpToPage(withID: page.id)
        saveCurrentPage(blocking: true)
        let stored = drawingStore.load(pageID: page.id)
        if stored == nil, page.drawingFileRef != nil {
            exportMessage = "This page's ink is still downloading. Try again in a moment."
            return
        }
        let turned = PageRotation.rotate(page, clockwise: clockwise, documents: allImportedDocuments,
                                         links: allLinks, drawing: stored ?? PKDrawing())
        if stored != nil {
            saveBlocking(turned, to: page)
        } else {
            page.markModified()
            saveMetadata("Failed to rotate page")
        }
        // The same canvas, not a fresh one: a fresh canvas brings a fresh
        // undo stack, and the redo that undoing this registers would land
        // on it as one more undo. The canvas refits to the page's new
        // shape by itself (`PagedCanvasHostView.apply`).
        canvasView.drawing = turned
        let canvas = canvasView
        canvas.undoManager?.registerUndo(withTarget: canvas) { _ in rotatePage(page, clockwise: !clockwise) }
        refreshUndoRedoState()
    }

    /// Page strip menu: the crop handles on the PDF that is the page, which
    /// a long-press no longer opens.
    func cropPage(_ page: Page) {
        guard let paper = artwork(for: page).first, paper.isPaper else { return }
        jumpToPage(withID: page.id)
        beginAdjustingImage(on: page, layerID: paper.id)
        toggleCropMode()
    }

    /// Opens the handles on one layer. Used right after importing onto an
    /// existing page too, so a photo can be placed straight away rather
    /// than always landing aspect-fit in the middle.
    func beginAdjustingImage(on page: Page, layerID: UUID) {
        guard adjustingImageFrame == nil,
              let layer = artwork(for: page).first(where: { $0.id == layerID }) else { return }
        // Never adjusted: start from the artwork's actual aspect-fit rect,
        // which is exactly where it's already being rendered - so nothing
        // jumps, and the handles hug the image rather than boxing the
        // whole page.
        adjustingImageFrame = layer.rect(in: PageGeometry.contentSize(for: page))
        adjustingLayerID = layerID
        adjustingSnapshot = documents(on: page).first { $0.id == layerID }.map(ArtworkSnapshot.init)
        updateCanvasInteractionEnabled()
    }

    /// The document the handles are on. A page from before
    /// `ImportedDocument` existed has only a `backgroundRef`; the first
    /// edit gives it a document so the placement has somewhere to live.
    func adjustingDocument(on page: Page) -> ImportedDocument? {
        let stack = documents(on: page)
        if let doc = stack.first(where: { $0.id == adjustingLayerID }) { return doc }
        guard adjustingLayerID == page.id, stack.isEmpty,
              let ref = page.backgroundRef, !ref.isEmpty else { return nil }
        let doc = ImportedDocument(
            sourceType: ref.lowercased().hasSuffix(".pdf") ? "pdf" : "image",
            fileRef: ref, pdfPageIndex: 0, page: page
        )
        modelContext.insert(doc)
        adjustingLayerID = doc.id
        return doc
    }

    /// Quarter-turn clockwise. The placement frame's aspect is flipped to
    /// match so the artwork doesn't end up stretched by the rotation.
    func rotateImage(on page: Page) {
        guard let doc = adjustingDocument(on: page) else { return }
        doc.rotationDegrees = ((doc.rotationDegrees ?? 0) + 90).truncatingRemainder(dividingBy: 360)

        // The crop is stored in rotated-display space (that's the space its
        // handles were drawn in), so it has to turn with the picture -
        // otherwise rotating a cropped image would suddenly show a
        // different part of it.
        if let x = doc.cropX, let y = doc.cropY, let w = doc.cropWidth, let h = doc.cropHeight {
            let rotated = ImportedArtwork.rotatingCropClockwise(x: x, y: y, width: w, height: h)
            doc.cropX = rotated.x
            doc.cropY = rotated.y
            doc.cropWidth = rotated.width
            doc.cropHeight = rotated.height
        }
        if let frame = adjustingImageFrame {
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let flipped = CGSize(width: frame.height, height: frame.width)
            adjustingImageFrame = CGRect(
                x: center.x - flipped.width / 2,
                y: center.y - flipped.height / 2,
                width: flipped.width,
                height: flipped.height
            )
        }
        page.markModified()
        saveMetadata("Failed to rotate image")
    }

    func toggleCropMode() {
        if croppingRect != nil {
            croppingRect = nil                 // cancel, leaving the crop untouched
        } else if let frame = adjustingImageFrame {
            croppingRect = frame               // start from the whole artwork
        }
    }

    /// Composes the new crop with whatever crop is already applied: the
    /// on-screen artwork is the *already cropped* image, so the rect the
    /// user drew is relative to that, not to the original file.
    func applyCrop(on page: Page) {
        defer { croppingRect = nil }
        guard let frame = adjustingImageFrame,
              let crop = croppingRect,
              frame.width > 0, frame.height > 0,
              let doc = adjustingDocument(on: page) else { return }

        let relativeX = (crop.minX - frame.minX) / frame.width
        let relativeY = (crop.minY - frame.minY) / frame.height
        let relativeWidth = crop.width / frame.width
        let relativeHeight = crop.height / frame.height

        let existingX = doc.cropX ?? 0
        let existingY = doc.cropY ?? 0
        let existingWidth = doc.cropWidth ?? 1
        let existingHeight = doc.cropHeight ?? 1

        doc.cropX = existingX + relativeX * existingWidth
        doc.cropY = existingY + relativeY * existingHeight
        doc.cropWidth = existingWidth * relativeWidth
        doc.cropHeight = existingHeight * relativeHeight

        // The visible artwork is now the crop, so shrink the placement frame
        // to it - otherwise the remaining image would stretch to refill the
        // old frame.
        adjustingImageFrame = crop
        page.markModified()
        saveMetadata("Failed to crop image")
    }

    /// Removes the artwork the handles are on - only that one; the rest
    /// of the stack stays. Undoable: its file waits in `pendingTrash`.
    func removeImage(from page: Page) {
        defer { endAdjusting() }
        guard let doc = adjustingDocument(on: page) else { return }
        changeArtwork(doc.id, on: page, from: adjustingSnapshot ?? ArtworkSnapshot(doc), to: nil)
    }

    /// Moves one piece of artwork from `old` to `new` (nil: not there) and
    /// registers the way back on the page's undo stack; undoing registers
    /// the way forward again, which is redo.
    func changeArtwork(_ id: UUID, on page: Page, from old: ArtworkSnapshot?, to new: ArtworkSnapshot?) {
        if let orphan = ArtworkEdits.apply(new, id: id, page: page, in: modelContext) { pendingTrash.insert(orphan) }
        if let ref = new?.fileRef { pendingTrash.remove(ref) }
        page.markModified()
        saveMetadata("Failed to change artwork")
        let canvas = canvasView
        canvas.undoManager?.registerUndo(withTarget: canvas) { _ in
            changeArtwork(id, on: page, from: new, to: old)
        }
        refreshUndoRedoState()
    }

    func commitPendingTrash() {
        for ref in pendingTrash where !allImportedDocuments.contains(where: { $0.fileRef == ref }) {
            drawingStore.trashPayload(named: ref)
        }
        pendingTrash = []
    }

    func endAdjusting() {
        adjustingImageFrame = nil
        adjustingLayerID = nil
        adjustingSnapshot = nil
        croppingRect = nil
        updateCanvasInteractionEnabled()
    }

    func finishAdjustingImage(on page: Page) {
        defer { endAdjusting() }
        guard let frame = adjustingImageFrame,
              let doc = adjustingDocument(on: page),
              // Stored as fractions of the page so the placement survives a
              // different canvas size and can be reproduced in thumbnails.
              let fractions = ImportedArtwork.fractions(
                  of: frame, in: PageGeometry.contentSize(for: page)
              ) else { return }
        doc.frameX = fractions.x
        doc.frameY = fractions.y
        doc.frameWidth = fractions.width
        doc.frameHeight = fractions.height
        // One undo step for the whole session: the placement, and any
        // rotation or crop made while the handles were up. A page from
        // before `ImportedDocument` had no row to snapshot; not undoable.
        if let before = adjustingSnapshot, before != ArtworkSnapshot(doc) {
            changeArtwork(doc.id, on: page, from: before, to: ArtworkSnapshot(doc))
        } else {
            page.markModified()
            saveMetadata("Failed to save image placement")
        }
    }
    #else
    // Not available on native macOS (no PencilKit canvas to place against).
    func beginAdjustingImage(on page: Page, at point: CGPoint) {}
    func beginAdjustingImage(on page: Page, layerID: UUID) {}
    func finishAdjustingImage(on page: Page) {}
    #endif

    /// Puts an imported file behind an existing page's ink instead of
    /// creating a new page for it. Any document previously imported onto
    /// this page is dropped first - a page renders exactly one background,
    /// and `SearchIndex` resolves one ImportedDocument per page, so leaving
    /// the old record around would make which one wins arbitrary.
    ///
    /// `fullBleed` makes the page take the document's own shape and the
    /// artwork fill it edge to edge. That's what an imported PDF template
    /// wants: it *is* the page, so it shouldn't be a portrait rectangle
    /// aspect-fitted into the middle of a landscape one. A photo is
    /// different - it's a picture placed on a page - so it keeps the
    /// centred fit and opens the placement handles.
    @discardableResult
    func applyBackground(
        _ storedFilename: String,
        sourceType: String,
        pdfPageIndex: Int,
        to page: Page,
        fullBleed: Bool
    ) -> ImportedDocument {
        // Whatever is already on the page stays. A PDF arrives full bleed
        // as the page's paper, so it goes *under* the pictures already
        // there; a photo is placed on the page, so it goes on top. Either
        // way nothing is replaced - importing a PDF onto a page with a
        // photo on it used to throw the photo away.
        let stack = documents(on: page)
        let importedDoc = ImportedDocument(
            sourceType: sourceType,
            fileRef: storedFilename,
            pdfPageIndex: pdfPageIndex,
            page: page
        )
        if fullBleed {
            importedDoc.stackOrder = ImportedDocument.stackOrder(under: stack)
            page.backgroundRef = storedFilename
            if let aspect = ImportedArtwork.aspectRatio(fileRef: storedFilename, pdfPageIndex: pdfPageIndex) {
                page.aspectRatio = aspect
                importedDoc.frameX = 0
                importedDoc.frameY = 0
                importedDoc.frameWidth = 1
                importedDoc.frameHeight = 1
            }
        } else {
            importedDoc.stackOrder = ImportedDocument.stackOrder(over: stack)
            // `backgroundRef` is the bottom of the stack; it only changes
            // when there was nothing there.
            if stack.isEmpty { page.backgroundRef = storedFilename }
        }
        modelContext.insert(importedDoc)

        page.markModified()
        saveMetadata("Failed to import onto the current page")
        return importedDoc
    }

    /// Brings a PDF page imported before pages had a shape of their own up
    /// to date, the first time it's opened: give the page the PDF's
    /// proportions and let the artwork fill it. Only untouched imports
    /// qualify - anything that was deliberately moved, resized or cropped
    /// is left exactly as it was placed.
    func adoptImportedPageShapeIfNeeded(_ page: Page) {
        let stack = documents(on: page)
        guard page.aspectRatio == nil,
              let ref = page.backgroundRef,
              stack.count == 1, let doc = stack.first,
              doc.sourceType == "pdf",
              doc.frameX == nil, doc.frameY == nil,
              doc.frameWidth == nil, doc.frameHeight == nil,
              doc.cropWidth == nil, doc.cropHeight == nil,
              (doc.rotationDegrees ?? 0) == 0,
              let aspect = ImportedArtwork.aspectRatio(fileRef: ref, pdfPageIndex: doc.pdfPageIndex)
        else { return }

        page.aspectRatio = aspect
        doc.frameX = 0
        doc.frameY = 0
        doc.frameWidth = 1
        doc.frameHeight = 1
        saveMetadata("Failed to update imported page shape")
    }

    /// Writes the import into the library off the main actor and returns
    /// its stored filename.
    nonisolated static func writeImport(_ data: Data, extension ext: String) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            let storedFilename = "\(UUID().uuidString).\(ext)"
            let destination = FileStore.baseDirectory().appendingPathComponent(storedFilename)
            do {
                try data.write(to: destination, options: .atomic)
                return storedFilename
            } catch {
                AppLog.note("import", "Failed to write imported file: \(error)")
                return nil
            }
        }.value
    }

    /// Sets the picker's types before presenting it, so the one importer
    /// on this view can serve both the PDF and the image menu items.
    func presentFileImporter(for types: [UTType]) {
        fileImporterTypes = types
        showingFileImporter = true
    }

    /// The PDF import proper. Takes bytes rather than a URL so a PDF that
    /// was pasted or dragged in goes down exactly the same path as one
    /// picked from Files.
    func importPDF(data: Data, target: ImportTarget) async {
        guard let document = PDFDocument(data: data) else {
            exportMessage = "That file isn't a PDF Mystnotes can read."
            return
        }
        guard let storedFilename = await Self.writeImport(data, extension: "pdf") else {
            exportMessage = "Couldn't save the imported PDF."
            return
        }

        saveCurrentPage()

        if target == .currentPage, let page = currentPage {
            // Only the first PDF page can go onto an existing page; the
            // rest would need pages of their own, which is what
            // "as New Pages" is for.
            applyBackground(storedFilename, sourceType: "pdf", pdfPageIndex: 0, to: page, fullBleed: true)
            // No placement handles: the page has just taken the PDF's own
            // shape, so the template already lines up exactly. Long-press
            // still opens them if it needs nudging.
            return
        }

        var newIndex = sortedPages.count
        for pdfPageIndex in 0..<document.pageCount {
            let page = Page(index: newIndex, type: "paged", template: "blank", notebook: notebook)
            page.backgroundRef = storedFilename
            modelContext.insert(page)

            let importedDoc = ImportedDocument(
                sourceType: "pdf",
                fileRef: storedFilename,
                pdfPageIndex: pdfPageIndex,
                page: page
            )
            // Each imported page takes that PDF page's own proportions and
            // is filled edge to edge, so an engineering-paper template
            // arrives as a real portrait sheet rather than a letterboxed
            // picture on a differently-shaped page. Page shapes are
            // per-page, so a PDF that mixes portrait and landscape imports
            // correctly too.
            if let aspect = ImportedArtwork.aspectRatio(fileRef: storedFilename, pdfPageIndex: pdfPageIndex) {
                page.aspectRatio = aspect
                importedDoc.frameX = 0
                importedDoc.frameY = 0
                importedDoc.frameWidth = 1
                importedDoc.frameHeight = 1
            }
            modelContext.insert(importedDoc)

            if notebook.pages == nil {
                notebook.pages = [page]
            } else {
                notebook.pages?.append(page)
            }
            newIndex += 1
        }

        notebook.modifiedAt = Date()
        saveMetadata("Failed to save imported PDF pages")

        // A PDF that reports zero pages would otherwise leave
        // currentPageIndex one past the end, where currentPage is nil and
        // the view sits on "Loading..." forever.
        guard document.pageCount > 0 else { return }
        currentPageIndex = max(sortedPages.count - document.pageCount, 0)
        viewport.reset(for: currentPage?.id)
        installFreshCanvas(forPageID: currentPage?.id)
    }

    #if targetEnvironment(macCatalyst) || canImport(UIKit)

    /// Every way an image can arrive funnels through here: the Photos
    /// picker, the Files/Finder importer, ⌘V, and a drag onto the page.
    /// Before this there was only the Photos picker, which on a Mac is the
    /// one place a Mac user's pictures generally are *not*.
    ///
    /// The bytes are written exactly as they came. The old path decoded to
    /// a `UIImage` and re-encoded JPEG at 0.9 on the main actor - lossy for
    /// a PNG screenshot, and a full decode of a 12-megapixel photo on the
    /// thread that has to stay clear for ink (invariant 10).
    func importImage(data: Data, target: ImportTarget) async {
        guard let kind = ImportedFileType.of(data) else {
            exportMessage = "That file isn't an image Mystnotes can read."
            return
        }
        // A pasted or dropped PDF is a document, not a picture: it goes
        // through the PDF path so multi-page imports still work.
        if kind.isPDF {
            await importPDF(data: data, target: target)
            return
        }
        guard let storedFilename = await Self.writeImport(data, extension: kind.fileExtension) else {
            exportMessage = "Couldn't save the imported image."
            return
        }

        saveCurrentPage()

        if target == .currentPage, let page = currentPage {
            let doc = applyBackground(storedFilename, sourceType: "image", pdfPageIndex: 0, to: page, fullBleed: false)
            beginAdjustingImage(on: page, layerID: doc.id)
            return
        }

        let newIndex = sortedPages.count
        let page = Page(index: newIndex, type: "paged", template: "blank", notebook: notebook)
        page.backgroundRef = storedFilename
        modelContext.insert(page)

        let importedDoc = ImportedDocument(sourceType: "image", fileRef: storedFilename, pdfPageIndex: 0, page: page)
        modelContext.insert(importedDoc)

        if notebook.pages == nil {
            notebook.pages = [page]
        } else {
            notebook.pages?.append(page)
        }
        notebook.modifiedAt = Date()
        saveMetadata("Failed to save imported image page")

        currentPageIndex = newIndex
        viewport.reset(for: page.id)
        installFreshCanvas(forPageID: page.id)
    }

    func importImage(from item: PhotosPickerItem) async {
        defer { selectedPhotoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        await importImage(data: data, target: importTarget)
    }

    /// A file chosen in the Files/Finder importer. Images and PDFs both
    /// arrive here, and the sniffed type decides which way they go - so
    /// picking a PDF from the image importer still does the right thing.
    func importFile(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            exportMessage = "Couldn't read \(url.lastPathComponent)."
            return
        }
        let target = importTarget
        Task { await importImage(data: data, target: target) }
    }

    /// Whether the Import menu's Paste Image item should be live. A
    /// silent check - see `CanvasPasteboard`.
    var pasteboardHasImage: Bool { CanvasPasteboard.hasImage }

    /// The menu route to the same thing ⌘V does. The keyboard route goes
    /// through the responder chain instead (`CanvasHostView.paste`), which
    /// is the only way to get the system Edit menu's own Paste item to
    /// reach the canvas.
    func pasteImageFromClipboard() {
        guard let data = CanvasPasteboard.payload() else {
            exportMessage = "There's no image on the clipboard."
            return
        }
        Task { await importImage(data: data, target: .currentPage) }
    }

    /// ⌘V, or a picture dragged onto the page from Finder / Files / another
    /// app. Always lands on the page you're looking at - that's where you
    /// dropped it.
    func importDroppedOrPasted(_ data: Data, onto page: Page) {
        guard !isPresenting else { return }
        Task { await importImage(data: data, target: .currentPage) }
    }

    #else
    // Dummy implementation for macOS native
    func importImage(from item: PhotosPickerItem) async {
        // Do nothing
    }
    #endif
}
