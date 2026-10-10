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
    // MARK: - Page navigation

    func jumpToPage(at index: Int) {
        guard index != currentPageIndex, sortedPages.indices.contains(index) else { return }
        saveCurrentPage()
        currentPageIndex = index
        loadCurrentPageDrawing()
    }

    func jumpToPage(withID id: UUID) {
        guard let index = sortedPages.firstIndex(where: { $0.id == id }) else {
            if let target = allNotebooks.first(where: { $0.id != notebook.id && ($0.pages ?? []).contains { $0.id == id } }) {
                saveCurrentPage()
                let number = ((target.pages ?? []).first { $0.id == id }?.index ?? 0) + 1
                otherNotebookTarget = SearchResult(notebook: target, pageID: id, pageNumber: number, snippet: "")
            }
            return
        }
        jumpToPage(at: index)
    }

    /// Puts the page at `targetIndex` and re-sequences the rest, keeping
    /// the open page open. Every page whose index changed is marked
    /// modified, so the new order syncs.
    func movePage(withID id: UUID, to targetIndex: Int) {
        var pages = sortedPages
        guard let from = pages.firstIndex(where: { $0.id == id }), from != targetIndex,
              pages.indices.contains(targetIndex) else { return }
        pages.insert(pages.remove(at: from), at: targetIndex)
        for (newIndex, page) in pages.enumerated() where page.index != newIndex {
            page.index = newIndex
            page.markModified()
        }
        if let open = pages.firstIndex(where: { $0.id == canvasPageID }) { currentPageIndex = open }
        saveMetadata("Failed to reorder pages")
    }

    /// Page strip menu: a blank page right after `source` with the same
    /// paper, shape and imported background - a PDF worksheet or template
    /// used again. Only the paper layer comes along, not photos placed on
    /// top, and no ink. The file is shared by name, as pages of one PDF
    /// import already share theirs.
    func addPage(like source: Page) {
        saveCurrentPage()
        // Everything after the source moves up one - before the new page
        // exists, so it can't be counted among them.
        for other in sortedPages where other.index > source.index {
            other.index += 1
            other.markModified()
        }
        let page = Page(index: source.index + 1, type: source.type, template: source.template, notebook: notebook)
        page.aspectRatio = source.aspectRatio
        modelContext.insert(page)
        if let paper = documents(on: source).first, ArtworkLayer(paper).isPaper {
            let copy = ImportedDocument(sourceType: paper.sourceType, fileRef: paper.fileRef,
                                        pdfPageIndex: paper.pdfPageIndex, page: page)
            (copy.frameX, copy.frameY, copy.frameWidth, copy.frameHeight) =
                (paper.frameX, paper.frameY, paper.frameWidth, paper.frameHeight)
            copy.rotationDegrees = paper.rotationDegrees
            (copy.cropX, copy.cropY, copy.cropWidth, copy.cropHeight) =
                (paper.cropX, paper.cropY, paper.cropWidth, paper.cropHeight)
            modelContext.insert(copy)
            page.backgroundRef = paper.fileRef
        }
        if !(notebook.pages ?? []).contains(where: { $0.id == page.id }) {
            notebook.pages = (notebook.pages ?? []) + [page]
        }
        page.markModified()
        saveMetadata("Failed to add the page")
        jumpToPage(withID: page.id)
    }

    /// The shape the next New Page takes: a size picked from the menu, or
    /// nil for the shape of the page you're on - so a landscape notebook,
    /// or one continuing a PDF, keeps going in that shape.
    var newPageSizeLabel: String {
        guard let aspect = newPageAspect else { return "Same as This Page" }
        return PageGeometry.sizes.first { abs($0.aspect - aspect) < 0.0001 }?.label ?? "Custom"
    }

    func addPage(type: String, template: String) {
        saveCurrentPage()

        let newIndex = sortedPages.count
        let page = Page(index: newIndex, type: type, template: template, notebook: notebook)
        if type == "paged" {
            page.aspectRatio = newPageAspect ?? (currentPage?.type == "paged" ? currentPage?.aspectRatio : nil)
        }
        modelContext.insert(page)

        if notebook.pages == nil {
            notebook.pages = [page]
        } else {
            notebook.pages?.append(page)
        }
        notebook.modifiedAt = Date()

        do {
            try modelContext.save()
        } catch {
            print("Failed to save new page: \(error)")
        }

        currentPageIndex = newIndex
        viewport.reset(for: page.id)
        installFreshCanvas(forPageID: page.id)
    }

    /// Appends copies of `pages` to `destination`: page settings, text
    /// blocks, stickers and artwork placements, and the ink under new
    /// stroke ids (`DrawingStore.copyDetached`). Artwork files are shared
    /// by name, as pages of one PDF import already share theirs. Links are
    /// not copied: they point at pages of this notebook.
    func copyPages(_ pages: [Page], to destination: Notebook) async {
        saveCurrentPage()
        var index = (destination.pages ?? []).count
        for source in pages {
            let page = Page(index: index, type: source.type, template: source.template, notebook: destination)
            page.backgroundRef = source.backgroundRef
            page.aspectRatio = source.aspectRatio
            page.recognizedTextCache = source.recognizedTextCache
            page.title = source.title
            page.isBookmarked = source.isBookmarked
            modelContext.insert(page)
            if destination.pages == nil { destination.pages = [page] } else { destination.pages?.append(page) }

            for block in source.textBlocks ?? [] {
                let copy = TypedTextBlock(content: block.content, page: page)
                copy.frameX = block.frameX; copy.frameY = block.frameY
                copy.frameWidth = block.frameWidth; copy.frameHeight = block.frameHeight
                copy.textColorHex = block.textColorHex
                copy.fontSize = block.fontSize; copy.fontDesign = block.fontDesign
                copy.isBold = block.isBold; copy.isItalic = block.isItalic
                modelContext.insert(copy)
            }
            for sticker in source.stickers ?? [] {
                let copy = Sticker(assetRef: sticker.assetRef, page: page)
                copy.frameX = sticker.frameX; copy.frameY = sticker.frameY
                copy.frameWidth = sticker.frameWidth; copy.frameHeight = sticker.frameHeight
                copy.rotationDegrees = sticker.rotationDegrees
                modelContext.insert(copy)
            }
            for doc in allImportedDocuments where doc.page?.id == source.id {
                let copy = ImportedDocument(sourceType: doc.sourceType, fileRef: doc.fileRef,
                                            pdfPageIndex: doc.pdfPageIndex, page: page)
                copy.frameX = doc.frameX; copy.frameY = doc.frameY
                copy.frameWidth = doc.frameWidth; copy.frameHeight = doc.frameHeight
                copy.rotationDegrees = doc.rotationDegrees
                copy.cropX = doc.cropX; copy.cropY = doc.cropY
                copy.cropWidth = doc.cropWidth; copy.cropHeight = doc.cropHeight
                copy.stackOrder = doc.stackOrder
                modelContext.insert(copy)
            }

#if targetEnvironment(macCatalyst) || canImport(UIKit)
            switch await DrawingStore.copyDetached(drawingStore, from: source.id, to: page.id).value {
            case .success(let ref): page.drawingFileRef = ref
            case .failure(let error): AppLog.note("copy", "ink of \(source.id): \(error)")
            }
#endif
            page.markModified()
            index += 1
        }
        saveMetadata("Failed to copy pages")
    }

    /// Delete Page: hides the page now and deletes it for real only once
    /// that can't be undone (`pendingDeletion`). Undo is the banner's
    /// button, or the undo button while you're on the page you landed on.
    func requestDeletePage(_ page: Page) {
        commitPendingDeletion()
        guard sortedPages.count > 1, let index = sortedPages.firstIndex(where: { $0.id == page.id }) else { return }
        saveCurrentPage()
        let wasCurrent = currentPage?.id == page.id
        let keptID = currentPage?.id
        pendingDeletion = (pageID: page.id, landingPageID: nil)
        // The page list no longer has it; stay on the page you were on, or
        // take its place if it was the open one.
        if wasCurrent {
            currentPageIndex = min(index, sortedPages.count - 1)
        } else if let keptID, let kept = sortedPages.firstIndex(where: { $0.id == keptID }) {
            currentPageIndex = kept
        }
        pendingDeletion?.landingPageID = currentPage?.id
        if wasCurrent {
            endAdjusting()
            loadCurrentPageDrawing()
        }
        let canvas = canvasView
        canvas.undoManager?.registerUndo(withTarget: canvas) { _ in undoPendingDeletion() }
        refreshUndoRedoState()
        deletionBannerTask?.cancel()
        withAnimation { showingDeletionBanner = true }
        deletionBannerTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { showingDeletionBanner = false }
        }
    }

    func undoPendingDeletion() {
        guard let pending = pendingDeletion else { return }
        pendingDeletion = nil
        guard let index = sortedPages.firstIndex(where: { $0.id == pending.pageID }) else { return }
        saveCurrentPage()
        currentPageIndex = index
        loadCurrentPageDrawing()
    }

    /// The pending page is already out of `sortedPages`, so deleting it for
    /// real moves no other page's position and the open page stays open.
    func commitPendingDeletion() {
        guard let pending = pendingDeletion else { return }
        pendingDeletion = nil
        guard let page = notebook.pages?.first(where: { $0.id == pending.pageID }) else { return }
        PageDeletion.delete(page, from: notebook, in: modelContext, drawingStore: drawingStore)
        saveMetadata("Failed to delete page")
    }
}
