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

    @Environment(\.modelContext) var modelContext
    @Environment(\.scenePhase) var scenePhase

#if targetEnvironment(macCatalyst) || canImport(UIKit)
    /// The canvas for the page on screen. Replaced with a brand-new
    /// `PageCanvasView` every time a page is opened or created - see
    /// installFreshCanvas - so no ink, zoom or undo history can carry over
    /// from one page to the next.
    @State var canvasView: PKCanvasView = PageCanvasView()
    // Seeded from the same Settings-configurable defaults PencilKit's own
    // tool used to start from (AppSettings.initialTool()); this is now the
    // single source of truth for canvasView.tool, replacing PKToolPicker.
    @State var toolState = DrawingToolState(
        penInkType: AppSettings.inkType(for: AppSettings.defaultToolType),
        penColor: Color(hex: AppSettings.defaultInkColorHex),
        penWidth: AppSettings.defaultInkWidth,
        shapeLineStyle: AppSettings.shapeLineStyle
    )
    /// The toolbar's open options popover; a Pencil squeeze sets it.
    @State var openToolOptions: DrawingToolKind?
#else
    // Placeholder for macOS native - PencilKit not available
    @State var canvasView: Any?
#endif

    /// The live pan/zoom of the paged canvas. Not @State: it's a reference
    /// the canvas writes to on every scroll frame, and only the layers that
    /// actually read it (`PageViewportLayer`) re-render when it changes -
    /// putting it in this view's state would re-evaluate this whole body
    /// sixty times a second during a pinch.
    @State var viewport = CanvasViewport()
#if targetEnvironment(macCatalyst) || canImport(UIKit)
    /// The lasso's selection. Ours, not PencilKit's: `PKLassoTool` never
    /// says which strokes it holds, so a pinch could not be put on it.
    /// See `InkSelectionController`.
    @State var inkSelection = InkSelectionController()
#endif

    @State var currentPageIndex: Int = 0
    @State var canUndo = false
    @State var canRedo = false
    @State var autosaveTask: Task<Void, Never>?
    let drawingStore = DrawingStore.live

    // Which page's ink the canvas currently holds, and whether the user has
    // changed it since it was loaded. Every save goes to `canvasPageID`,
    // and only when `canvasIsDirty`. Two real incidents behind this: a
    // page switch used to save the canvas unconditionally, so paging
    // through a notebook whose ink hadn't finished arriving from another
    // device wrote *blank* records over it; and a sync inserting a page
    // under an open notebook shifted `currentPage` without the canvas
    // following, so the next save would have written one page's ink into
    // another's file.
    @State var canvasPageID: UUID?
    @State var canvasIsDirty = false
    /// The modifiedAt our own last save stamped, so the "page changed
    /// under us" reload below can tell a pull from our autosave. Reloading
    /// after every autosave would reinstall the canvas mid-stroke.
    @State var ownSaveDate: Date?
    /// The ink record as the canvas last had it - when it loaded, or when
    /// this device last wrote it. A reload is only for ink that changed
    /// under the canvas (a pull); anything else on the page redraws from
    /// the models by itself.
    @State var loadedInkStamp: InkStamp?
    /// The page strip's visibility and height, persisted (`AppSettings`)
    /// so a strip you hid or dragged bigger stays that way - across page
    /// turns, notebooks, windows and launches.
    @AppStorage(AppSettings.Keys.pageStripVisible) var showingPageStrip = true
    @AppStorage(AppSettings.Keys.pageStripHeight) var pageStripHeight = PageStripMetrics.defaultHeight
    /// The height the current drag started from, and how far it has moved.
    /// The live height is computed from these rather than written straight
    /// to the stored preference - a drag would otherwise write to
    /// `UserDefaults` on every frame.
    @State var pageStripDragStart: CGFloat?
    @State var pageStripDragTranslation: CGFloat = 0

    /// Hold-to-snap: what the stroke in progress will snap to when the
    /// pencil lifts, previewed over the page in the tool's own ink.
    @State var shapePreview: ShapeRecognizer.RecognizedShape?
#if targetEnvironment(macCatalyst) || canImport(UIKit)
    /// The tool that was active before an Apple Pencil double-tap switched to
    /// the eraser, so a second double-tap can switch straight back to it.
    @State var toolBeforeEraser: DrawingToolKind?
