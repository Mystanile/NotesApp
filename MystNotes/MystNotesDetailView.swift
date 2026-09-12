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

/// The actual notebook-editing experience: one page's canvas at a time,
/// a page-thumbnail strip for navigation, a custom drawing toolbar
/// (undo/redo, pen/highlighter/eraser/lasso, the shape tool), draggable
/// text/sticker/link elements, PDF/image import, and a distraction-free
/// presentation mode. Elements/shapes/imports only apply to regular paged
/// pages — whiteboard pages keep plain PencilKit drawing (their scroll/zoom
/// coordinate space needs extra math to position overlays correctly, a
/// reasonable follow-up rather than folding into this already-large set of
/// phases).
struct NotebookDetailView: View {
    @Bindable var notebook: Notebook

    /// When non-nil (a search result), the view opens on this page instead of
    /// page 0.
    let initialPageID: UUID?

    init(notebook: Notebook, initialPageID: UUID? = nil) {
        self.notebook = notebook
        self.initialPageID = initialPageID
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

#if targetEnvironment(macCatalyst) || canImport(UIKit)
    /// The canvas for the page on screen. Replaced with a brand-new
    /// `PageCanvasView` every time a page is opened or created - see
    /// installFreshCanvas - so no ink, zoom or undo history can carry over
    /// from one page to the next.
    @State private var canvasView: PKCanvasView = PageCanvasView()
    // Seeded from the same Settings-configurable defaults PencilKit's own
    // tool used to start from (AppSettings.initialTool()); this is now the
    // single source of truth for canvasView.tool, replacing PKToolPicker.
    @State private var toolState = DrawingToolState(
        penInkType: AppSettings.inkType(for: AppSettings.defaultToolType),
        penColor: Color(hex: AppSettings.defaultInkColorHex),
        penWidth: AppSettings.defaultInkWidth
    )
#else
    // Placeholder for macOS native - PencilKit not available
    @State private var canvasView: Any?
#endif

    /// The live pan/zoom of the paged canvas. Not @State: it's a reference
    /// the canvas writes to on every scroll frame, and only the layers that
    /// actually read it (`PageViewportLayer`) re-render when it changes -
    /// putting it in this view's state would re-evaluate this whole body
    /// sixty times a second during a pinch.
    @State private var viewport = CanvasViewport()

    @State private var currentPageIndex: Int = 0
    @State private var canUndo = false
    @State private var canRedo = false
    @State private var autosaveTask: Task<Void, Never>?
    private let drawingStore = DrawingStore.live
    @State private var drawingNeedsOCR = false
    @State private var showingPageStrip = true

    @State private var isShapeModeArmed = false
#if targetEnvironment(macCatalyst) || canImport(UIKit)
    /// The tool that was active before an Apple Pencil double-tap switched to
    /// the eraser, so a second double-tap can switch straight back to it.
    @State private var toolBeforeEraser: DrawingToolKind?
#endif
    /// Non-nil while the imported artwork on this page is being moved or
    /// resized; holds its live frame in page coordinates.
    @State private var adjustingImageFrame: CGRect?
    /// Non-nil while cropping that artwork; the crop rect in page
    /// coordinates, always kept inside `adjustingImageFrame`.
    @State private var croppingRect: CGRect?
    @State private var showingStickerPicker = false
    @State private var linkNeedingDestination: Link?

    /// Whether an import lands on the page you're looking at or creates new
    /// page(s) after it. Set by whichever Import menu item was tapped, read
    /// when the picker comes back.
    private enum ImportTarget { case newPages, currentPage }
    @State private var importTarget: ImportTarget = .newPages

    @State private var showingPDFImporter = false
    #if targetEnvironment(macCatalyst) || canImport(UIKit)
    @State private var showingImagePicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    #endif

    @State private var isPresenting = false
    @State private var pageToDelete: Page?
    @State private var showingSaveConfirmation = false
    @State private var saveConfirmationTask: Task<Void, Never>?
    @State private var pdfExportURL: PDFExport?
    @State private var exportMessage: String?

    /// Identifiable wrapper so a finished PDF can drive a `.sheet(item:)`.
    private struct PDFExport: Identifiable {
        let id = UUID()
        let url: URL
    }

    @Query private var allLinks: [Link]
    @Query private var allImportedDocuments: [ImportedDocument]

    private var sortedPages: [Page] {
        (notebook.pages ?? []).sorted { $0.index < $1.index }
    }

    private var currentPage: Page? {
        guard sortedPages.indices.contains(currentPageIndex) else { return nil }
        return sortedPages[currentPageIndex]
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                if let page = currentPage {
                    canvasSection(for: page)
                        #if targetEnvironment(macCatalyst) || canImport(UIKit)
                        .overlay(alignment: .top) {
                            // Hidden while placing an image: this is an
                            // overlay, so it draws ON TOP of the canvas
                            // content - including the image toolbar, which
                            // occupies the same top-center spot and was
                            // completely covered by it. Drawing is disabled
                            // during adjust anyway, so there's nothing to
                            // lose by standing it down.
                            if !isPresenting && adjustingImageFrame == nil {
                                // GeometryReader gives the bar the canvas
                                // area to clamp its dragging within, which
                                // is also what keeps it from sliding down
                                // underneath the page-thumbnail strip.
                                GeometryReader { geo in
                                    DrawingToolbarView(
                                        toolState: $toolState,
                                        canUndo: canUndo,
                                        canRedo: canRedo,
                                        isShapeModeArmed: isShapeModeArmed,
                                        isShapeToolAvailable: page.type != "whiteboard",
                                        isFillToolAvailable: page.type != "whiteboard",
                                        containerSize: geo.size,
                                        onUndo: { canvasView.undoManager?.undo() },
                                        onRedo: { canvasView.undoManager?.redo() },
                                        onToggleShapeMode: toggleShapeMode
                                    )
                                    .frame(maxWidth: .infinity, alignment: .center)
                                }
                                .padding(.top, 8)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if showingSaveConfirmation {
                                Label("Saved", systemImage: "checkmark.circle.fill")
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                                    .padding(.bottom, 12)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                        #endif
                    if showingPageStrip && !isPresenting {
                        pageStrip
                    }
                } else {
                    ProgressView("Loading…")
                }
            }

            // Presentation mode is a chrome toggle on this SAME view, not a
            // separate modal — a fullScreenCover would mount a brand-new
            // PencilCanvasView backed by the same PKCanvasView instance,
            // which re-parents that UIView into the modal's hierarchy and
            // never returns it on dismiss (the pen/canvas going blank after
            // exiting presentation mode). Toggling visibility in place keeps
            // canvasView mounted exactly once, always.
            if isPresenting {
                Button {
                    isPresenting = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
        }
        .navigationTitle(notebook.title)
        #if targetEnvironment(macCatalyst) || canImport(UIKit)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isPresenting ? .hidden : .visible, for: .navigationBar)
        .statusBarHidden(isPresenting)
        #endif
        .ignoresSafeArea(.all, edges: isPresenting ? .all : [])
        .onAppear {
            openFirstPage()
            applyToolState()
        }
        #if targetEnvironment(macCatalyst) || canImport(UIKit)
        .onChange(of: toolState) { _, _ in applyToolState() }
        // Switching between a paged page and a whiteboard rebuilds the canvas
        // representable; re-push the tool the user actually has selected
        // (deferred so it lands after the new canvas is made).
        .onChange(of: currentPage?.type) { _, _ in
            DispatchQueue.main.async { applyToolState() }
        }
        #endif
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background || newPhase == .inactive {
                saveCurrentPage()
            }
        }
        #if targetEnvironment(macCatalyst) || canImport(UIKit)
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            // Dismiss before loading the image data. Leaving the picker
            // presented across the async load is what made it briefly snap
            // back to full screen before closing - it was still the active
            // presentation while the view rebuilt around the new selection.
            showingImagePicker = false
            Task { await importImage(from: newItem) }
        }
        #endif
        .toolbar {
#if targetEnvironment(macCatalyst) || canImport(UIKit)
            ToolbarItem(placement: .principal) {
                if !sortedPages.isEmpty {
                    Text("Page \(currentPageIndex + 1) of \(sortedPages.count)")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }

            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    enterPresentationMode()
                } label: {
                    Image(systemName: "play.rectangle")
                }

                Button {
                    showingPageStrip.toggle()
                } label: {
                    Image(systemName: "rectangle.grid.1x2")
                }

                Menu {
                    Section("New Page") {
                        Button("Blank") { addPage(type: "paged", template: "blank") }
                        Button("Lined") { addPage(type: "paged", template: "lined") }
                        Button("Grid") { addPage(type: "paged", template: "grid") }
                        Button("Dotted") { addPage(type: "paged", template: "dotted") }
                        Button("Whiteboard") { addPage(type: "whiteboard", template: "blank") }
                    }
                    if currentPage?.type != "whiteboard" {
                        Section("Add to Page") {
                            Button("Text Box") { addTextBlock() }
                            Button("Sticker") { showingStickerPicker = true }
                            Button("Link") { addLink() }
                        }
                    }
                    Section("Import") {
                        // Backgrounds only render on paged pages, so
                        // "onto this page" doesn't apply to a whiteboard.
                        if currentPage?.type != "whiteboard" {
                            Button("PDF onto This Page") {
                                importTarget = .currentPage
                                showingPDFImporter = true
                            }
                            Button("Photo onto This Page") {
                                importTarget = .currentPage
                                showingImagePicker = true
                            }
                        }
                        Button("PDF as New Pages") {
                            importTarget = .newPages
                            showingPDFImporter = true
                        }
                        Button("Photo as New Page") {
                            importTarget = .newPages
                            showingImagePicker = true
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }

                Menu {
                    Button("Save Now") {
                        saveCurrentPage()
                        showSaveConfirmation()
                    }
                    Section("Export This Page") {
                        Button("Save to Photos") { exportPageToPhotos() }
                        Button("Export as PDF") { exportPageAsPDF() }
                    }
                    Section("Export Notebook") {
                        Button("Export All Pages as PDF") { exportNotebookAsPDF() }
                    }
                } label: {
                    Text("Save")
                }
            }
#else
            // Simplified menu for macOS native placeholder
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button("Placeholder - Feature not available on native macOS") {}
                } label: {
                    Label("Menu", systemImage: "ellipsis.circle")
                }
            }
#endif
        }
        #if targetEnvironment(macCatalyst) || canImport(UIKit)
        .sheet(isPresented: $showingStickerPicker) {
            StickerPickerView { symbol in addSticker(symbol) }
        }
        .sheet(item: $linkNeedingDestination) { link in
            LinkDestinationPickerView(pages: sortedPages) { destinationID in
                link.destinationPageID = destinationID
                saveCurrentPage()
            }
        }
        .fileImporter(isPresented: $showingPDFImporter, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result {
                importPDF(from: url)
            }
        }
        .photosPicker(isPresented: $showingImagePicker, selection: $selectedPhotoItem, matching: .images)
        .sheet(item: $pdfExportURL) { export in
            ShareSheet(items: [export.url])
        }
        .alert("Export", isPresented: Binding(
            get: { exportMessage != nil },
            set: { if !$0 { exportMessage = nil } }
        )) {
            Button("OK") { exportMessage = nil }
        } message: {
            Text(exportMessage ?? "")
        }
        #endif
        #if targetEnvironment(macCatalyst) || canImport(UIKit)
        .alert(
            "Delete this page?",
            isPresented: Binding(get: { pageToDelete != nil }, set: { if !$0 { pageToDelete = nil } })
        ) {
            Button("Cancel", role: .cancel) { pageToDelete = nil }
            Button("Delete", role: .destructive) {
                if let page = pageToDelete {
                    deletePage(page)
                }
                pageToDelete = nil
            }
        } message: {
            Text("This will permanently delete this page and everything on it.")
        }
        #endif
    }

    @ViewBuilder
    private func canvasSection(for page: Page) -> some View {
        if page.type == "whiteboard" {
#if targetEnvironment(macCatalyst) || canImport(UIKit)
            WhiteboardCanvasView(
                canvasView: $canvasView,
                onDrawingChanged: scheduleAutosave,
                onPencilDoubleTap: togglePencilEraser
            )
#else
            // Placeholder for macOS native
            Text("Whiteboard view not available on native macOS")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.gray.opacity(0.2))
#endif
        } else {
            pagedCanvas(for: page)
        }
    }

