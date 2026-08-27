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
/// a page-thumbnail strip for navigation, undo/redo, the shape tool,
/// draggable text/sticker/link elements, PDF/image import, and a
/// distraction-free presentation mode. Elements/shapes/imports only apply
/// to regular paged pages — whiteboard pages keep plain PencilKit drawing
/// (their scroll/zoom coordinate space needs extra math to position
/// overlays correctly, a reasonable follow-up rather than folding into
/// this already-large set of phases).
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
    @State private var toolPicker = PKToolPicker()
    @State private var excalidrawController = ExcalidrawController()
#else
    // Placeholder for macOS native - PencilKit not available
    @State private var canvasView: Any?
    @State private var toolPicker: Any?
    @State private var excalidrawController: Any?
#endif

    @State private var currentPageIndex: Int = 0
    @State private var canUndo = false
    @State private var canRedo = false
    @State private var autosaveTask: Task<Void, Never>?
    // Serializes save/load across page switches so an in-flight Excalidraw
    // JS export (async, unlike PencilKit's instant in-memory read) can never
    // race a subsequent loadScene into the same shared WKWebView.
    @State private var canvasTransitionTask: Task<Void, Never>?
    @State private var drawingNeedsOCR = false
    @State private var showingPageStrip = true

    @State private var isShapeModeArmed = false
    @State private var showingStickerPicker = false
    @State private var linkNeedingDestination: Link?

    @State private var showingPDFImporter = false
    #if targetEnvironment(macCatalyst) || canImport(UIKit)
    @State private var showingImagePicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    #endif

    @State private var isPresenting = false
    @State private var pageToDelete: Page?

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
            // canvasView/toolPicker mounted exactly once, always.
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
        .onAppear(perform: openFirstPage)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background || newPhase == .inactive {
                // Once saveCurrentPage() awaits an Excalidraw JS round-trip,
                // iOS can suspend mid-await before it finishes; a background
                // task buys the extra time to finish the export+write first.
                // (PencilKit's save is pure synchronous disk I/O and never
                // needed this.)
                #if targetEnvironment(macCatalyst) || canImport(UIKit)
                var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
                backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "SaveCurrentPage") {
                    UIApplication.shared.endBackgroundTask(backgroundTaskID)
                }
                runCanvasTransition {
                    await saveCurrentPage()
                    if backgroundTaskID != .invalid {
                        UIApplication.shared.endBackgroundTask(backgroundTaskID)
                    }
                }
                #else
                runCanvasTransition { await saveCurrentPage() }
                #endif
            }
        }
        #if targetEnvironment(macCatalyst) || canImport(UIKit)
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task { await importImage(from: newItem) }
        }
        #endif
        .toolbar {
#if targetEnvironment(macCatalyst) || canImport(UIKit)
            ToolbarItemGroup(placement: .navigationBarLeading) {
                // Excalidraw has its own in-canvas undo stack (Cmd/Ctrl+Z)
                // this toolbar button doesn't reach - disable rather than
                // bridge into the webview's JS undo stack (v1 limitation).
                Button {
                    canvasView.undoManager?.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!canUndo || currentPage?.type == "excalidraw")

                Button {
                    canvasView.undoManager?.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!canRedo || currentPage?.type == "excalidraw")
            }
#else
            // For macOS native, we use automatic placement for toolbar items
            ToolbarItem(placement: .automatic) {
                Button {
#if targetEnvironment(macCatalyst) || canImport(UIKit)
                    canvasView.undoManager?.undo()
#endif
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!canUndo)
            }
            ToolbarItem(placement: .automatic) {
                Button {
#if targetEnvironment(macCatalyst) || canImport(UIKit)
                    canvasView.undoManager?.redo()
#endif
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!canRedo)
            }
#endif

            ToolbarItem(placement: .principal) {
                if !sortedPages.isEmpty {
                    Text("Page \(currentPageIndex + 1) of \(sortedPages.count)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

#if targetEnvironment(macCatalyst) || canImport(UIKit)
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

                Button {
                    toggleShapeMode()
                } label: {
                    Image(systemName: "square.on.circle")
                }
                .foregroundStyle(isShapeModeArmed ? Color.accentColor : Color.primary)
                .disabled(currentPage?.type == "whiteboard" || currentPage?.type == "excalidraw")

                Menu {
                    Section("New Page") {
                        Button("Excalidraw Board") { addPage(type: "excalidraw", template: "blank") }
                        Button("Blank") { addPage(type: "paged", template: "blank") }
                        Button("Lined") { addPage(type: "paged", template: "lined") }
                        Button("Grid") { addPage(type: "paged", template: "grid") }
                        Button("Dotted") { addPage(type: "paged", template: "dotted") }
                        Button("Whiteboard") { addPage(type: "whiteboard", template: "blank") }
                    }
                    if currentPage?.type != "whiteboard" && currentPage?.type != "excalidraw" {
                        Section("Add to Page") {
                            Button("Text Box") { addTextBlock() }
                            Button("Sticker") { showingStickerPicker = true }
                            Button("Link") { addLink() }
                        }
                    }
                    Section("Import") {
                        Button("Import PDF") { showingPDFImporter = true }
                        Button("Import Photo") { showingImagePicker = true }
                    }
                } label: {
                    Image(systemName: "plus")
                }

                Button("Save") {
                    runCanvasTransition { await saveCurrentPage() }
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
                runCanvasTransition { await saveCurrentPage() }
            }
        }
        .fileImporter(isPresented: $showingPDFImporter, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result {
                importPDF(from: url)
            }
        }
        .photosPicker(isPresented: $showingImagePicker, selection: $selectedPhotoItem, matching: .images)
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
                    toolPicker: toolPicker,
                    onDrawingChanged: scheduleAutosave
                )
#else
                // Placeholder for macOS native
                Text("Whiteboard view not available on native macOS")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.gray.opacity(0.2))
#endif
            } else if page.type == "excalidraw" {
#if targetEnvironment(macCatalyst) || canImport(UIKit)
                // Self-contained, like the whiteboard branch: Excalidraw
                // manages its own canvas/elements/shape-tools inside the
                // webview, so none of PageBackgroundView/
                // PageElementsOverlayView/ShapeDrawingOverlay apply here.
                ExcalidrawCanvasView(
                    controller: excalidrawController,
                    onSceneChanged: scheduleAutosave
                )
#else
                // Placeholder for macOS native
                Text("Excalidraw view not available on native macOS")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.gray.opacity(0.2))
