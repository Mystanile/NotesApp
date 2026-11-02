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

    /// When non-nil (a search result with a query), a lens shows where the
    /// match is once the page has opened; see `SearchHighlightLens`.
    let highlight: SearchHighlight?

    /// When true, the Page Map sheet opens once after the notebook appears
    /// (the Library Map opens a notebook this way).
    let initialShowsPageMap: Bool

    init(notebook: Notebook, initialPageID: UUID? = nil, highlight: SearchHighlight? = nil,
         initialShowsPageMap: Bool = false) {
        self.notebook = notebook
        self.initialPageID = initialPageID
        self.highlight = highlight
        self.initialShowsPageMap = initialShowsPageMap
    }

    @State private var didOpenInitialPageMap = false

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
    /// The page sidebar's visibility and width, persisted (`AppSettings`)
    /// so a strip you hid or dragged bigger stays that way - across page
    /// turns, notebooks, windows and launches.
    @AppStorage(AppSettings.Keys.pageStripVisible) var showingPageStrip = true
    /// Observed here so toggling "Draw with finger" reaches the open page.
    @AppStorage(AppSettings.Keys.fingerDrawing) var fingerDrawing = false
    @AppStorage(AppSettings.Keys.pageSidebarWidth) var pageSidebarWidth = PageSidebarMetrics.defaultWidth
    /// In compact width the sidebar overlays the canvas and starts closed
    /// on every open of a notebook, whatever the preference says.
    @State var compactSidebarOpen = false
    /// The width the current drag started from, and how far it has moved.
    /// The live width is computed from these rather than written straight
    /// to the stored preference - a drag would otherwise write to
    /// `UserDefaults` on every frame.
    @State var pageSidebarDragStart: CGFloat?
    @State var pageSidebarDragTranslation: CGFloat = 0

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
    @State var pageToTag: Page?
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
    /// The Study panel (AI helper): an inspector in regular width, a sheet
    /// in compact. The button is only there while the helper is switched on.
    @State var showingStudyPanel = false
    @AppStorage(AppSettings.Keys.aiEnabled) var aiEnabled = false
    /// VisionKit's document camera; the scan arrives as new pages.
    @State var showingScanner = false
    @State var linkNeedingDestination: Link?
    /// Make Node: the draft the name alert is about, and its text field.
    @State var nodeDraft: NodeDraft?
    @State var nodeTitleText = ""
    /// Rename Node (from a badge).
    @State var nodeToRename: Link?
    @State var renameNodeText = ""
    /// Nodes on this notebook whose ink is gone (derived, never stored).
    @State var goneNodeIDs: Set<UUID> = []
    /// Per node page: the record the verdict was reached on, and the verdict.
    @State var goneCache: [UUID: NodeInk.PageResult] = [:]
    /// This notebook's nodes, recomputed on change only (`refreshNodeCache`).
    @State var nodeCache: [Link] = []
    /// The Connections card's data, recomputed on change only.
    @State var connections = ConnectionsPanel.Snapshot()
    /// A per-viewer convenience only.
    @AppStorage("connectionsPanelExpanded") var connectionsExpanded = false

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
    /// Present mode's laser pointer: a fading trail, nothing drawn or saved.
    @State var laserPointerOn = false
    @State var showingGoToPage = false
    @State var goToPageText = ""
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
    /// The Page Grid, and the pages it asked to copy (several at once).
    @State var showingPageGrid = false
    @State var pagesToCopy: [Page] = []
    @State var showingCopyPagesFromGrid = false
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
    @Query(sort: \Notebook.title) var allNotebooks: [Notebook]
    /// A link to a page of another notebook opens that notebook here.
    @State var otherNotebookTarget: SearchResult?
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
        .overlay { searchHighlightOverlay }
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
            SearchIndexer.shared.notebookOpened()
            openFirstPage()
            applyToolState()
            if initialShowsPageMap, !didOpenInitialPageMap {
                didOpenInitialPageMap = true
                Task { @MainActor in showingPageMap = true }
            }
        }
        .onDisappear {
            SearchIndexer.shared.notebookClosed()
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
                    drawingToolbar(page: page, style: .inline, containerSize: .zero)
                }
            }

            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if aiEnabled {
                    Button { showingStudyPanel.toggle() } label: {
                        Image(systemName: "sparkles")
                    }
                    .accessibilityLabel("Study")
                    .help("Study this page or notebook with AI")
                }

                Button { showingPageMap = true } label: {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                }
                .accessibilityLabel("Page Map")
                .help("Page Map")

                Button {
                    togglePageSidebar()
                } label: {
                    Image(systemName: "sidebar.left")
                        .symbolVariant(pageSidebarVisible ? .fill : .none)
                }
                .accessibilityLabel("Pages")
                .help(pageSidebarVisible ? "Hide the page sidebar" : "Show the page sidebar")

                Button { showingPageGrid = true } label: {
                    Image(systemName: "square.grid.2x2")
                }
                .accessibilityLabel("All Pages")
                .help("All Pages")

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
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share")

                Menu {
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
                        Label("Outline", systemImage: "list.bullet.indent")
                    }
                    Button {
                        enterPresentationMode()
                    } label: {
                        Label("Present", systemImage: "play.rectangle")
                    }
                    Button {
                        promptGoToPage()
                    } label: {
                        Label("Go to Page…", systemImage: "arrow.right.doc.on.clipboard")
                    }
                    .keyboardShortcut("g", modifiers: .command)
                    .disabled(isPresenting || sortedPages.count < 2)
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
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
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
        .sheet(isPresented: $showingPageGrid) {
            PageGridView(pages: sortedPages, documentsByPageID: documentsByPageID,
                         currentPageID: currentPage?.id,
                         onOpen: { id in jumpToPage(withID: id) },
                         onDelete: { ids in deletePages(withIDs: ids) },
                         onDuplicate: { ids in duplicatePages(withIDs: ids) },
                         onCopyTo: { ids in
                             pagesToCopy = sortedPages.filter { ids.contains($0.id) }
                             showingCopyPagesFromGrid = true
                         },
                         onExport: { ids in exportPagesAsPDF(withIDs: ids) },
                         onMove: { id, target in movePage(withID: id, to: target) })
        }
        .sheet(isPresented: $showingCopyPagesFromGrid) {
            if !pagesToCopy.isEmpty {
                CopyPagesSheet(pages: pagesToCopy, documentsByPageID: documentsByPageID,
                               initialSelections: Set(pagesToCopy.map(\.id)), currentNotebookID: notebook.id) { pages, destination in
                    Task { await copyPages(pages, to: destination) }
                }
            }
        }
        .sheet(isPresented: $showingPageMap) {
            NotebookGraphView(pages: sortedPages, links: allLinks,
                              positions: notebook.graphPositions,
                              onMove: { id, point in
                                  notebook.setGraphPosition(point, forPageID: id)
                                  saveMetadata("Failed to save the Page Map")
                              },
                              goneNodeIDs: goneNodeIDs,
                              documents: documentsByPageID,
                              foreignPages: foreignPagesForPageMap()) { id in
                showingPageMap = false
                jumpToPage(withID: id)
            }
        }
        #if targetEnvironment(macCatalyst) || canImport(UIKit)
        .inspector(isPresented: Binding(
            get: { showingStudyPanel && aiEnabled && !isCompactWidth },
            set: { showingStudyPanel = $0 }
        )) {
            studyPanel.inspectorColumnWidth(min: 320, ideal: 380, max: 480)
        }
        .sheet(isPresented: Binding(
            get: { showingStudyPanel && aiEnabled && isCompactWidth },
            set: { showingStudyPanel = $0 }
        )) {
            studyPanel.presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingStickerPicker) {
            StickerPickerView { symbol in addSticker(symbol) }
        }
        .navigationDestination(item: $otherNotebookTarget) { target in
            NotebookDetailView(notebook: target.notebook, initialPageID: target.pageID)
        }
        .sheet(item: $linkNeedingDestination, onDismiss: removeUnfinishedLinks) { link in
            LinkDestinationPickerView(pages: sortedPages, documentsByPageID: documentsByPageID,
                                      notebooks: allNotebooks, links: allLinks,
                                      currentNotebookID: notebook.id) { destinationID, nodeID in
                if let nodeID, let node = allLinks.first(where: { $0.id == nodeID }) {
                    Links.setDestination(link, toNode: node, in: modelContext)
                } else {
                    Links.setDestination(link, toPage: destinationID, in: modelContext)
                }
            }
        }
        // The only `.fileImporter` on this view - see `showingFileImporter`.
        // Images and PDFs both: the type is decided by the file's own
        // header, so a PDF picked from the image item still imports as a PDF.
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: fileImporterTypes,
                      allowsMultipleSelection: importTarget == .newPages) { result in
            if case .success(let urls) = result {
                importFiles(from: urls)
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
                    await importPDF(data: data, target: importTarget)
                }
            }, onCancel: { showingScanner = false })
            .ignoresSafeArea()
        }
        #endif
        .sheet(item: $pageToTag) { page in
            PageTagsSheet(tags: page.tags ?? []) { tags in
                page.setTags(tags)
                saveMetadata("Failed to save the tags")
                pageToTag = nil
            }
            .presentationDetents([.medium])
        }
        .alert("Go to Page", isPresented: $showingGoToPage) {
            TextField("Page number", text: $goToPageText)
                #if targetEnvironment(macCatalyst) || canImport(UIKit)
                .keyboardType(.numberPad)
                #endif
            Button("Cancel", role: .cancel) {}
            Button("Go") { commitGoToPage() }
        } message: {
            Text("Enter a number from 1 to \(sortedPages.count).")
        }
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
        .alert("Make Node", isPresented: Binding(
            get: { nodeDraft != nil },
            set: { if !$0 { nodeDraft = nil } }
        )) {
            TextField("Name", text: $nodeTitleText)
            Button("Cancel", role: .cancel) { nodeDraft = nil }
            Button("Make") { commitNodeDraft() }
        } message: {
            Text("A named piece of ink you can link to from anywhere.")
        }
        .alert("Rename Node", isPresented: Binding(
            get: { nodeToRename != nil },
            set: { if !$0 { nodeToRename = nil } }
        )) {
            TextField("Name", text: $renameNodeText)
            Button("Cancel", role: .cancel) { nodeToRename = nil }
            Button("Save") { commitRenameNode() }
        }
        .onChange(of: nodeSetKey, initial: true) { refreshNodeCache() }
        .task(id: goneNodesKey) { await refreshGoneNodes() }
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

    /// Where the selection toolbar goes: top centre, or bottom centre when
    /// the selection's top (plus the handles' hit area) is in the band the
    /// toolbar would cover - the page can't pan while ink is selected, so
    /// otherwise those handles are unreachable. One place for both canvases.
    /// A view of its own, so only it reads the viewport (as
    /// `PageViewportLayer` does), not the whole detail view.
    static func placeInkToolbar<V: View>(_ bar: V, corners: [CGPoint]?, viewport: CanvasViewport) -> some View {
        InkToolbarPlacement(bar: bar, corners: corners, viewport: viewport)
    }

    /// The screen without its modifiers; `body` adds those.
    var mainContent: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 0) {
                if let page = currentPage {
                    if pageSidebarVisible && !isCompactWidth && !isPresenting {
                        pageSidebar
                    }
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
                            // Also hidden while ink is selected: in compact width
                            // it sits exactly over the selection toolbar.
                            // Done brings it back.
                            if !drawingToolbarInNavigationBar && !isPresenting && adjustingImageFrame == nil
                                && !inkSelection.hasSelection {
                                // GeometryReader gives the bar the canvas
                                // area to clamp its dragging within, which
                                // is also what keeps it inside the canvas,
                                // clear of the page sidebar.
                                GeometryReader { geo in
                                    drawingToolbar(page: page, style: .floating, containerSize: geo.size)
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
                                    .contentShape(Capsule())
                                    // Tap to jump to a page number (Nov 2, 2026).
                                    .onTapGesture { if sortedPages.count > 1 { promptGoToPage() } }
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityHint("Go to a page")
                                    .padding(10)
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
                        .overlay(alignment: .bottomLeading) { connectionsPanel }
                        .overlay(alignment: .leading) {
                            if pageSidebarVisible && isCompactWidth && !isPresenting {
                                pageSidebar.shadow(color: .black.opacity(0.25), radius: 10, x: 2)
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
            if isPresenting && laserPointerOn {
                // Above the canvas and taking every touch, so nothing can
                // be drawn while it is on. Below the buttons.
                LaserPointerOverlay()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if isPresenting {
                HStack(spacing: 0) {
                    Button {
                        laserPointerOn.toggle()
                    } label: {
                        Label("Laser", systemImage: laserPointerOn ? "circle.fill" : "circle.dotted")
                            .labelStyle(.iconOnly)
                            .font(.title)
                            .foregroundStyle(laserPointerOn ? Color.red : Color.secondary)
                            .padding(.vertical)
                            .padding(.horizontal, Space.s)
                    }
                    .accessibilityLabel("Laser")
                    .accessibilityValue(laserPointerOn ? "On" : "Off")
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
                onShapePreview: { shapePreview = $0 },
                viewport: viewport,
                inkSelection: inkSelection,
                fingerDrawing: fingerDrawing
            )
            if let shapePreview {
                PageViewportLayer(viewport: viewport,
                                  pageSize: CGSize(width: WhiteboardCanvasView.boardSize, height: WhiteboardCanvasView.boardSize)) { _ in
                    ShapePreviewView(shape: shapePreview, tool: toolState.pkTool as? PKInkingTool,
                                     lineStyle: toolState.shapeLineStyle)
                }
                .allowsHitTesting(false)
            }
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
                    Self.placeInkToolbar(InkSelectionToolbar(
                        canPaste: inkSelection.canPaste,
                        onCut: { inkSelection.cutSelection() },
                        onCopy: { inkSelection.copySelection() },
                        onPaste: { inkSelection.paste() },
                        onDuplicate: { inkSelection.duplicate() },
                        onDelete: { inkSelection.delete() },
                        onRecolor: { inkSelection.recolor($0.fixedUIColor) },
                        onCopyAsImage: { inkSelection.copySelectionAsImage() },
                        onConvertToText: { convertSelectionToText(on: page) },
                        onDone: { inkSelection.clear() }
                    ), corners: inkSelection.display.corners, viewport: viewport)
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
                } : nil,
                fingerDrawing: fingerDrawing,
                isRulerActive: toolState.rulerActive
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
                    Self.placeInkToolbar(InkSelectionToolbar(
                        canPaste: inkSelection.canPaste,
                        onCut: { inkSelection.cutSelection() },
                        onCopy: { inkSelection.copySelection() },
                        onPaste: { inkSelection.paste() },
                        onDuplicate: { inkSelection.duplicate() },
                        onDelete: { inkSelection.delete() },
                        onRecolor: { inkSelection.recolor($0.fixedUIColor) },
                        onCopyAsImage: { inkSelection.copySelectionAsImage() },
                        onConvertToText: { convertSelectionToText(on: page) },
                        onLinkTo: { linkSelection() },
                        onMakeNode: { beginMakeNode(on: page) },
                        onDone: { inkSelection.clear() }
                    ), corners: inkSelection.display.corners, viewport: viewport)
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
                    onMention: { dest, blockID, label in addMention(from: page, to: dest, blockID: blockID, label: label) },
                    onTextCommit: { block in pruneMentions(of: block, on: page) },
                    onSave: scheduleAutosave,
                    onRequestLinkDestinationChange: { link in linkNeedingDestination = link },
                    onDeleteTextBlock: { block in deleteTextBlock(block, on: page) },
                    goneNodeIDs: goneNodeIDs,
                    onRenameNode: { beginRenameNode($0) },
                    onShowPageMap: { showingPageMap = true },
                    onDeleteNode: { deleteNode($0, on: page) }
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

    /// Only the pages that link to `pageID`, fetched by id: walking every
    /// notebook's pages here would fault the whole library in on each
    /// redraw, and this view redraws on every colour change.
    func pagesLinking(to pageID: UUID) -> [Page] {
        let ids = Self.incomingSourceIDs(to: pageID, links: allLinks)
        guard !ids.isEmpty else { return [] }
        return (try? modelContext.fetch(FetchDescriptor<Page>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
    }

    /// The pages `pageID` links out to (other than itself), fetched by id for
    /// the same reason as `pagesLinking(to:)`.
    func pagesLinked(from pageID: UUID) -> [Page] {
        let ids = Array(Set(allLinks.lazy.filter { $0.sourcePageID == pageID && $0.destinationPageID != pageID }
            .map(\.destinationPageID)))
        guard !ids.isEmpty else { return [] }
        return (try? modelContext.fetch(FetchDescriptor<Page>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
    }

    /// The open page's connections (M2): who links here, where it links to,
    /// and its nodes, in one collapsible card.
    @ViewBuilder
    var connectionsPanel: some View {
        if !isPresenting, currentPage != nil {
            ConnectionsPanel(
                count: connections.count,
                expanded: $connectionsExpanded,
                linkedFrom: connections.linkedFrom,
                linksTo: connections.linksTo,
                nodes: connections.nodes.map { .init(id: $0.id, title: $0.title, isGone: goneNodeIDs.contains($0.id)) },
                onSelectPage: { jumpToPage(withID: $0) },
                onOpenPageMap: { showingPageMap = true })
                .onChange(of: connectionsKey, initial: true) { refreshConnections() }
        }
    }

    /// The page sidebar: a column of thumbnails down the left edge, with a
    /// grabber on its right edge that drags its width. Regular width puts
    /// it beside the canvas (the toolbar's pages button shows/hides it, and
    /// that persists); compact width overlays it on the canvas, closed each
    /// time the notebook opens, and a tap on a page closes it again.
    var pageSidebar: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Button { showingPageGrid = true } label: {
                    Label("All Pages", systemImage: "square.grid.2x2")
                        .font(Typography.label)
                        .frame(maxWidth: .infinity, minHeight: Metrics.minHitTarget)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("All Pages")
                Divider()
                pageSidebarContent
            }
            pageSidebarGrabber
        }
        .frame(width: livePageSidebarWidth)
        .background(.thinMaterial)
        .transition(.move(edge: .leading))
    }

    var isCompactWidth: Bool { horizontalSizeClass == .compact }

    /// Whether the sidebar is up: the persisted preference, or in compact
    /// width the per-open state.
    var pageSidebarVisible: Bool { isCompactWidth ? compactSidebarOpen : showingPageStrip }

    func togglePageSidebar() {
        withAnimation(.snappy) {
            if isCompactWidth { compactSidebarOpen.toggle() } else { showingPageStrip.toggle() }
        }
    }

    /// What the sidebar is actually this wide right now: the stored width,
    /// or the in-progress drag.
    var livePageSidebarWidth: CGFloat {
        guard let start = pageSidebarDragStart else { return PageSidebarMetrics.clamped(pageSidebarWidth) }
        return PageSidebarMetrics.clamped(start + pageSidebarDragTranslation)
    }

    var pageSidebarGrabber: some View {
        Capsule()
            .fill(Color.secondary.opacity(pageSidebarDragStart == nil ? 0.35 : 0.7))
            .frame(width: 5, height: 40)
            .frame(maxHeight: .infinity)
            .frame(width: PageSidebarMetrics.grabberWidth)
            // The whole edge is the grab area, not just the capsule.
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if pageSidebarDragStart == nil {
                            pageSidebarDragStart = PageSidebarMetrics.clamped(pageSidebarWidth)
                        }
                        pageSidebarDragTranslation = value.translation.width
                    }
                    .onEnded { value in
                        let start = pageSidebarDragStart ?? PageSidebarMetrics.clamped(pageSidebarWidth)
                        pageSidebarWidth = PageSidebarMetrics.clamped(start + value.translation.width)
                        pageSidebarDragStart = nil
                        pageSidebarDragTranslation = 0
                    }
            )
            .onTapGesture(count: 2) { togglePageSidebarSize() }
            .accessibilityLabel("Resize the page sidebar")
            .accessibilityHint("Drag right for larger previews")
            .accessibilityAdjustableAction { direction in
                let step: CGFloat = 24
                pageSidebarWidth = PageSidebarMetrics.clamped(
                    pageSidebarWidth + (direction == .increment ? step : -step)
                )
            }
    }

    var pageSidebarContent: some View {
        // Lazy, emphatically: a plain VStack builds every page's thumbnail
        // the moment the notebook opens, and each one decodes that page's
        // ink record and rasterizes its background. A 200-page notebook did
        // all 200 before showing anything. `PageSidebarReorderList` keeps the
        // LazyVStack and owns reordering (see PageSidebarReorder.swift).
        let documents = documentsByPageID
        // Mid-drag the cells scale the bitmap they have; the
        // re-render at the new size happens once, on release.
        let liveWidth = livePageSidebarWidth
        let storedWidth = PageSidebarMetrics.clamped(pageSidebarWidth)
        return PageSidebarReorderList(
            pages: sortedPages,
            currentIndex: currentPageIndex,
            onMove: { id, target in movePage(withID: id, to: target) },
            onInsertAfter: { page in addPage(like: page) },
            scrollToCurrent: { proxy in scrollSidebarToCurrentPage(proxy) },
            cell: { index, page, reordering in
                let aspect = PageGeometry.aspectRatio(page.aspectRatio)
                Button {
                    jumpToPage(at: index)
                    if isCompactWidth { withAnimation(.snappy) { compactSidebarOpen = false } }
                } label: {
                    VStack(spacing: 4) {
                        PageThumbnailView(page: page,
                                          importedDocuments: documents[page.id] ?? [],
                                          isSelected: index == currentPageIndex,
                                          height: PageSidebarMetrics.thumbnailHeight(sidebarWidth: liveWidth, aspect: aspect),
                                          renderHeight: PageSidebarMetrics.thumbnailHeight(sidebarWidth: storedWidth, aspect: aspect))
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
                            .frame(maxWidth: .infinity)
                            .overlay(alignment: .trailing) {
                                // The reorder handle (Reorder mode only).
                                if reordering {
                                    Image(systemName: "line.3.horizontal")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.trailing, 4)
                                        .accessibilityHidden(true)
                                }
                            }
                    }
                }
                .buttonStyle(.plain)
                    // Not `.contextMenu`: a long press now lifts the page
                    // to drag it, and one long press can't be both. The same
                    // items sit behind the cell's ellipsis button.
                    .sidebarCellMenu(isCurrent: index == currentPageIndex) {
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
                        Button {
                            pageToTag = page
                        } label: {
                            Label("Tags…", systemImage: "tag")
                        }
                        if page.type == "paged" {
                            Button {
                                addPage(like: page)
                            } label: {
                                Label("New Page Like This", systemImage: "doc.badge.plus")
                            }
                        }
                        Button {
                            duplicatePage(page)
                        } label: {
                            Label("Duplicate Page", systemImage: "plus.square.on.square")
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
            },
            footer: { addPageMenu })
    }

    /// Keeps the open page in view in the sidebar (deferred a tick so the
    /// lazy stack has laid out).
    func scrollSidebarToCurrentPage(_ proxy: ScrollViewProxy) {
        guard sortedPages.indices.contains(currentPageIndex) else { return }
        let id = sortedPages[currentPageIndex].id
        DispatchQueue.main.async { proxy.scrollTo(id) }
    }

    /// A page after the current one, on the current paper - the same as
    /// the page's own "New Page Like This".
    @ViewBuilder
    var addPageButton: some View {
        Button {
            if let page = currentPage, page.type == "paged" {
                addPage(like: page)
            } else {
                addPage(type: "paged", template: AppSettings.defaultTemplate)
            }
            if isCompactWidth { withAnimation(.snappy) { compactSidebarOpen = false } }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.title3)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.gray.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4])))
                Text("Add page").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add page")
    }

    /// Double-tapping the grabber jumps between the width you had and the
    /// widest, the way a double-click on a window edge does.
    func togglePageSidebarSize() {
        withAnimation(.snappy) {
            pageSidebarWidth = pageSidebarWidth < PageSidebarMetrics.maximumWidth - 1
                ? PageSidebarMetrics.maximumWidth
                : PageSidebarMetrics.defaultWidth
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

private struct InkToolbarPlacement<Bar: View>: View {
    var bar: Bar
    var corners: [CGPoint]?
    var viewport: CanvasViewport

    var body: some View {
        // 8 pt gap + 46 pt toolbar + 19 pt handle hit radius.
        let top = (corners?.map(\.y).min() ?? .infinity) * viewport.zoomScale - viewport.contentOffset.y
        let atBottom = top < 73
        bar
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: atBottom ? .bottom : .top)
            .padding(atBottom ? .bottom : .top, 8)
    }
}