    /// A paged page, drawn as an actual page: a fixed-proportion sheet
    /// (`PageGeometry`) centred on the desk with the whole thing visible,
    /// which is what stops a portrait PDF template from being a narrow strip
    /// stranded in the middle of a landscape-shaped canvas. Pinch to zoom in
    /// past the fit, one finger to pan.
    ///
    /// Everything that isn't ink - paper/PDF background, text blocks,
    /// stickers, links, placement handles - is laid out in the page's own
    /// coordinates and pushed through the canvas's live pan/zoom by
    /// `PageViewportLayer`, so all of it stays registered with the ink at
    /// every scale.
    @ViewBuilder
    private func pagedCanvas(for page: Page) -> some View {
#if targetEnvironment(macCatalyst) || canImport(UIKit)
        let pageSize = PageGeometry.contentSize(for: page)

        ZStack {
            // The desk the sheet sits on. No .ignoresSafeArea() - this
            // ZStack has to stay inside the area the VStack gave it, or it
            // grows under the navigation bar and shoves the page-thumbnail
            // strip off the bottom of the screen.
            Color(uiColor: .systemGray4)

            PageViewportLayer(viewport: viewport, pageSize: pageSize) { _ in
                ZStack {
                    if page.backgroundRef != nil {
                        ImportedPageBackgroundView(page: page, liveFrame: adjustingImageFrame)
                    } else {
                        PageBackgroundView(template: page.template)
                    }
                }
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
            }

            PencilCanvasView(
                canvasView: $canvasView,
                pageSize: pageSize,
                pageIdentity: page.id,
                viewport: viewport,
                // The placement handles want the same two fingers the pinch
                // does; while artwork is being placed, the page holds still.
                isZoomEnabled: adjustingImageFrame == nil,
                onDrawingChanged: scheduleAutosave,
                onLongPress: { beginAdjustingImage(on: page) },
                onPencilDoubleTap: togglePencilEraser
            )

            PageViewportLayer(viewport: viewport, pageSize: pageSize) { scale in
                PageElementsOverlayView(
                    page: page,
                    scale: scale,
                    onNavigateToPage: { id in jumpToPage(withID: id) },
                    onSave: scheduleAutosave,
                    onRequestLinkDestinationChange: { link in linkNeedingDestination = link }
                )
            }

            if isShapeModeArmed && !isPresenting {
                // Captured in canvas coordinates and converted to page
                // coordinates on the way in, so a shape drawn while zoomed
                // lands where it was drawn.
                ShapeDrawingOverlay { points in
                    addRecognizedShape(from: points.map(viewport.pagePoint(from:)))
                }
            }

            if toolState.activeKind == .fill && !isPresenting {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                performFill(at: viewport.pagePoint(from: value.location), on: page)
                            }
                    )
            }