#endif
    /// Non-nil while a piece of imported artwork on this page is being
    /// moved or resized; holds its live frame in page coordinates.
    @State var adjustingImageFrame: CGRect?
    /// Which layer of the page's artwork stack those handles are on. A
    /// page can hold several - a PDF page as its paper, photos over it -
    /// so the handles, rotate, crop and remove all act on this one only.
    /// For a page from before `ImportedDocument` existed it is the page's
    /// own id (see `ArtworkLayer.stack`).
    @State var adjustingLayerID: UUID?
    /// Non-nil while cropping that artwork; the crop rect in page
    /// coordinates, always kept inside `adjustingImageFrame`.
    @State var croppingRect: CGRect?
    @State var pageToRename: Page?
    @State var pageTitleText = ""
    /// See `newPageSizeLabel`.
    @State var newPageAspect: Double?
    /// The artwork as it was when the handles opened: one undo step per
    /// session, however many moves, rotations and crops it held.
    @State var adjustingSnapshot: ArtworkSnapshot?
    /// Files a removed picture left unused. Trashed only once the removal
    /// can't be undone - when the page's undo stack goes, on a page turn or
    /// leaving the notebook - so undo never brings back a picture with no
    /// file. Killed before then, the file just stays (invariant 1).
    @State var pendingTrash: Set<String> = []
    @State var showingStickerPicker = false
    @State var showingPageMap = false
    /// VisionKit's document camera; the scan arrives as new pages.
    @State var showingScanner = false
    @State var linkNeedingDestination: Link?

    /// Whether an import lands on the page you're looking at or creates new
    /// page(s) after it. Set by whichever Import menu item was tapped, read
    /// when the picker comes back.
    enum ImportTarget { case newPages, currentPage }
    @State var importTarget: ImportTarget = .newPages

    /// One Files importer for PDFs and images both. There must be exactly
    /// one `.fileImporter` on this view: SwiftUI gives a view a single
    /// document-picker presentation, and with two chained only the last
    /// one ever appears - the PDF importer was dead on the iPad for a day
    /// (Sept 18-19, 2026) because an image importer was added after it.
    /// The menu item decides which types the picker offers; the file's own
    /// header decides which import path it takes.
    @State var showingFileImporter = false
    @State var fileImporterTypes: [UTType] = [.pdf]
    #if targetEnvironment(macCatalyst) || canImport(UIKit)
    @State var showingImagePicker = false
    @State var selectedPhotoItem: PhotosPickerItem?
    #endif

    @State var isPresenting = false
    /// The drawing toolbar lives in the navigation bar's principal slot, on
    /// the row with Play / Pages / + / Save (GoodNotes' layout). That slot
    /// is squeezed to nothing in compact width (Slide Over, a narrow split),
    /// so there the bar falls back to floating over the canvas.
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    var drawingToolbarInNavigationBar: Bool { horizontalSizeClass != .compact }
    /// Delete Page is undoable: the page is hidden, not deleted, until the
    /// deletion can no longer be undone - a turn to any page other than the
    /// one it landed on, leaving the notebook, or another deletion. Then
    /// `PageDeletion` runs. Killed before that, the page is simply still
    /// there, which is the safe side of invariant 1.
    @State var pendingDeletion: (pageID: UUID, landingPageID: UUID?)?
    /// The "Page deleted" banner hides after a few seconds; the deletion
    /// stays undoable with the undo button until it commits.
    @State var showingDeletionBanner = false
    @State var deletionBannerTask: Task<Void, Never>?
    /// The page whose context menu opened the copy sheet; it starts ticked.
    @State var pageToCopy: Page?
    @State var showingSaveConfirmation = false
    @State var saveConfirmationTask: Task<Void, Never>?
    @State var pdfExportURL: PDFExport?
    @State var exportMessage: String?

    /// Identifiable wrapper so a finished PDF can drive a `.sheet(item:)`.
    struct PDFExport: Identifiable {
        let id = UUID()
        let url: URL
    }

    @Query var allLinks: [Link]
    @Query var allImportedDocuments: [ImportedDocument]

    /// Bookmarked or named pages, in page order, with their page numbers.
    var outline: [(number: Int, page: Page)] {
        sortedPages.enumerated()
            .filter { $1.isBookmarked == true || !($1.title ?? "").isEmpty }
            .map { (number: $0 + 1, page: $1) }
    }

    var sortedPages: [Page] {
        (notebook.pages ?? []).filter { $0.id != pendingDeletion?.pageID }.sorted { $0.index < $1.index }
    }

    var currentPage: Page? {
        guard sortedPages.indices.contains(currentPageIndex) else { return nil }
        return sortedPages[currentPageIndex]
    }

    /// Which page is on screen *and* how new it is, watched as one value so
    /// a page turn and a remote edit to the page you're on can be told
    /// apart. See the `.onChange` that reads it.
    struct PageStamp: Equatable {
        var id: UUID?
        var date: Date?
    }

    var currentPageStamp: PageStamp {
        PageStamp(id: currentPage?.id, date: currentPage?.modifiedAt)
    }

    var body: some View {
        mainContent
        .navigationTitle(notebook.title)
        #if targetEnvironment(macCatalyst) || canImport(UIKit)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isPresenting ? .hidden : .visible, for: .navigationBar)
        .statusBarHidden(isPresenting)
        #endif
        .ignoresSafeArea(.all, edges: isPresenting ? .all : [])
        #if targetEnvironment(macCatalyst) || canImport(UIKit)
        .background(ContentPopGate())
        #endif
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
        // Lines up a "[spin]" or "[mode]" freeze in the log with what led to it.
        .onChange(of: toolState.activeKind) { _, kind in AppLog.note("ui", "tool \(kind)") }
        .onChange(of: toolState.shapeLineStyle) { _, style in AppSettings.shapeLineStyle = style }
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
        //
        // And only when the *ink* changed. Every action marks the page
        // modified - resizing a picture, turning a sticker, typing, a
        // bookmark, the paper - and each of those used to reload the page:
        // a fresh canvas, the zoom back to fit, the layers blinking while
        // it refitted, and the undo stack gone (field report, Sept 25,
        // 2026). A pull that brings new ink rewrites the record on disk;
        // nothing else does.
        .onChange(of: currentPageStamp) { oldStamp, newStamp in
            guard oldStamp.id == newStamp.id,
                  let pageID = newStamp.id, pageID == canvasPageID,
                  !canvasIsDirty,
                  newStamp.date != ownSaveDate,
                  InkStamp(of: pageID, in: drawingStore) != loadedInkStamp else { return }
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
                        onAddLink: { addLink() }
                    )
                }
            }

            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Menu {
                    if outline.isEmpty {
                        Text("Bookmark or name a page from the page strip's menu to list it here.")
                    }
                    ForEach(outline, id: \.page.id) { entry in
                        Button {
                            jumpToPage(withID: entry.page.id)
                        } label: {
                            Label("\(entry.number). \(entry.page.title ?? "Page \(entry.number)")",
                                  systemImage: entry.page.isBookmarked == true ? "bookmark.fill" : "text.alignleft")
                        }
                    }
                } label: {
                    Image(systemName: "list.bullet.indent")
                }
                .help("Outline")

                Button { showingPageMap = true } label: {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                }
                .help("Page Map")

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
                        #if canImport(UIKit)
                        if DocumentScannerView.isAvailable {
                            Button("Scan Document") { showingScanner = true }
                        }
                        #endif
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
        .sheet(isPresented: $showingPageMap) {
            NotebookGraphView(pages: sortedPages, links: allLinks) { id in
                showingPageMap = false
                jumpToPage(withID: id)
            }
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
        #if canImport(UIKit)
        .fullScreenCover(isPresented: $showingScanner) {
            DocumentScannerView(onFinish: { images in
                showingScanner = false
                Task {
                    let data = await ScanToPDF.pdf(from: images)
                    guard !data.isEmpty else { return }
                    await importPDF(data: data, target: .newPages)
                }
            }, onCancel: { showingScanner = false })
            .ignoresSafeArea()
        }
        #endif
        .alert("Rename Page", isPresented: Binding(
            get: { pageToRename != nil },
            set: { if !$0 { pageToRename = nil } }
        )) {
            TextField("Title", text: $pageTitleText)
            Button("Cancel", role: .cancel) { pageToRename = nil }
            Button("Save") {
                if let page = pageToRename {
                    let title = pageTitleText.trimmingCharacters(in: .whitespacesAndNewlines)
                    page.title = title.isEmpty ? nil : title
                    page.markModified()
                    saveMetadata("Failed to rename the page")
                }
                pageToRename = nil
            }
        } message: {
            Text("A named page is listed in the notebook's outline.")
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

    /// The screen without its modifiers; `body` adds those.
    var mainContent: some View {
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
                                        onAddLink: { addLink() }
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
                            if pendingDeletion != nil && showingDeletionBanner && !isPresenting {
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
                        .overlay(alignment: .topTrailing) { linkedFromStrip }
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
    }

    @ViewBuilder
    func canvasSection(for page: Page) -> some View {
        if page.type == "whiteboard" {
#if targetEnvironment(macCatalyst) || canImport(UIKit)
            WhiteboardCanvasView(
                canvasView: $canvasView,
                onDrawingChanged: scheduleAutosave,
                onPencilDoubleTap: togglePencilEraser,
                onPencilSqueeze: openColorOptions,
                shapeLineStyle: toolState.shapeLineStyle,
                viewport: viewport,
                inkSelection: inkSelection
            )
            if toolState.activeKind == .lasso && !isPresenting {
                // Same overlay as a paged page, drawn in board coordinates.
                let board = CGSize(width: WhiteboardCanvasView.boardSize, height: WhiteboardCanvasView.boardSize)
                PageViewportLayer(viewport: viewport, pageSize: board) { scale in
                    InkSelectionOverlay(display: inkSelection.display, scale: scale)
                }
                .allowsHitTesting(false)
                if let corners = inkSelection.display.corners, corners.count == 4 {
                    PageViewportLayer(viewport: viewport, pageSize: board) { scale in
                        InkSelectionHandles(corners: corners, scale: scale, controller: inkSelection)
                    }
                }
                if inkSelection.hasSelection {
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
    func pagedCanvas(for page: Page) -> some View {
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
                    // Not with the lasso in hand: a Pencil resting mid-loop
                    // over a photo would open its handles.
                    guard toolState.activeKind != .lasso else { return }
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
                inkSelection: inkSelection,
                onSwipePage: adjustingImageFrame == nil && !inkSelection.hasSelection ? { step in
                    let target = currentPageIndex + step
                    guard sortedPages.indices.contains(target) else { return false }
                    jumpToPage(at: target)
                    return true
                } : nil
            )

            if toolState.activeKind == .lasso && !isPresenting {
                // The loop and the selection box, in page space like the
                // ink they're around.
                PageViewportLayer(viewport: viewport, pageSize: pageSize) { scale in
                    InkSelectionOverlay(display: inkSelection.display, scale: scale)
                }
                .allowsHitTesting(false)

                if let corners = inkSelection.display.corners, corners.count == 4 {
                    PageViewportLayer(viewport: viewport, pageSize: pageSize) { scale in
                        InkSelectionHandles(corners: corners, scale: scale, controller: inkSelection)
                    }
                }

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
                        onLinkTo: { linkSelection() },
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

    /// Pages that link here (M2).
    @ViewBuilder
    var linkedFromStrip: some View {
        if !isPresenting, let page = currentPage {
            LinkedFromStrip(
                sources: LinkedFromStrip.sources(linkingTo: page.id, links: allLinks, pages: sortedPages),
                onSelect: { jumpToPage(withID: $0) })
        }
    }

    /// The page strip, with a grabber along its top edge: drag to resize,
    /// drag below the minimum to put it away, and the toolbar's pages
    /// button brings it back. Both the height and the visibility persist.
    var pageStrip: some View {
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
    var liveStripHeight: CGFloat {
        guard let start = pageStripDragStart else { return PageStripMetrics.clamped(pageStripHeight) }
        return PageStripMetrics.clamped(start - pageStripDragTranslation)
    }

    var pageStripGrabber: some View {
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

    var pageStripContent: some View {
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
                                .overlay(alignment: .topTrailing) {
                                    if page.isBookmarked == true {
                                        Image(systemName: "bookmark.fill")
                                            .font(.caption)
                                            .foregroundStyle(.red)
                                            .offset(x: -4, y: -2)
                                            .accessibilityLabel("Bookmarked")
                                    }
                                }
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
                            page.isBookmarked = !(page.isBookmarked ?? false)
                            page.markModified()
                            saveMetadata("Failed to bookmark the page")
                        } label: {
                            if page.isBookmarked == true {
                                Label("Remove Bookmark", systemImage: "bookmark.slash")
                            } else {
                                Label("Bookmark", systemImage: "bookmark")
                            }
                        }
                        Button {
                            pageToRename = page
                            pageTitleText = page.title ?? ""
                        } label: {
                            Label("Rename Page…", systemImage: "pencil")
                        }
                        if page.type == "paged" {
                            Button {
                                addPage(like: page)
                            } label: {
                                Label("New Page Like This", systemImage: "doc.badge.plus")
                            }
                        }
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
    func togglePageStripSize() {
        withAnimation(.snappy) {
            pageStripHeight = pageStripHeight < PageStripMetrics.maximumHeight - 1
                ? PageStripMetrics.maximumHeight
                : PageStripMetrics.defaultHeight
        }
    }

    // MARK: - Setup

    func openFirstPage() {
        if let id = initialPageID,
           let idx = sortedPages.firstIndex(where: { $0.id == id }) {
            currentPageIndex = idx
        } else {
            currentPageIndex = 0
        }
        loadCurrentPageDrawing()
    }


    // MARK: - Document import





}
