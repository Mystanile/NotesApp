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
        // A page waiting on Delete's undo still holds its index; renumbering
        // around it would leave two pages with one index.
        commitPendingDeletion()
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
        commitPendingDeletion()
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

    /// Page strip menu: a page right after the current one made from a
    /// custom template (`PageTemplates`) - its paper, shape and artwork,
    /// no ink. The file is shared with the template by name. The copy is
    /// `PageTemplates.insertPage`, which is what the tests drive.
    func addPage(fromTemplate template: Page) {
        commitPendingDeletion()
        saveCurrentPage()
        let after = currentPage?.index ?? ((sortedPages.last?.index ?? -1))
        let page = PageTemplates.insertPage(copyingPaperOf: template, into: notebook, at: after + 1,
                                            paperOnly: false, in: modelContext)
        saveMetadata("Failed to add the page from the template")
        jumpToPage(withID: page.id)
    }

    /// Page strip menu: keeps the open page's paper as a custom template.
    func saveCurrentPageAsTemplate() {
        guard let page = currentPage else { return }
        PageTemplates.saveAsTemplate(page, in: modelContext)
        saveMetadata("Failed to save the template")
    }

    /// The page strip's add-page control: a menu of new-page choices.
    /// Replaces `addPageButton` (which just did "New Page Like This").
    @ViewBuilder
    var addPageMenu: some View {
        PageAddMenu(
            canCopyCurrent: currentPage?.type == "paged",
            templates: PageTemplates.templates(in: allNotebooks),
            onBlank: { choose { addPage(type: "paged", template: AppSettings.defaultTemplate) } },
            onLikeThis: { choose { if let page = currentPage { addPage(like: page) } } },
            onPaper: { id in choose { addPage(type: "paged", template: id) } },
            onWhiteboard: { choose { addPage(type: "whiteboard", template: "blank") } },
            onTemplate: { template in choose { addPage(fromTemplate: template) } },
            onSaveCurrent: { saveCurrentPageAsTemplate() })
    }

    private func choose(_ action: () -> Void) {
        action()
        if isCompactWidth { withAnimation(.snappy) { compactSidebarOpen = false } }
    }

    /// The shape the next New Page takes: a size picked from the menu, or
    /// nil for the shape of the page you're on - so a landscape notebook,
    /// or one continuing a PDF, keeps going in that shape.
    var newPageSizeLabel: String {
        guard let aspect = newPageAspect else { return "Same as This Page" }
        return PageGeometry.sizes.first { abs($0.aspect - aspect) < 0.0001 }?.label ?? "Custom"
    }

    func addPage(type: String, template: String) {
        commitPendingDeletion()
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
        // The copy reads the ink from disk, so the open page's last strokes
        // must be written first.
        saveCurrentPage(blocking: true)
        var index = (destination.pages ?? []).count
        for source in pages {
            let page = Page(index: index, type: source.type, template: source.template, notebook: destination)
            page.backgroundRef = source.backgroundRef
            page.aspectRatio = source.aspectRatio
            page.recognizedTextCache = source.recognizedTextCache
            page.title = source.title
            page.isBookmarked = source.isBookmarked
            page.tags = source.tags
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

    /// Page menu: Duplicate Page. A copy right after `page` - settings,
    /// elements and the ink - via `PageDuplication`. The open page's last
    /// strokes are written first (only if the canvas is dirty, so a canvas
    /// whose ink hasn't arrived is never saved) so the copy has them.
    func duplicatePage(_ page: Page) {
        commitPendingDeletion()
        saveCurrentPage(blocking: true)
        let documents = allImportedDocuments.filter { $0.page?.id == page.id }
        Task {
            let copy = await PageDuplication.duplicate(page, in: notebook, documents: documents,
                                                       context: modelContext, store: drawingStore)
            saveMetadata("Failed to duplicate the page")
            jumpToPage(withID: copy.id)
        }
    }

    /// Page Grid: delete several pages through the single-page path, which
    /// commits the previous pending deletion each time (everything but the
    /// last goes to the trash at once; the last keeps its undo banner). The
    /// notebook always keeps one page.
    func deletePages(withIDs ids: [UUID]) {
        for id in ids {
            guard sortedPages.count > 1, let page = sortedPages.first(where: { $0.id == id }) else { continue }
            requestDeletePage(page)
        }
    }

    /// Page Grid: duplicate each page right after its source, in order.
    func duplicatePages(withIDs ids: [UUID]) {
        commitPendingDeletion()
        saveCurrentPage(blocking: true)
        let sources = sortedPages.filter { ids.contains($0.id) }
        guard !sources.isEmpty else { return }
        let documents = allImportedDocuments
        Task {
            for source in sources {
                let own = documents.filter { $0.page?.id == source.id }
                _ = await PageDuplication.duplicate(source, in: notebook, documents: own,
                                                    context: modelContext, store: drawingStore)
            }
            saveMetadata("Failed to duplicate the pages")
        }
    }

    #if targetEnvironment(macCatalyst) || canImport(UIKit)
    /// Page Grid: the chosen pages, in notebook order, as one PDF.
    func exportPagesAsPDF(withIDs ids: [UUID]) {
        saveCurrentPage(blocking: true)
        let entries = sortedPages.filter { ids.contains($0.id) }.map { (page: $0, artwork: artwork(for: $0)) }
        guard !entries.isEmpty else { return }
        presentPDF(PageRenderer.pdfData(for: entries), named: "\(notebook.title) - \(entries.count) pages")
    }
    #else
    func exportPagesAsPDF(withIDs ids: [UUID]) {}
    #endif

    /// Go to Page: opens the number prompt.
    func promptGoToPage() {
        goToPageText = ""
        showingGoToPage = true
    }

    func commitGoToPage() {
        if let index = PageNavigation.index(forEntered: goToPageText, pageCount: sortedPages.count) {
            jumpToPage(at: index)
        }
        showingGoToPage = false
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

// MARK: - Go to Page, page indicator, Duplicate Page

/// The arithmetic behind Go to Page and the page indicator.
enum PageNavigation {
    /// The zero-based index for what was typed (one-based), clamped to the
    /// notebook; nil for nothing or non-numbers.
    static func index(forEntered text: String, pageCount: Int) -> Int? {
        guard pageCount > 0,
              let number = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return min(max(number, 1), pageCount) - 1
    }

    /// "3 / 20" for the zero-based `index`.
    static func indicatorText(index: Int, count: Int) -> String {
        "\(index + 1) / \(count)"
    }
}

/// The copy behind Duplicate Page. Kept off the view so tests can drive it.
enum PageDuplication {
    /// Inserts a copy of `source` right after it and renumbers the pages
    /// behind it (each marked modified, so the order syncs). Copies the page
    /// settings, text blocks, stickers and `documents` (artwork files are
    /// shared by name); the ink goes through `DrawingStore.copyDetached`,
    /// which saves it under the new page's id with fresh stroke ids. Links
    /// are not copied.
    static func duplicate(_ source: Page, in notebook: Notebook, documents: [ImportedDocument],
                          context: ModelContext, store: DrawingStore) async -> Page {
        // Everything after the source moves up one - before the copy
        // exists, so it can't be counted among them.
        for other in notebook.pages ?? [] where other.index > source.index {
            other.index += 1
            other.markModified()
        }
        let page = Page(index: source.index + 1, type: source.type, template: source.template, notebook: notebook)
        page.backgroundRef = source.backgroundRef
        page.aspectRatio = source.aspectRatio
        page.recognizedTextCache = source.recognizedTextCache
        page.title = source.title
        page.tags = source.tags
        context.insert(page)
        if !(notebook.pages ?? []).contains(where: { $0.id == page.id }) {
            notebook.pages = (notebook.pages ?? []) + [page]
        }

        for block in source.textBlocks ?? [] {
            let copy = TypedTextBlock(content: block.content, page: page)
            copy.frameX = block.frameX; copy.frameY = block.frameY
            copy.frameWidth = block.frameWidth; copy.frameHeight = block.frameHeight
            copy.textColorHex = block.textColorHex
            copy.fontSize = block.fontSize; copy.fontDesign = block.fontDesign
            copy.isBold = block.isBold; copy.isItalic = block.isItalic
            context.insert(copy)
        }
        for sticker in source.stickers ?? [] {
            let copy = Sticker(assetRef: sticker.assetRef, page: page)
            copy.frameX = sticker.frameX; copy.frameY = sticker.frameY
            copy.frameWidth = sticker.frameWidth; copy.frameHeight = sticker.frameHeight
            copy.rotationDegrees = sticker.rotationDegrees
            context.insert(copy)
        }
        for doc in documents {
            let copy = ImportedDocument(sourceType: doc.sourceType, fileRef: doc.fileRef,
                                        pdfPageIndex: doc.pdfPageIndex, page: page)
            copy.frameX = doc.frameX; copy.frameY = doc.frameY
            copy.frameWidth = doc.frameWidth; copy.frameHeight = doc.frameHeight
            copy.rotationDegrees = doc.rotationDegrees
            copy.cropX = doc.cropX; copy.cropY = doc.cropY
            copy.cropWidth = doc.cropWidth; copy.cropHeight = doc.cropHeight
            copy.stackOrder = doc.stackOrder
            context.insert(copy)
        }

#if targetEnvironment(macCatalyst) || canImport(UIKit)
        switch await DrawingStore.copyDetached(store, from: source.id, to: page.id).value {
        case .success(let ref): page.drawingFileRef = ref
        case .failure(let error): AppLog.note("duplicate", "ink of \(source.id): \(error)")
        }
#endif
        page.markModified()
        return page
    }
}

/// "3 / 20" at the bottom of the canvas: appears when the page changes,
/// fades out two seconds later, and a tap opens Go to Page.
struct PageIndicatorOverlay: View {
    var index: Int
    var count: Int
    var onTap: () -> Void

    @State private var visible = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        Group {
            if visible {
                Button(action: onTap) {
                    Text(PageNavigation.indicatorText(index: index, count: count))
                        .font(Typography.caption.monospacedDigit())
                        .foregroundStyle(.primary)
                        .padding(.horizontal, Space.m)
                        .padding(.vertical, Space.xs)
                        .minimumHitTarget()
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Palette.separator, lineWidth: Metrics.hairline))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Page \(index + 1) of \(count)")
                .accessibilityHint("Go to a page")
                .transition(.opacity)
            }
        }
        .padding(.bottom, 56)
        .onChange(of: index) { _, _ in show() }
    }

    private func show() {
        hideTask?.cancel()
        withAnimation(Motion.quick) { visible = true }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.4)) { visible = false }
        }
    }
}
