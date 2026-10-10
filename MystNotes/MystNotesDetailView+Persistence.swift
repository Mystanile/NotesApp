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
    // MARK: - Drawing persistence

    func loadCurrentPageDrawing() {
        MainThreadWatchdog.checkpoint("DetailView.loadCurrentPageDrawing")
        guard let page = currentPage else {
            installFreshCanvas(forPageID: nil)
            return
        }
        // A different page means a different sheet: the canvas refits it, so
        // stand the dependent layers down until it reports back rather than
        // letting them flash at the outgoing page's zoom.
        viewport.reset(for: page.id)
        // The placement handles belong to the page they were opened on.
        // Leaving a page with them up used to carry that rect onto the next
        // page - and `ImportedPageBackgroundView` draws its artwork at
        // `liveFrame` whenever one is set, so the incoming page's picture
        // would be drawn in the outgoing page's box.
        if page.id != canvasPageID {
            adjustingImageFrame = nil
            adjustingLayerID = nil
            croppingRect = nil
        }
        adoptImportedPageShapeIfNeeded(page)
#if targetEnvironment(macCatalyst) || canImport(UIKit)
        var drawing = PKDrawing()
        if let saved = drawingStore.load(pageID: page.id) {
            drawing = fittingWithinPage(saved, on: page)
        }
        installFreshCanvas(with: drawing, forPageID: page.id)
#else
        installFreshCanvas(forPageID: page.id)
#endif
    }

    /// Every page gets its own canvas view, made here the moment the page
    /// is opened or created.
    ///
    /// Pages used to share one `PKCanvasView` with `.drawing` swapped in
    /// place, and each fix for what leaked across that swap (the undo stack
    /// restoring another page's ink, the whiteboard's zoom and scroll
    /// position, its rendered strokes lingering on a freshly added page)
    /// left the next one waiting. A page that starts from a new view has
    /// nothing to inherit: its drawing is exactly what's passed in, its
    /// undo history is empty, and its scroll view has never been anywhere.
    func installFreshCanvas(with drawing: PKDrawing = PKDrawing(), forPageID pageID: UUID?) {
        // The outgoing canvas takes its undo stack with it.
        commitPendingTrash()
        if let pending = pendingDeletion, pending.landingPageID != pageID { commitPendingDeletion() }
        canvasPageID = pageID
        canvasIsDirty = false
        ownSaveDate = nil
        loadedInkStamp = pageID.flatMap { InkStamp(of: $0, in: drawingStore) }
        autosaveTask?.cancel()
#if targetEnvironment(macCatalyst) || canImport(UIKit)
        let fresh = PageCanvasView()
        fresh.drawing = drawing
        canvasView = fresh
        // The tool and the shape/fill interaction gate live on the canvas
        // instance, so the new one has to be told about them.
        applyToolState()
#endif
        refreshUndoRedoState()
    }

#if targetEnvironment(macCatalyst) || canImport(UIKit)
    /// Rescues ink saved before pages had a fixed size of their own.
    ///
    /// Back then a page's coordinate space was simply however large the
    /// canvas happened to be, so a note written on a landscape iPad has
    /// strokes running well past the right edge of the page it now lives
    /// on - they'd be cut off. Ink can no longer be drawn outside the page,
    /// so anything that overflows must be from that era: scale it down (never
    /// up, and never move it) to fit, once, and save it back in page space.
    func fittingWithinPage(_ drawing: PKDrawing, on page: Page) -> PKDrawing {
        // A whiteboard has no page to fit inside - its board is 3000pt
        // square and ink is *meant* to run well past 780x1040.
        guard page.type != "whiteboard" else { return drawing }
        let pageSize = PageGeometry.contentSize(for: page)
        let bounds = drawing.bounds
        guard !bounds.isNull, !bounds.isEmpty, bounds.maxX > 0, bounds.maxY > 0 else { return drawing }

        let scale = min(1, min(pageSize.width / bounds.maxX, pageSize.height / bounds.maxY))
        // A couple of percent of overhang is a stroke drawn against the edge,
        // not a page from a differently sized canvas.
        guard scale < 0.98 else { return drawing }

        let fitted = drawing.transformed(using: CGAffineTransform(scaleX: scale, y: scale))
        try? drawingStore.save(fitted, pageID: page.id)
        return fitted
    }
#endif

    /// Saves the canvas to the page it was loaded for - if the user changed
    /// it. A canvas nobody drew on is never written: it may be blank only
    /// because its ink hasn't arrived yet, and writing it would replace
    /// that ink with nothing.
    /// `blocking` is for the one case that can't be asynchronous: the app
    /// is going to the background and may be suspended before a background
    /// write would land (invariant 1). Everywhere else the write goes off
    /// the main thread.
    func saveCurrentPage(force: Bool = false, blocking: Bool = false) {
        MainThreadWatchdog.checkpoint("DetailView.saveCurrentPage")
        guard canvasIsDirty || force,
              let pageID = canvasPageID,
              let page = sortedPages.first(where: { $0.id == pageID }) else { return }
        canvasIsDirty = false
#if targetEnvironment(macCatalyst) || canImport(UIKit)
        let drawing = canvasView.drawing
        if blocking {
            saveBlocking(drawing, to: page)
        } else {
            Task { await save(drawing, to: page) }
        }
#else
        save(to: page)
#endif
    }