#endif
            } else {
                ZStack {
                    if page.backgroundRef != nil {
                        ImportedPageBackgroundView(page: page)
                    } else {
                        PageBackgroundView(template: page.template)
                    }
#if targetEnvironment(macCatalyst) || canImport(UIKit)
                    PencilCanvasView(
                        canvasView: $canvasView,
                        toolPicker: toolPicker,
                        onDrawingChanged: scheduleAutosave
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
        runCanvasTransition { await loadCurrentPageDrawing() }
    }

    // MARK: - Page navigation

    private func jumpToPage(at index: Int) {
        guard index != currentPageIndex, sortedPages.indices.contains(index) else { return }
        runCanvasTransition {
            await saveCurrentPage()
            currentPageIndex = index
            await loadCurrentPageDrawing()
        }
    }

    private func jumpToPage(withID id: UUID) {
        guard let index = sortedPages.firstIndex(where: { $0.id == id }) else { return }
        jumpToPage(at: index)
    }

    private func addPage(type: String, template: String) {
        runCanvasTransition {
            await saveCurrentPage()

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
            // A brand-new page has nothing saved yet, so skip the disk
            // round-trip both engines' load paths would otherwise do.
            if type == "excalidraw" {
                await excalidrawController.loadScene(ExcalidrawController.emptyScene)
            } else {
                canvasView.drawing = PKDrawing()
            }
#endif
            refreshUndoRedoState()
        }
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
        runCanvasTransition { await loadCurrentPageDrawing() }
    }

    // MARK: - Document import

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

        runCanvasTransition {
            await saveCurrentPage()

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

        runCanvasTransition {
            await saveCurrentPage()

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

    // MARK: - Shape tool

    private func toggleShapeMode() {
        isShapeModeArmed.toggle()
#if targetEnvironment(macCatalyst) || canImport(UIKit)
        canvasView.isUserInteractionEnabled = !isShapeModeArmed
#endif
    }

    #if targetEnvironment(macCatalyst) || canImport(UIKit)
    private func addRecognizedShape(from points: [CGPoint]) {
        defer {
            isShapeModeArmed = false
            canvasView.isUserInteractionEnabled = true
        }
        if let inkingTool = canvasView.tool as? PKInkingTool {
            let ink = PKInk(.pen, color: inkingTool.color)
            guard let stroke = ShapeRecognizer.recognizeStroke(from: points, ink: ink) else { return }
            canvasView.drawing = PKDrawing(strokes: canvasView.drawing.strokes + [stroke])
        } else {
            // Fallback to black if tool is not an inking tool
            let ink = PKInk(.pen, color: .black)
            guard let stroke = ShapeRecognizer.recognizeStroke(from: points, ink: ink) else { return }
            canvasView.drawing = PKDrawing(strokes: canvasView.drawing.strokes + [stroke])
        }
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

    private func excalidrawSceneURL(for page: Page) -> URL {
        FileStore.baseDirectory().appendingPathComponent("\(page.id.uuidString).excalidraw.json")
    }

    private func excalidrawThumbnailURL(for page: Page) -> URL {
        FileStore.baseDirectory().appendingPathComponent("\(page.id.uuidString).excalidraw.png")
    }

    /// Serializes every save/load through one chain so an in-flight
    /// Excalidraw JS export (async, unlike PencilKit's instant in-memory
    /// read) can never race a subsequent loadScene into the same shared
    /// WKWebView - each new operation waits for the previous one to finish.
    private func runCanvasTransition(_ operation: @escaping () async -> Void) {
        let previous = canvasTransitionTask
        canvasTransitionTask = Task {
            await previous?.value
            await operation()
        }
    }

    private func loadCurrentPageDrawing() async {
        guard let page = currentPage else {
#if targetEnvironment(macCatalyst) || canImport(UIKit)
            canvasView.drawing = PKDrawing()
#endif
            return
        }

#if targetEnvironment(macCatalyst) || canImport(UIKit)
        if page.type == "excalidraw" {
            let url = excalidrawSceneURL(for: page)
            let json = (try? String(contentsOf: url, encoding: .utf8)) ?? ExcalidrawController.emptyScene
            await excalidrawController.loadScene(json)
            refreshUndoRedoState()
            return
        }
#endif

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

    private func saveCurrentPage() async {
        guard let page = currentPage else { return }

#if targetEnvironment(macCatalyst) || canImport(UIKit)
        if page.type == "excalidraw" {
            guard let json = await excalidrawController.exportSceneJSON() else { return }
            let url = excalidrawSceneURL(for: page)
            do {
                try json.write(to: url, atomically: true, encoding: .utf8)
                page.drawingFileRef = url.lastPathComponent

                // Excalidraw's own text elements give exact strings for
                // free, but a page can just as easily be freehand ink drawn
                // with its pen tool - that's only searchable by OCR'ing the
                // rendered canvas, same as PencilKit pages are.
                let typedText = await excalidrawController.exportPlainText()
                var searchableParts = [String]()
                if let typedText, !typedText.isEmpty {
                    searchableParts.append(typedText)
                }

                let thumbnail = await excalidrawController.snapshotThumbnail()
                if let thumbnail, let pngData = thumbnail.pngData() {
                    try? pngData.write(to: excalidrawThumbnailURL(for: page))
                }
                if let cgImage = thumbnail?.cgImage,
                   let inkText = await HandwritingRecognizer.ocrText(from: cgImage) {
                    searchableParts.append(inkText)
                }

                page.recognizedTextCache = searchableParts.isEmpty ? nil : searchableParts.joined(separator: "\n")

                notebook.modifiedAt = Date()
                try modelContext.save()
            } catch {
                print("Failed to save Excalidraw scene: \(error)")
            }
            return
        }
#endif

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
            runCanvasTransition {
                await saveCurrentPage()
                // Re-recognize handwriting in the background (skips if the
                // file hasn't changed since the last pass) so search stays
                // up to date. Excalidraw pages populate recognizedTextCache
                // directly above instead - OCR doesn't apply to them.
                if drawingNeedsOCR, let pageToIndex, pageToIndex.type != "excalidraw" {
                    drawingNeedsOCR = false
                    await HandwritingRecognizer.refreshOCR(for: pageToIndex, modelContext: modelContext)
                }
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
}