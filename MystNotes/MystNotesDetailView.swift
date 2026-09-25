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
import UniformTypeIdentifiers

/// The actual notebook-editing experience: one page's canvas at a time,
/// a page-thumbnail strip for navigation, a custom drawing toolbar
/// (undo/redo, pen/highlighter/eraser/lasso/fill, text box), hold-to-snap
/// shapes (`ShapeHoldRecognizer`), draggable
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
    /// The toolbar's open options popover; a Pencil squeeze sets it.
    @State private var openToolOptions: DrawingToolKind?
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
#if targetEnvironment(macCatalyst) || canImport(UIKit)
    /// The lasso's selection. Ours, not PencilKit's: `PKLassoTool` never
    /// says which strokes it holds, so a pinch could not be put on it.
    /// See `InkSelectionController`.
    @State private var inkSelection = InkSelectionController()
#endif

    @State private var currentPageIndex: Int = 0
    @State private var canUndo = false
    @State private var canRedo = false
    @State private var autosaveTask: Task<Void, Never>?
    private let drawingStore = DrawingStore.live

    // Which page's ink the canvas currently holds, and whether the user has
    // changed it since it was loaded. Every save goes to `canvasPageID`,
    // and only when `canvasIsDirty`. Two real incidents behind this: a
    // page switch used to save the canvas unconditionally, so paging
    // through a notebook whose ink hadn't finished arriving from another
    // device wrote *blank* records over it; and a sync inserting a page
    // under an open notebook shifted `currentPage` without the canvas
    // following, so the next save would have written one page's ink into
    // another's file.
    @State private var canvasPageID: UUID?
    @State private var canvasIsDirty = false
    /// The modifiedAt our own last save stamped, so the "page changed
    /// under us" reload below can tell a pull from our autosave. Reloading
    /// after every autosave would reinstall the canvas mid-stroke.
    @State private var ownSaveDate: Date?
    /// The page strip's visibility and height, persisted (`AppSettings`)
    /// so a strip you hid or dragged bigger stays that way - across page
    /// turns, notebooks, windows and launches.
    @AppStorage(AppSettings.Keys.pageStripVisible) private var showingPageStrip = true
    @AppStorage(AppSettings.Keys.pageStripHeight) private var pageStripHeight = PageStripMetrics.defaultHeight
    /// The height the current drag started from, and how far it has moved.
    /// The live height is computed from these rather than written straight
    /// to the stored preference - a drag would otherwise write to
    /// `UserDefaults` on every frame.
    @State private var pageStripDragStart: CGFloat?
    @State private var pageStripDragTranslation: CGFloat = 0

    /// Hold-to-snap: what the stroke in progress will snap to when the
    /// pencil lifts, previewed over the page in the tool's own ink.
    @State private var shapePreview: ShapeRecognizer.RecognizedShape?
#if targetEnvironment(macCatalyst) || canImport(UIKit)
    /// The tool that was active before an Apple Pencil double-tap switched to
    /// the eraser, so a second double-tap can switch straight back to it.
    @State private var toolBeforeEraser: DrawingToolKind?