#if targetEnvironment(macCatalyst) || canImport(UIKit)
    /// Writes `drawing` to `page`'s file. The page and the drawing are
    /// passed together on purpose: the autosave that fires a second after
    /// a stroke must save the page that stroke was drawn on, even if a
    /// different page has been opened since.
    ///
    /// The encode-compress-write is off the main thread (`saveDetached`);
    /// only the SwiftData half runs here, because the model context is
    /// main-actor. `markModified()` deliberately comes *after* the bytes
    /// are on disk: it is what re-renders this page's thumbnail and what a
    /// pull compares against, and neither may see a date newer than the
    /// ink it stands for.
    func save(_ drawing: PKDrawing, to page: Page) async {
        switch await DrawingStore.saveDetached(drawingStore, drawing, pageID: page.id).value {
        case .success(let ref):
            page.drawingFileRef = ref
            page.markModified()
            if page.id == canvasPageID {
                ownSaveDate = page.modifiedAt
                loadedInkStamp = InkStamp(of: page.id, in: drawingStore)
            }
            do { try modelContext.save() } catch { AppLog.note("save", "metadata: \(error)") }
        case .failure(let error):
            AppLog.note("save", "drawing: \(error)")
            // The ink is still in the canvas and still dirty as far as the
            // next autosave is concerned, so it gets another go.
            if page.id == canvasPageID { canvasIsDirty = true }
        }
    }

    /// The same save, run here and now. Only for backgrounding.
    func saveBlocking(_ drawing: PKDrawing, to page: Page) {
        do {
            page.drawingFileRef = try drawingStore.save(drawing, pageID: page.id)
            page.markModified()
            if page.id == canvasPageID {
                ownSaveDate = page.modifiedAt
                loadedInkStamp = InkStamp(of: page.id, in: drawingStore)
            }
            try modelContext.save()
        } catch {
            AppLog.note("save", "drawing (blocking): \(error)")
            if page.id == canvasPageID { canvasIsDirty = true }
        }
    }
#else
    func save(to page: Page) {
        page.drawingFileRef = DrawingStore.fileName(for: page.id)
        page.markModified()
        if page.id == canvasPageID {
            ownSaveDate = page.modifiedAt
            loadedInkStamp = InkStamp(of: page.id, in: drawingStore)
        }
        try? modelContext.save()
    }
#endif

    func scheduleAutosave() {
        refreshUndoRedoState()
        // Only a user change reaches here (strokes, shapes, elements). The
        // canvas is now worth saving - and only to the page it was loaded for.
        canvasIsDirty = true
        guard let pageToIndex = currentPage, pageToIndex.id == canvasPageID else { return }
        // Pin down which page's canvas this is for now. By the time the
        // delay is up the user may be on another page with another canvas,
        // and this must never write one page's ink into another's file.
#if targetEnvironment(macCatalyst) || canImport(UIKit)
        let canvas = canvasView
#endif
        autosaveTask?.cancel()
        autosaveTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
#if targetEnvironment(macCatalyst) || canImport(UIKit)
            if canvasPageID == pageToIndex.id { canvasIsDirty = false }
            await save(canvas.drawing, to: pageToIndex)
#else
            save(to: pageToIndex)
            if canvasPageID == pageToIndex.id { canvasIsDirty = false }
#endif
        }
        // Handwriting recognition is on a much longer timer of its own.
        // Awaiting it here meant a full Vision pass - render the page at
        // 2x, composite it, recognize - every single second for as long as
        // anyone kept writing, every one of them thrown away by the next
        // stroke.
        HandwritingIndexer.shared.schedule(pageToIndex, modelContext: modelContext)
    }

    func refreshUndoRedoState() {
#if targetEnvironment(macCatalyst) || canImport(UIKit)
        let newCanUndo = canvasView.undoManager?.canUndo ?? false
        let newCanRedo = canvasView.undoManager?.canRedo ?? false
#else
        let newCanUndo = false
        let newCanRedo = false
#endif
        // Avoid writing @State (and triggering a re-render) when nothing
        // actually changed — this runs on every single stroke update while
        // the user is actively drawing.
        if canUndo != newCanUndo { canUndo = newCanUndo }
        if canRedo != newCanRedo { canRedo = newCanRedo }
    }

    func saveMetadata(_ errorMessage: String) {
        do {
            try modelContext.save()
        } catch {
            print("\(errorMessage): \(error)")
        }
    }

    /// Brief "Saved" confirmation so the toolbar Save button gives visible
    /// feedback instead of appearing to do nothing (autosave already covers
    /// the common case, but a manual save should still confirm it happened).
    func showSaveConfirmation() {
        saveConfirmationTask?.cancel()
        withAnimation { showingSaveConfirmation = true }
        saveConfirmationTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { showingSaveConfirmation = false }
        }
    }
}
