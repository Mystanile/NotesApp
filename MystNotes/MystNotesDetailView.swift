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
    @State private var canvasView = PKCanvasView()
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

    @State private var currentPageIndex: Int = 0
    @State private var canUndo = false
    @State private var canRedo = false
    @State private var autosaveTask: Task<Void, Never>?
    @State private var drawingNeedsOCR = false
    @State private var showingPageStrip = true

    @State private var isShapeModeArmed = false
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
                    isPresenting = true
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
        Group {
            if page.type == "whiteboard" {
#if targetEnvironment(macCatalyst) || canImport(UIKit)
                WhiteboardCanvasView(
                    canvasView: $canvasView,
                    onDrawingChanged: scheduleAutosave
                )
#else
                // Placeholder for macOS native
                Text("Whiteboard view not available on native macOS")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.gray.opacity(0.2))
#endif
            } else {
                ZStack {
                    if page.backgroundRef != nil {
                        ImportedPageBackgroundView(page: page, liveFrame: adjustingImageFrame)
                    } else {
                        PageBackgroundView(template: page.template)
                    }
#if targetEnvironment(macCatalyst) || canImport(UIKit)
                    PencilCanvasView(
                        canvasView: $canvasView,
                        onDrawingChanged: scheduleAutosave,
                        onLongPress: { beginAdjustingImage(on: page) }
                    )
#else
                    // Placeholder for macOS native
                    Rectangle()
                        .fill(Color.blue.opacity(0.2))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
#endif
                    PageElementsOverlayView(
                        page: page,
                        onNavigateToPage: { id in jumpToPage(withID: id) },
                        onSave: scheduleAutosave,
                        onRequestLinkDestinationChange: { link in linkNeedingDestination = link }
                    )
                    if isShapeModeArmed {
                        ShapeDrawingOverlay { points in
                            addRecognizedShape(from: points)
                        }
                    }
#if targetEnvironment(macCatalyst) || canImport(UIKit)
                    if toolState.activeKind == .fill {
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onEnded { value in
                                        performFill(at: value.location)
                                    }
                            )
                    }
                    if let frame = adjustingImageFrame {
                        GeometryReader { geo in
                            ZStack(alignment: .topLeading) {
                                if let crop = croppingRect {
                                    ImageCropOverlay(
                                        artworkRect: frame,
                                        cropRect: Binding(
                                            get: { crop },
                                            set: { croppingRect = $0 }
                                        )
                                    )
                                } else {
                                    ImageAdjustOverlay(
                                        frame: Binding(
                                            get: { adjustingImageFrame ?? CGRect(origin: .zero, size: geo.size) },
                                            set: { adjustingImageFrame = $0 }
                                        ),
                                        containerSize: geo.size,
                                        onDone: { finishAdjustingImage(on: page) }
                                    )
                                }

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
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 8)
                            }
                        }
                    }
#endif
                }
            }
        }
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
#if targetEnvironment(macCatalyst) || canImport(UIKit)
        canvasView.drawing = PKDrawing()