#endif
    /// Non-nil while a piece of imported artwork on this page is being
    /// moved or resized; holds its live frame in page coordinates.
    @State private var adjustingImageFrame: CGRect?
    /// Which layer of the page's artwork stack those handles are on. A
    /// page can hold several - a PDF page as its paper, photos over it -
    /// so the handles, rotate, crop and remove all act on this one only.
    /// For a page from before `ImportedDocument` existed it is the page's
    /// own id (see `ArtworkLayer.stack`).
    @State private var adjustingLayerID: UUID?
    /// Non-nil while cropping that artwork; the crop rect in page
    /// coordinates, always kept inside `adjustingImageFrame`.
    @State private var croppingRect: CGRect?
    /// See `newPageSizeLabel`.
    @State private var newPageAspect: Double?
    /// The artwork as it was when the handles opened: one undo step per
    /// session, however many moves, rotations and crops it held.
    @State private var adjustingSnapshot: ArtworkSnapshot?
    /// Files a removed picture left unused. Trashed only once the removal
    /// can't be undone - when the page's undo stack goes, on a page turn or
    /// leaving the notebook - so undo never brings back a picture with no
    /// file. Killed before then, the file just stays (invariant 1).
    @State private var pendingTrash: Set<String> = []
    @State private var showingStickerPicker = false
    @State private var linkNeedingDestination: Link?

    /// Whether an import lands on the page you're looking at or creates new
    /// page(s) after it. Set by whichever Import menu item was tapped, read
    /// when the picker comes back.
    private enum ImportTarget { case newPages, currentPage }
    @State private var importTarget: ImportTarget = .newPages

    /// One Files importer for PDFs and images both. There must be exactly
    /// one `.fileImporter` on this view: SwiftUI gives a view a single
    /// document-picker presentation, and with two chained only the last
    /// one ever appears - the PDF importer was dead on the iPad for a day
    /// (Sept 18-19, 2026) because an image importer was added after it.
    /// The menu item decides which types the picker offers; the file's own
    /// header decides which import path it takes.
    @State private var showingFileImporter = false
    @State private var fileImporterTypes: [UTType] = [.pdf]
    #if targetEnvironment(macCatalyst) || canImport(UIKit)
    @State private var showingImagePicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    #endif

    @State private var isPresenting = false
    /// The drawing toolbar lives in the navigation bar's principal slot, on
    /// the row with Play / Pages / + / Save (GoodNotes' layout). That slot
    /// is squeezed to nothing in compact width (Slide Over, a narrow split),
    /// so there the bar falls back to floating over the canvas.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var drawingToolbarInNavigationBar: Bool { horizontalSizeClass != .compact }
    /// Delete Page is undoable: the page is hidden, not deleted, until the
    /// deletion can no longer be undone - a turn to any page other than the
    /// one it landed on, leaving the notebook, or another deletion. Then
    /// `PageDeletion` runs. Killed before that, the page is simply still
    /// there, which is the safe side of invariant 1.
    @State private var pendingDeletion: (pageID: UUID, landingPageID: UUID?)?
    /// The page whose context menu opened the copy sheet; it starts ticked.
    @State private var pageToCopy: Page?
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
        (notebook.pages ?? []).filter { $0.id != pendingDeletion?.pageID }.sorted { $0.index < $1.index }
    }

    private var currentPage: Page? {
        guard sortedPages.indices.contains(currentPageIndex) else { return nil }
        return sortedPages[currentPageIndex]
    }

    /// Which page is on screen *and* how new it is, watched as one value so
    /// a page turn and a remote edit to the page you're on can be told
    /// apart. See the `.onChange` that reads it.
    private struct PageStamp: Equatable {
        var id: UUID?
        var date: Date?
    }

    private var currentPageStamp: PageStamp {
        PageStamp(id: currentPage?.id, date: currentPage?.modifiedAt)
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
                            if !drawingToolbarInNavigationBar && !isPresenting && adjustingImageFrame == nil {
                                // GeometryReader gives the bar the canvas
                                // area to clamp its dragging within, which
                                // is also what keeps it from sliding down
                                // underneath the page-thumbnail strip.
                                GeometryReader { geo in
                                    DrawingToolbarView(
                                        style: .floating,
                                        toolState: $toolState,
                                        openPopover: $openToolOptions,
                                        canUndo: canUndo,
                                        canRedo: canRedo,
                                        isFillToolAvailable: page.type != "whiteboard",
                                        isTextBoxAvailable: page.type != "whiteboard",
                                        containerSize: geo.size,
                                        onUndo: { canvasView.undoManager?.undo() },
                                        onRedo: { canvasView.undoManager?.redo() },
                                        onAddTextBox: addTextBlock,
                                        onAddSticker: { showingStickerPicker = true },
                                        onAddLink: addLink
                                    )
                                    .frame(maxWidth: .infinity, alignment: .center)
                                }
                                .padding(.top, 8)
                            }
                        }
                        .overlay(alignment: .bottomTrailing) {
                            // Page position, moved off the navigation bar
                            // to make room for the drawing toolbar there.
                            if !isPresenting && !sortedPages.isEmpty {
                                Text("Page \(currentPageIndex + 1) of \(sortedPages.count)")
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .padding(10)
                                    .allowsHitTesting(false)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if pendingDeletion != nil && !isPresenting {
                                HStack(spacing: 14) {
                                    Text("Page deleted")
                                    Button("Undo", action: undoPendingDeletion)
                                        .fontWeight(.semibold)
                                }
                                .font(.subheadline)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(.ultraThinMaterial, in: Capsule())
                                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                                .padding(.bottom, 12)
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
        .onDisappear {
            commitPendingDeletion()
            commitPendingTrash()
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
                // The one blocking save: the app may be suspended before an
                // asynchronous write would land.
                saveCurrentPage(blocking: true)
                HandwritingIndexer.shared.flush(modelContext: modelContext)
            }
        }
        // A pull can insert or remove pages while this notebook is open,
        // which changes which page sits at `currentPageIndex`. The canvas
        // must follow the page, never the index.
        .onChange(of: currentPage?.id) { _, newID in
            guard newID != canvasPageID else { return }
            saveCurrentPage()
            // The page being left doesn't have to wait out its OCR timer.
            HandwritingIndexer.shared.flush(modelContext: modelContext)
            loadCurrentPageDrawing()
        }
        // A pull that brings a newer version of *this* page changes its
        // modifiedAt. Show it - unless the user has drawn on the canvas
        // since it loaded, in which case their strokes stay and the save
        // decides by date, like any same-page edit.
        //
        // The page id travels with the date on purpose. Watching the date
        // alone couldn't tell "this page just changed" from "a different
        // page is now current", and a page turn changes it either way - so
        // turning to a page that has a date (every imported or edited page
        // does) ran a second loadCurrentPageDrawing() on top of the one the
        // turn had already done, resetting the viewport and installing a
        // second canvas in the middle of the first one's update. Turning to
        // a never-edited page (modifiedAt nil, same as ownSaveDate's nil)
        // stayed quiet, which is why it only ever went wrong coming *back*.
        .onChange(of: currentPageStamp) { oldStamp, newStamp in
            guard oldStamp.id == newStamp.id,
                  newStamp.id == canvasPageID,
                  !canvasIsDirty,
                  newStamp.date != ownSaveDate else { return }
            loadCurrentPageDrawing()
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
                // Hidden while placing an image, as the floating bar is:
                // drawing is disabled during adjust and the image toolbar
                // owns the moment.
                if drawingToolbarInNavigationBar, let page = currentPage, adjustingImageFrame == nil {
                    DrawingToolbarView(
                        style: .inline,
                        toolState: $toolState,
                        openPopover: $openToolOptions,
                        canUndo: canUndo,
                        canRedo: canRedo,
                        isFillToolAvailable: page.type != "whiteboard",
                        isTextBoxAvailable: page.type != "whiteboard",
                        containerSize: .zero,
                        onUndo: { canvasView.undoManager?.undo() },
                        onRedo: { canvasView.undoManager?.redo() },
                        onAddTextBox: addTextBlock,
                        onAddSticker: { showingStickerPicker = true },
                        onAddLink: addLink
                    )
                }
            }

            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    enterPresentationMode()
                } label: {
                    Image(systemName: "play.rectangle")
                }

                Button {
                    withAnimation(.snappy) { showingPageStrip.toggle() }
                } label: {
                    Image(systemName: showingPageStrip ? "rectangle.grid.1x2.fill" : "rectangle.grid.1x2")
                }
                .help(showingPageStrip ? "Hide the page strip" : "Show the page strip")

                Menu {
                    Section {
                        ForEach(PageTemplate.options, id: \.id) { option in
                            Button(option.label) { addPage(type: "paged", template: option.id) }
                        }
                    }
                    Menu("Size: \(newPageSizeLabel)") {
                        Button("Same as This Page") { newPageAspect = nil }
                        ForEach(PageGeometry.sizes, id: \.label) { size in
                            Button(size.label) { newPageAspect = size.aspect }
                        }
                    }
                    Button("Whiteboard") { addPage(type: "whiteboard", template: "blank") }
                } label: {
                    Label("New Page", systemImage: "plus")
                }

                // One importer for PDFs and images both: the file's own
                // header decides the path (see importFile). Stickers,
                // links and text boxes are on the drawing toolbar.
                Menu {
                    // Backgrounds only render on paged pages, so "onto
                    // this page" doesn't apply to a whiteboard.
                    if currentPage?.type != "whiteboard" {
                        Section("Onto This Page") {
                            Button("From Files") {
                                importTarget = .currentPage
                                presentFileImporter(for: [.pdf, .image])
                            }
                            Button("From Photos") {
                                importTarget = .currentPage
                                showingImagePicker = true
                            }
                            Button("Paste Image") { pasteImageFromClipboard() }
                                .disabled(!pasteboardHasImage)
                        }
                    }
                    Section("As New Pages") {
                        Button("From Files") {
                            importTarget = .newPages
                            presentFileImporter(for: [.pdf, .image])
                        }
                        Button("From Photos") {
                            importTarget = .newPages
                            showingImagePicker = true
                        }
                    }
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }

                Menu {
                    Button("Save Now") {
                        saveCurrentPage(force: true)
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
            LinkDestinationPickerView(pages: sortedPages, documentsByPageID: documentsByPageID) { destinationID in
                link.destinationPageID = destinationID
                saveCurrentPage()
            }
        }
        // The only `.fileImporter` on this view - see `showingFileImporter`.
        // Images and PDFs both: the type is decided by the file's own
        // header, so a PDF picked from the image item still imports as a PDF.
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: fileImporterTypes) { result in
            if case .success(let url) = result {
                importFile(from: url)
            }
        }
        .photosPicker(isPresented: $showingImagePicker, selection: $selectedPhotoItem, matching: .images)
        .sheet(item: $pdfExportURL) { export in
            ShareSheet(items: [export.url])
        }
        .sheet(item: $pageToCopy) { page in
            CopyPagesSheet(pages: sortedPages, documentsByPageID: documentsByPageID,
                           initialSelection: page.id, currentNotebookID: notebook.id) { pages, destination in
                Task { await copyPages(pages, to: destination) }
            }
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
        #endif
    }

    @ViewBuilder
    private func canvasSection(for page: Page) -> some View {
        if page.type == "whiteboard" {
#if targetEnvironment(macCatalyst) || canImport(UIKit)
            WhiteboardCanvasView(
                canvasView: $canvasView,
                onDrawingChanged: scheduleAutosave,
                onPencilDoubleTap: togglePencilEraser,
                onPencilSqueeze: openColorOptions,
                shapeLineStyle: toolState.shapeLineStyle
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
                    // Paper first, always. An imported photo is something
                    // placed *on* the page, not a replacement for it - the
                    // old either/or here is why importing an image wiped
                    // the lined/grid/dotted template.
                    PageBackgroundView(template: page.template)
                    if page.backgroundRef != nil || documentsByPageID[page.id] != nil {
                        // Per-page identity: without it the same view is
                        // reused across page turns.
                        ImportedPageBackgroundView(page: page,
                                                   liveFrame: adjustingImageFrame,
                                                   liveLayerID: adjustingLayerID)
                            .id(page.id)
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
                // Same for selected ink: the pinch resizes it instead.
                isZoomEnabled: adjustingImageFrame == nil && !inkSelection.hasSelection,
                onDrawingChanged: scheduleAutosave,
                onLongPress: { location in
                    beginAdjustingImage(on: page, at: viewport.pagePoint(from: location))
                },
                onFillTap: toolState.activeKind == .fill && !isPresenting ? { location in
                    performFill(at: viewport.pagePoint(from: location), on: page)
                } : nil,
                onPencilDoubleTap: togglePencilEraser,
                onPencilSqueeze: openColorOptions,
                onShapePreview: { shapePreview = $0 },
                shapeLineStyle: toolState.shapeLineStyle,
                onPasteImage: { data in importDroppedOrPasted(data, onto: page) },
                inkSelection: inkSelection
            )

            if toolState.activeKind == .lasso && !isPresenting {
                // The loop and the selection box, in page space like the
                // ink they're around.
                PageViewportLayer(viewport: viewport, pageSize: pageSize) { scale in
                    InkSelectionOverlay(display: inkSelection.display, scale: scale)
                }
                .allowsHitTesting(false)

                if inkSelection.hasSelection {
                    // Chrome, so it stays put in screen space.
                    InkSelectionToolbar(
                        canPaste: InkSelectionController.pasteboardHasInk,
                        onCut: { inkSelection.cutSelection() },
                        onCopy: { inkSelection.copySelection() },
                        onPaste: { inkSelection.paste() },
                        onDuplicate: { inkSelection.duplicate() },
                        onDelete: { inkSelection.delete() },
                        onRecolor: { inkSelection.recolor($0.fixedUIColor) },
                        onCopyAsImage: { inkSelection.copySelectionAsImage() },
                        onConvertToText: { convertSelectionToText(on: page) },
                        onDone: { inkSelection.clear() }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 8)
                }
            }

            if let shapePreview {
                // Drawn in page space through the viewport, like the ink it
                // is about to become.
                PageViewportLayer(viewport: viewport, pageSize: pageSize) { _ in
                    ShapePreviewView(shape: shapePreview, tool: toolState.pkTool as? PKInkingTool,
                                     lineStyle: toolState.shapeLineStyle)
                }
                .allowsHitTesting(false)
            }

            PageViewportLayer(viewport: viewport, pageSize: pageSize) { scale in
                PageElementsOverlayView(
                    page: page,
                    scale: scale,
                    onNavigateToPage: { id in jumpToPage(withID: id) },
                    onSave: scheduleAutosave,
                    onRequestLinkDestinationChange: { link in linkNeedingDestination = link }
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
                                    set: {
                                        AppLog.note("adjust", "handles \($0) layer \(adjustingLayerID?.uuidString.prefix(8) ?? "nil")")
                                        adjustingImageFrame = $0
                                    }
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

    /// The page strip, with a grabber along its top edge: drag to resize,
    /// drag below the minimum to put it away, and the toolbar's pages
    /// button brings it back. Both the height and the visibility persist.
    private var pageStrip: some View {
        VStack(spacing: 0) {
            pageStripGrabber
            pageStripContent
        }
        .frame(height: liveStripHeight)
        .background(.thinMaterial)
        .transition(.move(edge: .bottom))
    }

    /// What the strip is actually this tall right now: the stored height,
    /// or the in-progress drag.
    private var liveStripHeight: CGFloat {
        guard let start = pageStripDragStart else { return PageStripMetrics.clamped(pageStripHeight) }
        return PageStripMetrics.clamped(start - pageStripDragTranslation)
    }

    private var pageStripGrabber: some View {
        // A capsule, like every other resizable drawer on the platform.
        Capsule()
            .fill(Color.secondary.opacity(pageStripDragStart == nil ? 0.35 : 0.7))
            .frame(width: 40, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: PageStripMetrics.grabberHeight)
            // The whole bar is the grab area, not just the 5pt capsule.
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if pageStripDragStart == nil {
                            pageStripDragStart = PageStripMetrics.clamped(pageStripHeight)
                        }
                        // Up is negative in screen coordinates, and up means
                        // a taller strip.
                        pageStripDragTranslation = value.translation.height
                    }
                    .onEnded { value in
                        let start = pageStripDragStart ?? PageStripMetrics.clamped(pageStripHeight)
                        let dragged = start - value.translation.height
                        pageStripHeight = PageStripMetrics.clamped(dragged)
                        pageStripDragStart = nil
                        pageStripDragTranslation = 0
                        // Dragged well below the minimum: put it away rather
                        // than leaving a strip too short to read. The height
                        // is kept at the minimum, so bringing it back gives
                        // a usable strip.
                        if dragged < PageStripMetrics.minimumHeight - 24 {
                            withAnimation(.snappy) { showingPageStrip = false }
                        }
                    }
            )
            .onTapGesture(count: 2) { togglePageStripSize() }
            .accessibilityLabel("Resize the page strip")
            .accessibilityHint("Drag up for larger previews, down to hide")
            .accessibilityAdjustableAction { direction in
                let step: CGFloat = 40
                pageStripHeight = PageStripMetrics.clamped(
                    pageStripHeight + (direction == .increment ? step : -step)
                )
            }
    }

    private var pageStripContent: some View {
        // Lazy, emphatically: a plain HStack builds every page's thumbnail
        // the moment the notebook opens, and each one decodes that page's
        // ink record and rasterizes its background. A 200-page notebook did
        // all 200 before showing anything.
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                let documents = documentsByPageID
                let thumbnailHeight = PageStripMetrics.thumbnailHeight(for: liveStripHeight)
                // Mid-drag the cells scale the bitmap they have; the
                // re-render at the new size happens once, on release.
                let renderHeight = PageStripMetrics.thumbnailHeight(for: PageStripMetrics.clamped(pageStripHeight))
                ForEach(Array(sortedPages.enumerated()), id: \.element.id) { index, page in
                    Button {
                        jumpToPage(at: index)
                    } label: {
                        VStack(spacing: 4) {
                            PageThumbnailView(page: page,
                                              importedDocuments: documents[page.id] ?? [],
                                              isSelected: index == currentPageIndex,
                                              height: thumbnailHeight,
                                              renderHeight: renderHeight)
                            Text("\(index + 1)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    // Hold and drag to reorder; hold and release still
                    // opens the menu. The payload is the page id as text,
                    // which nothing else in the app accepts on a drop.
                    .draggable(page.id.uuidString)
                    .dropDestination(for: String.self) { items, _ in
                        guard let raw = items.first, let id = UUID(uuidString: raw) else { return false }
                        movePage(withID: id, to: index)
                        return true
                    }
                    .contextMenu {
                        Button {
                            pageToCopy = page
                        } label: {
                            Label("Copy to Notebook…", systemImage: "doc.on.doc")
                        }
                        if page.type == "paged" {
                            Menu("Paper") {
                                ForEach(PageTemplate.options, id: \.id) { option in
                                    Button {
                                        page.template = option.id
                                        page.markModified()
                                        saveMetadata("Failed to change the paper")
                                    } label: {
                                        if page.template == option.id {
                                            Label(option.label, systemImage: "checkmark")
                                        } else {
                                            Text(option.label)
                                        }
                                    }
                                }
                            }
                        }
                        #if targetEnvironment(macCatalyst) || canImport(UIKit)
                        if artwork(for: page).first?.isPaper == true {
                            Button {
                                rotatePage(page)
                            } label: {
                                Label("Rotate Page", systemImage: "rotate.right")
                            }
                            Button {
                                cropPage(page)
                            } label: {
                                Label("Crop Page", systemImage: "crop")
                            }
                        }
                        #endif
                        Button(role: .destructive) {
                            requestDeletePage(page)
                        } label: {
                            Label("Delete Page", systemImage: "trash")
                        }
                        .disabled(sortedPages.count <= 1)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    /// Double-tapping the grabber jumps between the size you had and a big
    /// one, the way a double-click on a window edge does - so "let me
    /// actually see these pages" is one gesture, not a drag.
    private func togglePageStripSize() {
        withAnimation(.snappy) {
            pageStripHeight = pageStripHeight < PageStripMetrics.maximumHeight - 1
                ? PageStripMetrics.maximumHeight
                : PageStripMetrics.defaultHeight
        }
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

    /// Puts the page at `targetIndex` and re-sequences the rest, keeping
    /// the open page open. Every page whose index changed is marked
    /// modified, so the new order syncs.
    private func movePage(withID id: UUID, to targetIndex: Int) {
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

    /// The shape the next New Page takes: a size picked from the menu, or
    /// nil for the shape of the page you're on - so a landscape notebook,
    /// or one continuing a PDF, keeps going in that shape.
    private var newPageSizeLabel: String {
        guard let aspect = newPageAspect else { return "Same as This Page" }
        return PageGeometry.sizes.first { abs($0.aspect - aspect) < 0.0001 }?.label ?? "Custom"
    }

    private func addPage(type: String, template: String) {
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
    private func copyPages(_ pages: [Page], to destination: Notebook) async {
        saveCurrentPage()
        var index = (destination.pages ?? []).count
        for source in pages {
            let page = Page(index: index, type: source.type, template: source.template, notebook: destination)
            page.backgroundRef = source.backgroundRef
            page.aspectRatio = source.aspectRatio
            page.recognizedTextCache = source.recognizedTextCache
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
    private func requestDeletePage(_ page: Page) {
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
    }

    private func undoPendingDeletion() {
        guard let pending = pendingDeletion else { return }
        pendingDeletion = nil
        guard let index = sortedPages.firstIndex(where: { $0.id == pending.pageID }) else { return }
        saveCurrentPage()
        currentPageIndex = index
        loadCurrentPageDrawing()
    }

    /// The pending page is already out of `sortedPages`, so deleting it for
    /// real moves no other page's position and the open page stays open.
    private func commitPendingDeletion() {
        guard let pending = pendingDeletion else { return }
        pendingDeletion = nil
        guard let page = notebook.pages?.first(where: { $0.id == pending.pageID }) else { return }
        PageDeletion.delete(page, from: notebook, in: modelContext, drawingStore: drawingStore)
        saveMetadata("Failed to delete page")
    }

    // MARK: - Document import

    // MARK: - Export

    #if targetEnvironment(macCatalyst) || canImport(UIKit)
    /// The page's artwork stack, bottom first, as values for a renderer.
    private func artwork(for page: Page) -> [ArtworkLayer] {
        ArtworkLayer.stack(for: page, stacked: documentsByPageID)
    }

    /// The page's artwork stack as the documents themselves, for editing.
    private func documents(on page: Page) -> [ImportedDocument] {
        ImportedDocument.stack(on: page.id, in: allImportedDocuments)
    }

    /// `ImportedDocument` has no inverse relationship from `Page`, so the
    /// mapping is built here once per update rather than scanned once per
    /// page - the page strip asks for every page in the notebook.
    private var documentsByPageID: [UUID: [ImportedDocument]] {
        ImportedDocument.stacksByPage(allImportedDocuments)
    }

    private func exportPageToPhotos() {
        guard let page = currentPage else { return }
        // Flush pending ink first so the export matches what's on screen.
        saveCurrentPage()
        let image = PageRenderer.image(for: page, artwork: artwork(for: page))
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
        let data = PageRenderer.pdfData(for: [(page: page, artwork: artwork(for: page))])
        presentPDF(data, named: "\(notebook.title) - Page \(currentPageIndex + 1)")
    }

    private func exportNotebookAsPDF() {
        saveCurrentPage()
        let entries = sortedPages.map { (page: $0, artwork: artwork(for: $0)) }
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

    /// Opens the move/resize handles on the picture under a long-press:
    /// the topmost one under the finger, or none - never the PDF that is
    /// the page (`ImportedArtwork.layerToAdjust`).
    #if targetEnvironment(macCatalyst) || canImport(UIKit)
    private func beginAdjustingImage(on page: Page, at point: CGPoint) {
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
    private func rotatePage(_ page: Page, clockwise: Bool = true) {
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
    private func cropPage(_ page: Page) {
        guard let paper = artwork(for: page).first, paper.isPaper else { return }
        jumpToPage(withID: page.id)
        beginAdjustingImage(on: page, layerID: paper.id)
        toggleCropMode()
    }

    /// Opens the handles on one layer. Used right after importing onto an
    /// existing page too, so a photo can be placed straight away rather
    /// than always landing aspect-fit in the middle.
    private func beginAdjustingImage(on page: Page, layerID: UUID) {
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
    private func adjustingDocument(on page: Page) -> ImportedDocument? {
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
    private func rotateImage(on page: Page) {
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
    private func removeImage(from page: Page) {
        defer { endAdjusting() }
        guard let doc = adjustingDocument(on: page) else { return }
        changeArtwork(doc.id, on: page, from: adjustingSnapshot ?? ArtworkSnapshot(doc), to: nil)
    }

    /// Moves one piece of artwork from `old` to `new` (nil: not there) and
    /// registers the way back on the page's undo stack; undoing registers
    /// the way forward again, which is redo.
    private func changeArtwork(_ id: UUID, on page: Page, from old: ArtworkSnapshot?, to new: ArtworkSnapshot?) {
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

    private func commitPendingTrash() {
        for ref in pendingTrash where !allImportedDocuments.contains(where: { $0.fileRef == ref }) {
            drawingStore.trashPayload(named: ref)
        }
        pendingTrash = []
    }

    private func endAdjusting() {
        adjustingImageFrame = nil
        adjustingLayerID = nil
        adjustingSnapshot = nil
        croppingRect = nil
        updateCanvasInteractionEnabled()
    }

    private func finishAdjustingImage(on page: Page) {
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
        AppLog.note("adjust", "done \(doc.id.uuidString.prefix(8)) frame \(frame) fractions \(fractions)")
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
    private func beginAdjustingImage(on page: Page, at point: CGPoint) {}
    private func beginAdjustingImage(on page: Page, layerID: UUID) {}
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
    private func adoptImportedPageShapeIfNeeded(_ page: Page) {
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
    nonisolated private static func writeImport(_ data: Data, extension ext: String) async -> String? {
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
    private func presentFileImporter(for types: [UTType]) {
        fileImporterTypes = types
        showingFileImporter = true
    }

    /// The PDF import proper. Takes bytes rather than a URL so a PDF that
    /// was pasted or dragged in goes down exactly the same path as one
    /// picked from Files.
    private func importPDF(data: Data, target: ImportTarget) async {
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
    private func importImage(data: Data, target: ImportTarget) async {
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

    private func importImage(from item: PhotosPickerItem) async {
        defer { selectedPhotoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        await importImage(data: data, target: importTarget)
    }

    /// A file chosen in the Files/Finder importer. Images and PDFs both
    /// arrive here, and the sniffed type decides which way they go - so
    /// picking a PDF from the image importer still does the right thing.
    private func importFile(from url: URL) {
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
    private var pasteboardHasImage: Bool { CanvasPasteboard.hasImage }

    /// The menu route to the same thing ⌘V does. The keyboard route goes
    /// through the responder chain instead (`CanvasHostView.paste`), which
    /// is the only way to get the system Edit menu's own Paste item to
    /// reach the canvas.
    private func pasteImageFromClipboard() {
        guard let data = CanvasPasteboard.payload() else {
            exportMessage = "There's no image on the clipboard."
            return
        }
        Task { await importImage(data: data, target: .currentPage) }
    }

    /// ⌘V, or a picture dragged onto the page from Finder / Files / another
    /// app. Always lands on the page you're looking at - that's where you
    /// dropped it.
    private func importDroppedOrPasted(_ data: Data, onto page: Page) {
        guard !isPresenting else { return }
        Task { await importImage(data: data, target: .currentPage) }
    }

    #else
    // Dummy implementation for macOS native
    private func importImage(from item: PhotosPickerItem) async {
        // Do nothing
    }
    #endif

    // MARK: - Page elements

    /// Lasso → Convert to Text: the selection's handwriting, read by the
    /// same Vision pipeline search uses, becomes a text box where the ink
    /// was, and the ink goes - one undo step that brings the ink back and
    /// takes the box away.
    private func convertSelectionToText(on page: Page) {
        guard let selection = inkSelection.selectedStrokes else { return }
        let canvas = canvasView
        Task {
            let recognized = await HandwritingRecognizer.text(in: PKDrawing(strokes: selection.strokes), separator: "\n")
            guard canvasView === canvas else { return }
            guard let text = recognized?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                exportMessage = "Couldn't read any handwriting in the selection."
                return
            }
            canvas.undoManager?.beginUndoGrouping()
            defer {
                canvas.undoManager?.endUndoGrouping()
                refreshUndoRedoState()
            }
            guard inkSelection.delete(exactly: selection.strokes) else { return }
            let lines = max(text.split(separator: "\n").count, 1)
            var block = TextBlockSnapshot(id: UUID(), content: text)
            block.frame = CGRect(x: selection.bounds.minX - 6, y: selection.bounds.minY - 6,
                                 width: max(selection.bounds.width + 12, 120), height: selection.bounds.height + 12)
            block.fontSize = min(max(Double(selection.bounds.height) / Double(lines) * 0.6, 12), 48)
            setTextBlock(block, present: true, on: page)
        }
    }

    /// Adds or removes one text box and registers the opposite on the
    /// page's undo stack (so undo registers redo).
    private func setTextBlock(_ snapshot: TextBlockSnapshot, present: Bool, on page: Page) {
        if present {
            let block = TypedTextBlock(content: snapshot.content, page: page)
            block.id = snapshot.id
            (block.frameX, block.frameY) = (snapshot.frame.minX, snapshot.frame.minY)
            (block.frameWidth, block.frameHeight) = (snapshot.frame.width, snapshot.frame.height)
            block.fontSize = snapshot.fontSize
            modelContext.insert(block)
            page.textBlocks = (page.textBlocks ?? []) + [block]
        } else if let block = page.textBlocks?.first(where: { $0.id == snapshot.id }) {
            page.textBlocks?.removeAll { $0.id == snapshot.id }
            modelContext.delete(block)
        }
        page.markModified()
        saveMetadata("Failed to save text block")
        let canvas = canvasView
        canvas.undoManager?.registerUndo(withTarget: canvas) { _ in
            setTextBlock(snapshot, present: !present, on: page)
        }
    }

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
        // Named in the log so a stall while switching tools or colours
        // says so - see MainThreadWatchdog.
        MainThreadWatchdog.checkpoint("DetailView.applyToolState")
        canvasView.tool = toolState.pkTool
        // Our lasso, not PencilKit's: with it active the canvas stops
        // inking and the Pencil draws a loop instead. Paged pages only -
        // the whiteboard has its own host with none of our recognizers
        // on it, so it keeps PencilKit's lasso (select and move, no
        // resize) for now.
        let usesOurLasso = currentPage?.type != "whiteboard"
        inkSelection.canvas = usesOurLasso ? canvasView : nil
        inkSelection.onDrawingChanged = scheduleAutosave
        inkSelection.isActive = usesOurLasso && toolState.activeKind == .lasso
        // Neither our lasso nor the fill leaves ink: the Pencil draws a
        // loop or taps. Written here, from both, so neither undoes the
        // other when switching straight from one to the other.
        let inks = !inkSelection.isActive && toolState.activeKind != .fill
        if canvasView.drawingGestureRecognizer.isEnabled != inks {
            canvasView.drawingGestureRecognizer.isEnabled = inks
        }
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

    /// Apple Pencil Pro squeeze: open the colour options of the tool in
    /// hand. The eraser and lasso have no colour, so the pen's open then.
    private func openColorOptions() {
        let kind = toolState.activeKind
        openToolOptions = [.pen, .highlighter, .fill].contains(kind) ? kind : .pen
    }

    /// Image handles take the touches while an image is being adjusted.
    private func updateCanvasInteractionEnabled() {
        canvasView.isUserInteractionEnabled = adjustingImageFrame == nil
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

    // MARK: - Presentation

    /// Presentation mode is meant to be a clean, non-interactive view, but
    /// the fill tool acts on a tap - left armed, a stray tap on the
    /// presented page would fill a region. Stand it down on the way in.
    private func enterPresentationMode() {
        shapePreview = nil
        adjustingImageFrame = nil
        adjustingLayerID = nil
        croppingRect = nil
#if targetEnvironment(macCatalyst) || canImport(UIKit)
        if toolState.activeKind == .fill { toolState.activeKind = .pen }
        updateCanvasInteractionEnabled()
#endif
        isPresenting = true
    }

    // MARK: - Drawing persistence

    private func loadCurrentPageDrawing() {
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
    private func installFreshCanvas(with drawing: PKDrawing = PKDrawing(), forPageID pageID: UUID?) {
        // The outgoing canvas takes its undo stack with it.
        commitPendingTrash()
        if let pending = pendingDeletion, pending.landingPageID != pageID { commitPendingDeletion() }
        canvasPageID = pageID
        canvasIsDirty = false
        ownSaveDate = nil
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

    /// Saves the canvas to the page it was loaded for - if the user changed
    /// it. A canvas nobody drew on is never written: it may be blank only
    /// because its ink hasn't arrived yet, and writing it would replace
    /// that ink with nothing.
    /// `blocking` is for the one case that can't be asynchronous: the app
    /// is going to the background and may be suspended before a background
    /// write would land (invariant 1). Everywhere else the write goes off
    /// the main thread.
    private func saveCurrentPage(force: Bool = false, blocking: Bool = false) {
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
    private func save(_ drawing: PKDrawing, to page: Page) async {
        switch await DrawingStore.saveDetached(drawingStore, drawing, pageID: page.id).value {
        case .success(let ref):
            page.drawingFileRef = ref
            page.markModified()
            if page.id == canvasPageID { ownSaveDate = page.modifiedAt }
            do { try modelContext.save() } catch { AppLog.note("save", "metadata: \(error)") }
        case .failure(let error):
            AppLog.note("save", "drawing: \(error)")
            // The ink is still in the canvas and still dirty as far as the
            // next autosave is concerned, so it gets another go.
            if page.id == canvasPageID { canvasIsDirty = true }
        }
    }

    /// The same save, run here and now. Only for backgrounding.
    private func saveBlocking(_ drawing: PKDrawing, to page: Page) {
        do {
            page.drawingFileRef = try drawingStore.save(drawing, pageID: page.id)
            page.markModified()
            if page.id == canvasPageID { ownSaveDate = page.modifiedAt }
            try modelContext.save()
        } catch {
            AppLog.note("save", "drawing (blocking): \(error)")
            if page.id == canvasPageID { canvasIsDirty = true }
        }
    }
#else
    private func save(to page: Page) {
        page.drawingFileRef = DrawingStore.fileName(for: page.id)
        page.markModified()
        if page.id == canvasPageID { ownSaveDate = page.modifiedAt }
        try? modelContext.save()
    }
#endif

    private func scheduleAutosave() {
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