            if adjustingImageFrame != nil {
                PageViewportLayer(viewport: viewport, pageSize: pageSize) { scale in
                    ZStack(alignment: .topLeading) {
                        if let crop = croppingRect, let frame = adjustingImageFrame {
                            ImageCropOverlay(
                                artworkRect: frame,
                                cropRect: Binding(
                                    get: { crop },
                                    set: { croppingRect = $0 }
                                ),
                                scale: scale
                            )
                        } else {
                            ImageAdjustOverlay(
                                frame: Binding(
                                    get: { adjustingImageFrame ?? CGRect(origin: .zero, size: pageSize) },
                                    set: { adjustingImageFrame = $0 }
                                ),
                                containerSize: pageSize,
                                scale: scale,
                                onDone: { finishAdjustingImage(on: page) }
                            )
                        }
                    }
                }

                // The image toolbar is chrome, so it stays put in screen
                // space rather than riding the page's zoom.
                ImageAdjustToolbar(
                    isCropping: croppingRect != nil,
                    onRotate: { rotateImage(on: page) },
                    onToggleCrop: { toggleCropMode() },
                    onRemove: { removeImage(from: page) },
                    onDone: {
                        if croppingRect != nil {
                            applyCrop(on: page)
                        } else {
                            finishAdjustingImage(on: page)
                        }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 8)
            }
        }
        .clipped()
#else
        // Placeholder for macOS native
        Rectangle()
            .fill(Color.blue.opacity(0.2))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
#endif
    }

    private var pageStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(sortedPages.enumerated()), id: \.element.id) { index, page in
                    Button {
                        jumpToPage(at: index)
                    } label: {
                        VStack(spacing: 4) {
                            PageThumbnailView(page: page, isSelected: index == currentPageIndex)
                            Text("\(index + 1)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            pageToDelete = page
                        } label: {
                            Label("Delete Page", systemImage: "trash")
                        }
                        .disabled(sortedPages.count <= 1)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.thinMaterial)
    }

    // MARK: - Setup

    private func openFirstPage() {
        if let id = initialPageID,
           let idx = sortedPages.firstIndex(where: { $0.id == id }) {
            currentPageIndex = idx
        } else {
            currentPageIndex = 0
        }
        loadCurrentPageDrawing()
    }

    // MARK: - Page navigation

    private func jumpToPage(at index: Int) {
        guard index != currentPageIndex, sortedPages.indices.contains(index) else { return }
        saveCurrentPage()
        currentPageIndex = index
        loadCurrentPageDrawing()
    }

    private func jumpToPage(withID id: UUID) {
        guard let index = sortedPages.firstIndex(where: { $0.id == id }) else { return }
        jumpToPage(at: index)
    }

    private func addPage(type: String, template: String) {
        saveCurrentPage()

        let newIndex = sortedPages.count
        let page = Page(index: newIndex, type: type, template: template, notebook: notebook)
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
        installFreshCanvas()
    }

    /// Removes a page and everything tied to it: the saved drawing file on
    /// disk, any Links/ImportedDocument records referencing it (neither
    /// cascades automatically — Link stores raw UUIDs, and Page has no
    /// inverse relationship to ImportedDocument), then re-sequences the
    /// remaining pages' index values so they stay contiguous — otherwise a
    /// future new page could end up colliding with an existing index.
    private func deletePage(_ page: Page) {
        guard sortedPages.count > 1 else { return }

        for link in allLinks where link.sourcePageID == page.id || link.destinationPageID == page.id {
            modelContext.delete(link)
        }
        // Work out which imported files this page is the last user of
        // BEFORE deleting its records - a multi-page PDF import shares one
        // file across many pages, so it can only be removed once none of
        // them reference it any more. Skipping this leaked every imported
        // photo permanently.
        let refsHere = Set(allImportedDocuments.filter { $0.page?.id == page.id }.map(\.fileRef))
        let refsElsewhere = Set(allImportedDocuments.filter { $0.page?.id != page.id }.map(\.fileRef))
        let orphanedRefs = refsHere.subtracting(refsElsewhere).filter { !$0.isEmpty }

        for doc in allImportedDocuments where doc.page?.id == page.id {
            modelContext.delete(doc)
        }

        drawingStore.trashDrawing(forPageID: page.id)
        for ref in orphanedRefs {
            drawingStore.trashPayload(named: ref)
        }

        let deletedIndex = sortedPages.firstIndex(where: { $0.id == page.id }) ?? 0

        notebook.pages?.removeAll { $0.id == page.id }
        modelContext.delete(page) // cascades to its TypedTextBlocks/Stickers
        // So sync removes it elsewhere instead of bringing it back from
        // another device's copy. A page edited there *after* this moment
        // survives - the edit is newer than the deletion.
        SyncTombstones.merge([Tombstone(kind: .page, id: page.id, deletedAt: Date())])

        let remaining = sortedPages
        for (newIndex, remainingPage) in remaining.enumerated() where remainingPage.index != newIndex {
            remainingPage.index = newIndex
            remainingPage.markModified()
        }

        notebook.modifiedAt = Date()
        saveMetadata("Failed to delete page")

        // Any placement UI was aimed at the page that just went away.
        adjustingImageFrame = nil
        croppingRect = nil
#if targetEnvironment(macCatalyst) || canImport(UIKit)
        updateCanvasInteractionEnabled()
#endif

        currentPageIndex = min(deletedIndex, max(remaining.count - 1, 0))
        loadCurrentPageDrawing()
    }

    // MARK: - Document import

    // MARK: - Export

    #if targetEnvironment(macCatalyst) || canImport(UIKit)
    private func document(for page: Page) -> ImportedDocument? {
        allImportedDocuments.first { $0.page?.id == page.id }
    }

    private func exportPageToPhotos() {
        guard let page = currentPage else { return }
        // Flush pending ink first so the export matches what's on screen.
        saveCurrentPage()
        let image = PageRenderer.image(for: page, importedDocument: document(for: page))
        Task {
            do {
                try await PageRenderer.saveToPhotos(image)
                exportMessage = "Saved this page to your photo library."
            } catch {
                exportMessage = error.localizedDescription
            }
        }
    }

    private func exportPageAsPDF() {
        guard let page = currentPage else { return }
        saveCurrentPage()
        let data = PageRenderer.pdfData(for: [(page: page, document: document(for: page))])
        presentPDF(data, named: "\(notebook.title) - Page \(currentPageIndex + 1)")
    }

    private func exportNotebookAsPDF() {
        saveCurrentPage()
        let entries = sortedPages.map { (page: $0, document: document(for: $0)) }
        guard !entries.isEmpty else { return }
        let data = PageRenderer.pdfData(for: entries)
        presentPDF(data, named: notebook.title)
    }

    private func presentPDF(_ data: Data, named name: String) {
        do {
            pdfExportURL = PDFExport(url: try PageRenderer.writeTemporaryPDF(data, named: name))
        } catch {
            exportMessage = "Couldn't create the PDF: \(error.localizedDescription)"
        }
    }
    #endif

    /// Opens the move/resize handles for whatever was imported onto this
    /// page. Triggered by the canvas long-press, and automatically right
    /// after importing onto an existing page so it can be placed straight
    /// away rather than always landing full-bleed.
    #if targetEnvironment(macCatalyst) || canImport(UIKit)
    private func beginAdjustingImage(on page: Page) {
        guard adjustingImageFrame == nil, page.backgroundRef != nil else { return }
        let pageSize = PageGeometry.contentSize(for: page)
        let doc = allImportedDocuments.first { $0.page?.id == page.id }
        if let placed = ImportedArtwork.placedRect(
            x: doc?.frameX, y: doc?.frameY, width: doc?.frameWidth, height: doc?.frameHeight,
            in: pageSize
        ) {
            adjustingImageFrame = placed
        } else if let ref = page.backgroundRef {
            // Never adjusted: start from the artwork's actual aspect-fit
            // rect, which is exactly where it's already being rendered - so
            // nothing jumps, and the handles hug the image rather than
            // boxing the whole page.
            adjustingImageFrame = ImportedArtwork.fittedRect(
                fileRef: ref,
                pdfPageIndex: doc?.pdfPageIndex ?? 0,
                in: pageSize
            )
        }
        updateCanvasInteractionEnabled()
    }

    /// Quarter-turn clockwise. The placement frame's aspect is flipped to
    /// match so the artwork doesn't end up stretched by the rotation.
    private func rotateImage(on page: Page) {
        guard let doc = allImportedDocuments.first(where: { $0.page?.id == page.id }) else { return }
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

    private func toggleCropMode() {
        if croppingRect != nil {
            croppingRect = nil                 // cancel, leaving the crop untouched
        } else if let frame = adjustingImageFrame {
            croppingRect = frame               // start from the whole artwork
        }
    }

    /// Composes the new crop with whatever crop is already applied: the
    /// on-screen artwork is the *already cropped* image, so the rect the
    /// user drew is relative to that, not to the original file.
    private func applyCrop(on page: Page) {
        defer { croppingRect = nil }
        guard let frame = adjustingImageFrame,
              let crop = croppingRect,
              frame.width > 0, frame.height > 0,
              let doc = allImportedDocuments.first(where: { $0.page?.id == page.id }) else { return }

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

    private func removeImage(from page: Page) {
        for doc in allImportedDocuments where doc.page?.id == page.id {
            modelContext.delete(doc)
        }
        page.backgroundRef = nil
        adjustingImageFrame = nil
        croppingRect = nil
        updateCanvasInteractionEnabled()
        page.markModified()
        saveMetadata("Failed to remove image")
    }

    private func finishAdjustingImage(on page: Page) {
        defer {
            adjustingImageFrame = nil
            croppingRect = nil
            updateCanvasInteractionEnabled()
        }
        guard let frame = adjustingImageFrame,
              let doc = allImportedDocuments.first(where: { $0.page?.id == page.id }),
              // Stored as fractions of the page so the placement survives a
              // different canvas size and can be reproduced in thumbnails.
              let fractions = ImportedArtwork.fractions(
                  of: frame, in: PageGeometry.contentSize(for: page)
              ) else { return }
        doc.frameX = fractions.x
        doc.frameY = fractions.y
        doc.frameWidth = fractions.width
        doc.frameHeight = fractions.height
        page.markModified()
        saveMetadata("Failed to save image placement")
    }
    #else
    // Not available on native macOS (no PencilKit canvas to place against).
    private func beginAdjustingImage(on page: Page) {}
    private func finishAdjustingImage(on page: Page) {}
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
    private func applyBackground(
        _ storedFilename: String,
        sourceType: String,
        pdfPageIndex: Int,
        to page: Page,
        fullBleed: Bool
    ) -> ImportedDocument {
        for doc in allImportedDocuments where doc.page?.id == page.id {
            modelContext.delete(doc)
        }

        page.backgroundRef = storedFilename
        let importedDoc = ImportedDocument(
            sourceType: sourceType,
            fileRef: storedFilename,
            pdfPageIndex: pdfPageIndex,
            page: page
        )
        if fullBleed,
           let aspect = ImportedArtwork.aspectRatio(fileRef: storedFilename, pdfPageIndex: pdfPageIndex) {
            page.aspectRatio = aspect
            importedDoc.frameX = 0
            importedDoc.frameY = 0
            importedDoc.frameWidth = 1
            importedDoc.frameHeight = 1
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
    private func adoptImportedPageShapeIfNeeded(_ page: Page) {
        guard page.aspectRatio == nil,
              let ref = page.backgroundRef,
              let doc = allImportedDocuments.first(where: { $0.page?.id == page.id }),
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

    private func importPDF(from sourceURL: URL) {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

        guard let document = PDFDocument(url: sourceURL) else {
            print("Could not open PDF at \(sourceURL)")
            return
        }

        let directory = FileStore.baseDirectory()
        let storedFilename = "\(UUID().uuidString).pdf"
        let destinationURL = directory.appendingPathComponent(storedFilename)

        do {
            if let data = document.dataRepresentation() {
                try data.write(to: destinationURL)
            } else {
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            }
        } catch {
            print("Failed to copy imported PDF: \(error)")
            return
        }

        saveCurrentPage()

        if importTarget == .currentPage, let page = currentPage {
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
        installFreshCanvas()
    }

    #if targetEnvironment(macCatalyst) || canImport(UIKit)
    private func importImage(from item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let uiImage = UIImage(data: data),
              let jpegData = uiImage.jpegData(compressionQuality: 0.9) else {
            return
        }

        let directory = FileStore.baseDirectory()
        let storedFilename = "\(UUID().uuidString).jpg"
        let destinationURL = directory.appendingPathComponent(storedFilename)

        do {
            try jpegData.write(to: destinationURL)
        } catch {
            print("Failed to save imported image: \(error)")
            return
        }

        saveCurrentPage()

        if importTarget == .currentPage, let page = currentPage {
            applyBackground(storedFilename, sourceType: "image", pdfPageIndex: 0, to: page, fullBleed: false)
            beginAdjustingImage(on: page)
            selectedPhotoItem = nil
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
        installFreshCanvas()
        selectedPhotoItem = nil
    }
    #else
    // Dummy implementation for macOS native
    private func importImage(from item: PhotosPickerItem) async {
        // Do nothing
    }
    #endif

    // MARK: - Page elements

    private func addTextBlock() {
        guard let page = currentPage else { return }
        let block = TypedTextBlock(content: "", page: page)
        block.frameX = 60
        block.frameY = 60
        modelContext.insert(block)
        if page.textBlocks == nil {
            page.textBlocks = [block]
        } else {
            page.textBlocks?.append(block)
        }
        page.markModified()
        saveMetadata("Failed to save text block")
    }

    private func addSticker(_ symbolName: String) {
        guard let page = currentPage else { return }
        let sticker = Sticker(assetRef: symbolName, page: page)
        sticker.frameX = 100
        sticker.frameY = 100
        modelContext.insert(sticker)
        if page.stickers == nil {
            page.stickers = [sticker]
        } else {
            page.stickers?.append(sticker)
        }
        page.markModified()
        saveMetadata("Failed to save sticker")
    }

    private func addLink() {
        guard let page = currentPage else { return }
        // Placeholder self-referencing destination — immediately prompting
        // the picker below means the user always ends up choosing a real
        // target right away.
        let link = Link(sourcePageID: page.id, destinationPageID: page.id)
        link.anchorX = 40
        link.anchorY = 40
        modelContext.insert(link)
        page.markModified()
        saveMetadata("Failed to save link")
        linkNeedingDestination = link
    }

    // MARK: - Drawing tool

    #if targetEnvironment(macCatalyst) || canImport(UIKit)
    private func applyToolState() {
        canvasView.tool = toolState.pkTool
        updateCanvasInteractionEnabled()
    }

    /// Apple Pencil (Pro) double-tap: jump to the eraser, and on the next
    /// double-tap jump back to whatever tool was in hand. `.onChange(of:
    /// toolState)` pushes the change down to the canvas and the toolbar
    /// highlight follows automatically.
    private func togglePencilEraser() {
        if toolState.activeKind == .eraser {
            toolState.activeKind = toolBeforeEraser ?? .pen
            toolBeforeEraser = nil
        } else {
            toolBeforeEraser = toolState.activeKind
            toolState.activeKind = .eraser
        }
    }

    /// The canvas needs real touches routed to a capture overlay instead
    /// (see canvasSection's fill-tap overlay / ShapeDrawingOverlay) while
    /// either the shape tool is armed or Fill is the active tool.
    private func updateCanvasInteractionEnabled() {
        canvasView.isUserInteractionEnabled =
            !isShapeModeArmed && toolState.activeKind != .fill && adjustingImageFrame == nil
    }

    private func performFill(at point: CGPoint, on page: Page) {
        let drawing = canvasView.drawing
        let size = PageGeometry.contentSize(for: page)
        let color = toolState.fillColor.fixedUIColor
        Task {
            guard let filled = await FillTool.fill(drawing, in: size, at: point, color: color) else { return }
            canvasView.setDrawingUndoably(filled)
            scheduleAutosave()
        }
    }
    #endif

    // MARK: - Shape tool

    /// Presentation mode is meant to be a clean, non-interactive view, but
    /// the shape and fill tools work through transparent gesture-capture
    /// overlays - left armed, those would sit invisibly over the presented
    /// page and turn a stray tap into a drawn shape or a filled region.
    /// Stand them down on the way in.
    private func enterPresentationMode() {
        isShapeModeArmed = false
        adjustingImageFrame = nil
        croppingRect = nil
#if targetEnvironment(macCatalyst) || canImport(UIKit)
        if toolState.activeKind == .fill { toolState.activeKind = .pen }
        updateCanvasInteractionEnabled()
#endif
        isPresenting = true
    }

    private func toggleShapeMode() {
        isShapeModeArmed.toggle()
#if targetEnvironment(macCatalyst) || canImport(UIKit)
        updateCanvasInteractionEnabled()
#endif
    }

    #if targetEnvironment(macCatalyst) || canImport(UIKit)
    private func addRecognizedShape(from points: [CGPoint]) {
        defer {
            isShapeModeArmed = false
            updateCanvasInteractionEnabled()
        }
        let ink = PKInk(.pen, color: toolState.penColor.fixedUIColor)
        guard let stroke = ShapeRecognizer.recognizeStroke(from: points, ink: ink) else { return }
        canvasView.setDrawingUndoably(PKDrawing(strokes: canvasView.drawing.strokes + [stroke]))
        scheduleAutosave()
    }
    #else
    // Dummy implementation for macOS native
    private func addRecognizedShape(from points: [CGPoint]) {
        // Do nothing
    }
    #endif

    // MARK: - Drawing persistence

    private func loadCurrentPageDrawing() {
        guard let page = currentPage else {
            installFreshCanvas()
            return
        }
        // A different page means a different sheet: the canvas refits it, so
        // stand the dependent layers down until it reports back rather than
        // letting them flash at the outgoing page's zoom.
        viewport.reset(for: page.id)
        adoptImportedPageShapeIfNeeded(page)
#if targetEnvironment(macCatalyst) || canImport(UIKit)
        var drawing = PKDrawing()
        if let saved = drawingStore.load(pageID: page.id) {
            drawing = fittingWithinPage(saved, on: page)
        }
        installFreshCanvas(with: drawing)
#else
        installFreshCanvas()
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
    private func installFreshCanvas(with drawing: PKDrawing = PKDrawing()) {
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
    private func fittingWithinPage(_ drawing: PKDrawing, on page: Page) -> PKDrawing {
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

    private func saveCurrentPage() {
        guard let page = currentPage else { return }
#if targetEnvironment(macCatalyst) || canImport(UIKit)
        save(canvasView.drawing, to: page)
#else
        save(to: page)
#endif
    }

#if targetEnvironment(macCatalyst) || canImport(UIKit)
    /// Writes `drawing` to `page`'s file. The page and the drawing are
    /// passed together on purpose: the autosave that fires a second after
    /// a stroke must save the page that stroke was drawn on, even if a
    /// different page has been opened since.
    private func save(_ drawing: PKDrawing, to page: Page) {
        do {
            page.drawingFileRef = try drawingStore.save(drawing, pageID: page.id)
            page.markModified()
            try modelContext.save()
        } catch {
            print("Failed to save drawing: \(error)")
        }
    }
#else
    private func save(to page: Page) {
        page.drawingFileRef = DrawingStore.fileName(for: page.id)
        page.markModified()
        try? modelContext.save()
    }
#endif

    private func scheduleAutosave() {
        refreshUndoRedoState()
        // A stroke changed the canvas, so this page's OCR cache is stale.
        drawingNeedsOCR = true
        guard let pageToIndex = currentPage else { return }
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
            save(canvas.drawing, to: pageToIndex)
#else
            save(to: pageToIndex)
#endif
            // Re-recognize handwriting in the background (skips if the file
            // hasn't changed since the last pass) so search stays up to date.
            if drawingNeedsOCR {
                drawingNeedsOCR = false
                await HandwritingRecognizer.refreshOCR(for: pageToIndex, modelContext: modelContext)
            }
        }
    }

    private func refreshUndoRedoState() {
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

    private func saveMetadata(_ errorMessage: String) {
        do {
            try modelContext.save()
        } catch {
            print("\(errorMessage): \(error)")
        }
    }

    /// Brief "Saved" confirmation so the toolbar Save button gives visible
    /// feedback instead of appearing to do nothing (autosave already covers
    /// the common case, but a manual save should still confirm it happened).
    private func showSaveConfirmation() {
        saveConfirmationTask?.cancel()
        withAnimation { showingSaveConfirmation = true }
        saveConfirmationTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { showingSaveConfirmation = false }
        }
    }
}