#endif
        refreshUndoRedoState()
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
        for doc in allImportedDocuments where doc.page?.id == page.id {
            modelContext.delete(doc)
        }

        let url = drawingURL(for: page)
        try? FileManager.default.removeItem(at: url)

        let deletedIndex = sortedPages.firstIndex(where: { $0.id == page.id }) ?? 0

        notebook.pages?.removeAll { $0.id == page.id }
        modelContext.delete(page) // cascades to its TypedTextBlocks/Stickers

        let remaining = sortedPages
        for (newIndex, remainingPage) in remaining.enumerated() {
            remainingPage.index = newIndex
        }

        notebook.modifiedAt = Date()
        saveMetadata("Failed to delete page")

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
        let doc = allImportedDocuments.first { $0.page?.id == page.id }
        if let placed = ImportedArtwork.placedRect(
            x: doc?.frameX, y: doc?.frameY, width: doc?.frameWidth, height: doc?.frameHeight,
            in: canvasView.bounds.size
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
                in: canvasView.bounds.size
            )
        }
        updateCanvasInteractionEnabled()
    }

    /// Quarter-turn clockwise. The placement frame's aspect is flipped to
    /// match so the artwork doesn't end up stretched by the rotation.
    private func rotateImage(on page: Page) {
        guard let doc = allImportedDocuments.first(where: { $0.page?.id == page.id }) else { return }
        doc.rotationDegrees = ((doc.rotationDegrees ?? 0) + 90).truncatingRemainder(dividingBy: 360)
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
        notebook.modifiedAt = Date()
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
        notebook.modifiedAt = Date()
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
        notebook.modifiedAt = Date()
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
              let fractions = ImportedArtwork.fractions(of: frame, in: canvasView.bounds.size) else { return }
        doc.frameX = fractions.x
        doc.frameY = fractions.y
        doc.frameWidth = fractions.width
        doc.frameHeight = fractions.height
        notebook.modifiedAt = Date()
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
    private func applyBackground(_ storedFilename: String, sourceType: String, pdfPageIndex: Int, to page: Page) {
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
        modelContext.insert(importedDoc)

        notebook.modifiedAt = Date()
        saveMetadata("Failed to import onto the current page")
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
            applyBackground(storedFilename, sourceType: "pdf", pdfPageIndex: 0, to: page)
            beginAdjustingImage(on: page)
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

        currentPageIndex = sortedPages.count - document.pageCount
#if targetEnvironment(macCatalyst) || canImport(UIKit)
        canvasView.drawing = PKDrawing()
#endif
        refreshUndoRedoState()
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
            applyBackground(storedFilename, sourceType: "image", pdfPageIndex: 0, to: page)
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
        canvasView.drawing = PKDrawing()
        refreshUndoRedoState()
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
        saveMetadata("Failed to save link")
        linkNeedingDestination = link
    }

    // MARK: - Drawing tool

    #if targetEnvironment(macCatalyst) || canImport(UIKit)
    private func applyToolState() {
        canvasView.tool = toolState.pkTool
        updateCanvasInteractionEnabled()
    }

    /// The canvas needs real touches routed to a capture overlay instead
    /// (see canvasSection's fill-tap overlay / ShapeDrawingOverlay) while
    /// either the shape tool is armed or Fill is the active tool.
    private func updateCanvasInteractionEnabled() {
        canvasView.isUserInteractionEnabled =
            !isShapeModeArmed && toolState.activeKind != .fill && adjustingImageFrame == nil
    }

    private func performFill(at point: CGPoint) {
        let drawing = canvasView.drawing
        let size = canvasView.bounds.size
        let color = toolState.fillColor.fixedUIColor
        Task {
            guard let filled = await FillTool.fill(drawing, in: size, at: point, color: color) else { return }
            canvasView.drawing = filled
            scheduleAutosave()
        }
    }
    #endif

    // MARK: - Shape tool

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
        canvasView.drawing = PKDrawing(strokes: canvasView.drawing.strokes + [stroke])
        scheduleAutosave()
    }
    #else
    // Dummy implementation for macOS native
    private func addRecognizedShape(from points: [CGPoint]) {
        // Do nothing
    }
    #endif

    // MARK: - Drawing persistence

    private func drawingURL(for page: Page) -> URL {
        let directory = FileStore.baseDirectory()
        return directory.appendingPathComponent("\(page.id.uuidString).drawing")
    }

    private func loadCurrentPageDrawing() {
        guard let page = currentPage else {
#if targetEnvironment(macCatalyst) || canImport(UIKit)
            canvasView.drawing = PKDrawing()
#endif
            return
        }
        let url = drawingURL(for: page)
        if let data = try? Data(contentsOf: url) {
#if targetEnvironment(macCatalyst) || canImport(UIKit)
            if let drawing = try? PKDrawing(data: data) {
                canvasView.drawing = drawing
            } else {
                canvasView.drawing = PKDrawing()
            }
#endif
        } else {
#if targetEnvironment(macCatalyst) || canImport(UIKit)
            canvasView.drawing = PKDrawing()
#endif
        }
        refreshUndoRedoState()
    }

    private func saveCurrentPage() {
        guard let page = currentPage else { return }
        let url = drawingURL(for: page)
        do {
#if targetEnvironment(macCatalyst) || canImport(UIKit)
            try canvasView.drawing.dataRepresentation().write(to: url)
#endif
            page.drawingFileRef = url.lastPathComponent
            notebook.modifiedAt = Date()
            try modelContext.save()
        } catch {
            print("Failed to save drawing: \(error)")
        }
    }

    private func scheduleAutosave() {
        refreshUndoRedoState()
        // A stroke changed the canvas, so this page's OCR cache is stale.
        drawingNeedsOCR = true
        let pageToIndex = currentPage
        autosaveTask?.cancel()
        autosaveTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            saveCurrentPage()
            // Re-recognize handwriting in the background (skips if the file
            // hasn't changed since the last pass) so search stays up to date.
            if drawingNeedsOCR, let pageToIndex {
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
