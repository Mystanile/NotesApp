import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Browsable library at a given folder level (nil = top level / "My Library").
/// Recursive: navigating into a subfolder pushes another LibraryView.
struct LibraryView: View {
    let parentFolder: Folder?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow

    // Deliberately unfiltered @Query + in-view filtering rather than a
    // SwiftData #Predicate with a captured optional parent ID — simpler,
    // more reliable, and plenty fast at personal-library scale.
    @Query(sort: \Folder.name) private var allFolders: [Folder]
    @Query(sort: \Notebook.title) private var storedNotebooks: [Notebook]
    @Query private var allImportedDocuments: [ImportedDocument]

    @State private var showingNewFolderAlert = false
    @State private var newFolderName = ""
    /// The New Smart Folder / Edit Search alert. `smartFolderToEdit` is nil
    /// for a new one.
    @State private var showingSmartFolderAlert = false
    @State private var smartFolderToEdit: Folder?
    @State private var smartFolderSearch = ""
    @State private var showingNewNotebookSheet = false
    /// A notebook just created opens once its sheet is gone: a push
    /// during the sheet's dismissal can be dropped.
    @State private var createdNotebook: Notebook?
    @State private var notebookToOpen: Notebook?
    /// The Library Map (M2 task 12). A notebook picked on it opens once the
    /// map's sheet is gone, as with `createdNotebook`.
    @State private var showingMap = false
    @State private var mapPick: Notebook?

    @State private var itemToRename: LibraryItem?
    @State private var renameText = ""

    @State private var itemToMove: LibraryItem?
    @State private var showingMovePicker = false

    @State private var searchText = ""
    @State private var showingSettings = false
    @State private var showingTemplates = false
    @State private var pdfExportURL: PDFExport?
    @State private var exportMessage: String?
    @State private var showingImporter = false

    /// Identifiable wrapper so a finished PDF can drive a `.sheet(item:)`.
    private struct PDFExport: Identifiable {
        let id = UUID()
        let url: URL
    }

    /// Two columns on a phone, five or six on a 13" iPad. The maximum keeps
    /// covers from ballooning in a wide window.
    private let gridColumns = [GridItem(.adaptive(minimum: 148, maximum: 220), spacing: Space.l, alignment: .top)]

    private var folders: [Folder] {
        allFolders.filter { $0.parentFolder?.id == parentFolder?.id }
    }

    /// Every notebook the library lists - the page-templates notebook
    /// (`role == "templates"`) is managed from Page Templates instead.
    private var allNotebooks: [Notebook] {
        PageTemplates.libraryNotebooks(storedNotebooks)
    }

    private var notebooks: [Notebook] {
        allNotebooks.filter { $0.folder?.id == parentFolder?.id }
    }

    /// The most recently touched notebooks across the whole library
    /// (regardless of which folder they live in) — shown as a strip at the
    /// top of the root library so it doesn't open on a blank page.
    /// Starred notebooks, wherever they live, by title.
    private var favoriteNotebooks: [Notebook] {
        allNotebooks.filter { $0.isFavorite == true }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private var pageTags: [PageTags.Tag] {
        PageTags.counts(in: allNotebooks.flatMap { $0.pages ?? [] })
    }

    private var recentNotebooks: [Notebook] {
        allNotebooks
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(8)
            .map { $0 }
    }

    /// Search is a global feature: only active at the root of the library, once
    /// the user has typed a non-empty query. Nested folder levels stay as plain
    /// browsing.
    private var isSearching: Bool {
        parentFolder == nil && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if isSearching {
                SearchResultsView(query: searchText)
                    .navigationTitle("Search")
            } else {
                libraryContent
            }
        }
        .modifier(SearchableModifier(text: $searchText, enabled: parentFolder == nil))
        .sheet(isPresented: $showingSettings) {
            // A stack for Settings' own links (Restore Pages), and a Done
            // for a Mac, where a sheet can't be swiped away.
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingSettings = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showingTemplates) {
            NavigationStack {
                PageTemplatesView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingTemplates = false }
                        }
                    }
            }
        }
        #if targetEnvironment(macCatalyst) || canImport(UIKit)
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
        .task(id: parentFolder?.id) {
            MainThreadWatchdog.checkpoint("LibraryView.task")
            seedTutorialNotebookIfNeeded()
        }
    }

    #if targetEnvironment(macCatalyst) || canImport(UIKit)
    /// Flattens every page of a notebook into one PDF and hands it to the
    /// share sheet. Reuses the same renderer the in-notebook export uses, so
    /// both produce identical pages.
    /// The notebook's words - page names, typed text, recognized
    /// handwriting - as Markdown (`LibraryExport.markdown`).
    /// Exports of a locked notebook ask first, like opening it.
    private func whenOpen(_ notebook: Notebook, _ action: @escaping () -> Void) {
        Task { if await NotebookLock.shared.unlock(notebook) { action() } }
    }

    private func exportNotebookAsMarkdown(_ notebook: Notebook) {
        let name = (notebook.title.isEmpty ? "Notebook" : notebook.title)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).md")
        Task {
            // Handwriting comes from the OCR cache, which only search fills:
            // read any page it has not seen yet, or its ink is missing.
            await HandwritingRecognizer.indexAllIfNeeded(pages: notebook.pages ?? [], modelContext: modelContext)
            do {
                try Data(LibraryExport.markdown(for: notebook).utf8).write(to: url, options: .atomic)
                pdfExportURL = PDFExport(url: url)
            } catch {
                exportMessage = "Couldn't create the Markdown file: \(error.localizedDescription)"
            }
        }
    }

    private func exportNotebookAsPDF(_ notebook: Notebook) {
        let pages = (notebook.pages ?? []).sorted { $0.index < $1.index }
        guard !pages.isEmpty else {
            exportMessage = "That notebook has no pages to export."
            return
        }
        let stacked = ImportedDocument.stacksByPage(allImportedDocuments)
        let entries = pages.map { page in
            (page: page, artwork: ArtworkLayer.stack(for: page, stacked: stacked))
        }
        let data = PageRenderer.pdfData(for: entries)
        do {
            pdfExportURL = PDFExport(url: try PageRenderer.writeTemporaryPDF(data, named: notebook.title))
        } catch {
            exportMessage = "Couldn't create the PDF: \(error.localizedDescription)"
        }
    }
    #endif

    /// Creates the "Welcome to Linework" notebook once, the first time the
    /// root library is opened with nothing in it yet. Gated on a persistent
    /// flag rather than "is the library empty right now" so deleting that
    /// notebook later doesn't bring it back.
    private func seedTutorialNotebookIfNeeded() {
        guard parentFolder == nil,
              allNotebooks.isEmpty,
              !AppSettings.hasSeededTutorialNotebook else { return }
        AppSettings.hasSeededTutorialNotebook = true
        TutorialNotebookFactory.makeWelcomeNotebook(in: modelContext)
        save()
    }

    private var libraryContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xxl) {
                if parentFolder == nil && !favoriteNotebooks.isEmpty {
                    section("Favorites") { notebookStrip(favoriteNotebooks) }
                }

                if parentFolder == nil && !recentNotebooks.isEmpty {
                    section("Recent") { notebookStrip(recentNotebooks) }
                }

                if parentFolder == nil {
                    let tags = pageTags
                    if !tags.isEmpty {
                        section("Tags") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: Space.s) {
                                    ForEach(tags) { tag in
                                        NavigationLink(destination: TagPagesView(tag: tag)) {
                                            Chip(title: "#\(tag.name) · \(tag.pages.count)")
                                                .fixedSize()
                                                .minimumHitTarget()
                                        }
                                        .buttonStyle(LibraryCellButtonStyle())
                                    }
                                }
                            }
                            .scrollClipDisabled()
                        }
                    }
                }

                if !folders.isEmpty {
                    section("Folders") {
                        LazyVGrid(columns: gridColumns, spacing: Space.l) {
                            ForEach(folders, id: \.id) { folder in
                                NavigationLink(value: folder) {
                                    FolderCellView(folder: folder)
                                }
                                .buttonStyle(LibraryCellButtonStyle())
                                .contextMenu { folderMenu(for: folder) }
                            }
                        }
                    }
                }

                if !notebooks.isEmpty {
                    section("Notebooks") {
                        let previewArtwork = ImportedDocument.stacksByPage(allImportedDocuments)
                        LazyVGrid(columns: gridColumns, spacing: Space.xl) {
                            ForEach(notebooks, id: \.id) { notebook in
                                NavigationLink(value: notebook) {
                                    NotebookCellView(notebook: notebook, previewArtwork: previewArtwork)
                                }
                                .buttonStyle(LibraryCellButtonStyle())
                                .contextMenu {
                                    notebookMenu(for: notebook)
                                } preview: {
                                    NotebookCoverView(notebook: notebook)
                                        .frame(width: 200)
                                        .padding(Space.l)
                                }
                            }
                        }
                    }
                }

                if folders.isEmpty && notebooks.isEmpty {
                    emptyState
                }
            }
            .padding(.horizontal, Space.l)
            .padding(.top, Space.s)
            .padding(.bottom, Space.xxl)
        }
        .navigationTitle(parentFolder?.name ?? "My Library")
        .toolbar {
            if parentFolder == nil {
                ToolbarItem(placement: .automatic) {
                    Button {
                        showingMap = true
                    } label: {
                        Label("Map", systemImage: "point.3.filled.connected.trianglepath.dotted")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Shows how your notebooks link to each other")
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            // Last, so the primary action sits at the trailing edge.
            ToolbarItem(placement: addPlacement) {
                addMenu
            }
        }
        .alert("New Folder", isPresented: $showingNewFolderAlert) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { createFolder() }
        }
        .alert(smartFolderToEdit == nil ? "New Smart Folder" : "Edit Search", isPresented: $showingSmartFolderAlert) {
            if smartFolderToEdit == nil {
                TextField("Folder name", text: $newFolderName)
            }
            TextField("Search for", text: $smartFolderSearch)
            Button("Cancel", role: .cancel) {}
            Button(smartFolderToEdit == nil ? "Create" : "Save") { saveSmartFolder() }
        } message: {
            Text("Shows every page that matches, in every notebook: typed text, handwriting, PDF text and tags.")
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.pdf, .image],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await importFiles(urls) }
        }
        // A PDF or picture dragged onto the library (Split View, Stage
        // Manager, a Mac) becomes a notebook in this folder.
        .onDrop(of: [.pdf, .image], isTargeted: nil) { providers in
            importDropped(providers)
            return true
        }
        // "Open in Mystnotes" from Files or another app's share sheet.
        // Only the top level handles it, so one file makes one notebook.
        .onOpenURL { url in
            guard parentFolder == nil else { return }
            Task { await importFiles([url]) }
        }
        .sheet(isPresented: $showingNewNotebookSheet, onDismiss: {
            notebookToOpen = createdNotebook
            createdNotebook = nil
        }) {
            NewNotebookSheet { title, template, cover in
                createNotebook(title: title, template: template, coverStyle: cover)
            }
        }
        .sheet(isPresented: $showingMap, onDismiss: {
            notebookToOpen = mapPick
            mapPick = nil
        }) {
            LibraryGraphView(notebooks: storedNotebooks) { notebook in
                mapPick = notebook
                showingMap = false
            }
            .presentationSizing(.page)
        }
        .navigationDestination(item: $notebookToOpen) { notebook in
            LockedNotebookGate(notebook: notebook) { NotebookDetailView(notebook: notebook) }
        }
        .alert("Rename", isPresented: renameAlertBinding) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") { applyRename() }
        }
        .sheet(isPresented: $showingMovePicker) {
            FolderPickerView(excludingFolder: excludingFolderForMove) { destination in
                applyMove(to: destination)
            }
        }
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(get: { itemToRename != nil }, set: { if !$0 { itemToRename = nil } })
    }

    private var excludingFolderForMove: Folder? {
        if case .folder(let f) = itemToMove { return f }
        return nil
    }

    private var addPlacement: ToolbarItemPlacement {
#if targetEnvironment(macCatalyst) || canImport(UIKit)
        .navigationBarTrailing
#else
        .automatic
#endif
    }

    /// The one "+" menu, prominent: semibold glyph in the accent colour.
    private var addMenu: some View {
        Menu {
            Button {
                newFolderName = ""
                showingNewFolderAlert = true
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            Button {
                showingNewNotebookSheet = true
            } label: {
                Label("New Notebook", systemImage: "book.badge.plus")
            }
            Button {
                smartFolderToEdit = nil
                newFolderName = ""
                smartFolderSearch = ""
                showingSmartFolderAlert = true
            } label: {
                Label("New Smart Folder", systemImage: "folder.badge.gearshape")
            }
            Button {
                showingImporter = true
            } label: {
                Label("Import PDF or Image", systemImage: "square.and.arrow.down")
            }
            Button {
                showingTemplates = true
            } label: {
                Label("Page Templates…", systemImage: "doc.on.doc")
            }
        } label: {
            Image(systemName: "plus")
                .fontWeight(.semibold)
        }
    }

    /// A titled block: a large-title-style header, then its content.
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(title)
                .font(Typography.title)
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    /// Nothing in this folder: the brand mark, a plain line, two actions.
    private var emptyState: some View {
        VStack(spacing: Space.xl) {
            BrandMarkShape()
                .frame(width: 72, height: 72)
                .padding(Space.xl)
                .background(
                    RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                        .fill(LinearGradient(colors: [Palette.ink.opacity(0.85), Palette.ink],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                )
                .shadow(color: Palette.ink.opacity(0.25), radius: 16, y: 8)
            VStack(spacing: Space.s) {
                Text("Nothing here yet")
                    .font(Typography.title)
                Text("Start a notebook, or bring in a PDF or a picture. You can also drop files here.")
                    .font(Typography.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            VStack(spacing: Space.m) {
                Button("New Notebook") { showingNewNotebookSheet = true }
                    .buttonStyle(.borderedProminent)
                Button("Import PDF or Image") { showingImporter = true }
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Space.xxl * 2)
    }

    @ViewBuilder
    private func folderMenu(for folder: Folder) -> some View {
        Button {
            itemToRename = .folder(folder)
            renameText = folder.name
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        if folder.smartQuery != nil {
            Button {
                smartFolderToEdit = folder
                smartFolderSearch = folder.smartQuery ?? ""
                showingSmartFolderAlert = true
            } label: {
                Label("Edit Search", systemImage: "magnifyingglass")
            }
        }
        Button {
            itemToMove = .folder(folder)
            showingMovePicker = true
        } label: {
            Label("Move", systemImage: "folder")
        }
        Button(role: .destructive) {
            deleteFolder(folder)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    fileprivate static let coverStyleOptions: [(name: String, label: String)] = [
        ("default", "Indigo"),
        ("sunset", "Sunset"),
        ("ocean", "Ocean"),
        ("forest", "Forest"),
        ("mono", "Mono"),
        ("berry", "Berry")
    ]

    /// A horizontal strip of small covers, as Recent shows them.
    private func notebookStrip(_ notebooks: [Notebook]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: Space.l) {
                ForEach(notebooks, id: \.id) { notebook in
                    NavigationLink(value: notebook) {
                        RecentNotebookCellView(notebook: notebook)
                    }
                    .buttonStyle(LibraryCellButtonStyle())
                    .contextMenu {
                        notebookMenu(for: notebook)
                    } preview: {
                        NotebookCoverView(notebook: notebook)
                            .frame(width: 200)
                            .padding(Space.l)
                    }
                }
            }
            .padding(.vertical, Space.s)
        }
        .scrollClipDisabled()
    }

    /// A star is a setting, so it syncs on the settings clock - set
    /// directly, not through `markSettingsModified`, which would also lift
    /// `modifiedAt` and move the notebook to the front of Recent.
    private func toggleFavorite(_ notebook: Notebook) {
        notebook.isFavorite = !(notebook.isFavorite ?? false)
        notebook.settingsModifiedAt = Date()
        save()
    }

    @ViewBuilder
    private func notebookMenu(for notebook: Notebook) -> some View {
        Button {
            Task {
                let locking = notebook.isLocked != true
                if await NotebookLock.shared.setLocked(locking, for: notebook) {
                    save()
                } else if locking {
                    exportMessage = "Set a passcode on this device to lock notebooks."
                }
            }
        } label: {
            if notebook.isLocked == true {
                Label("Remove Lock", systemImage: "lock.open")
            } else {
                Label("Lock", systemImage: "lock")
            }
        }
        Button {
            toggleFavorite(notebook)
        } label: {
            if notebook.isFavorite == true {
                Label("Remove from Favorites", systemImage: "star.slash")
            } else {
                Label("Add to Favorites", systemImage: "star")
            }
        }
        Button {
            openWindow(id: "notebook", value: notebook.persistentModelID)
        } label: {
            Label("Open in New Window", systemImage: "rectangle.badge.plus")
        }
        Button {
            itemToRename = .notebook(notebook)
            renameText = notebook.title
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        #if targetEnvironment(macCatalyst) || canImport(UIKit)
        Button {
            whenOpen(notebook) { exportNotebookAsPDF(notebook) }
        } label: {
            Label("Export as PDF", systemImage: "arrow.up.doc")
        }
        Button {
            whenOpen(notebook) { exportNotebookAsMarkdown(notebook) }
        } label: {
            Label("Export as Markdown", systemImage: "doc.plaintext")
        }
        #endif
        Menu {
            ForEach(Self.coverStyleOptions, id: \.name) { option in
                Button(option.label) {
                    notebook.coverStyle = option.name
                    notebook.markSettingsModified()
                    save()
                }
            }
        } label: {
            Label("Change Cover", systemImage: "paintpalette")
        }
        Button {
            itemToMove = .notebook(notebook)
            showingMovePicker = true
        } label: {
            Label("Move", systemImage: "folder")
        }
        Button(role: .destructive) {
            deleteNotebook(notebook)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Actions

    private func saveSmartFolder() {
        let search = smartFolderSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return }
        if let folder = smartFolderToEdit {
            folder.smartQuery = search
        } else {
            let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
            let folder = Folder(name: name.isEmpty ? search : name, parentFolder: parentFolder)
            folder.smartQuery = search
            modelContext.insert(folder)
        }
        save()
    }

    private func createFolder() {
        let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let folder = Folder(name: trimmed, parentFolder: parentFolder)
        modelContext.insert(folder)
        save()
    }

    /// Each file becomes its own notebook in this folder. A single file
    /// opens straight away, like a new notebook does.
    private func importFiles(_ urls: [URL]) async {
        var made: [Notebook] = []
        for url in urls {
            guard let data = await NotebookImport.readFile(at: url),
                  let notebook = await importData(data, fileName: url.lastPathComponent) else { continue }
            made.append(notebook)
        }
        if made.count == 1 { notebookToOpen = made[0] }
    }

    private func importDropped(_ providers: [NSItemProvider]) {
        for provider in providers {
            guard let type = provider.registeredTypeIdentifiers.first(where: {
                guard let type = UTType($0) else { return false }
                return type.conforms(to: .pdf) || type.conforms(to: .image)
            }) else { continue }
            let name = provider.suggestedName ?? "Imported"
            _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                guard let data else { return }
                Task { @MainActor in _ = await importData(data, fileName: name) }
            }
        }
    }

    private func importData(_ data: Data, fileName: String) async -> Notebook? {
        guard let notebook = await NotebookImport.makeNotebook(from: data, fileName: fileName,
                                                                in: parentFolder, context: modelContext) else {
            exportMessage = "Couldn't import \(fileName). Linework imports PDFs and images."
            return nil
        }
        return notebook
    }

    private func createNotebook(title: String, template: String, coverStyle: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? "Untitled Notebook" : trimmed
        let notebook = Notebook(title: title, coverStyle: coverStyle, folder: parentFolder)
        let firstPage = Page(index: 0, type: "paged", template: template, notebook: notebook)
        notebook.pages = [firstPage]
        modelContext.insert(notebook)
        modelContext.insert(firstPage)
        save()
        createdNotebook = notebook
    }

    private func applyRename() {
        guard let item = itemToRename else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch item {
        case .folder(let folder):
            folder.name = trimmed
        case .notebook(let notebook):
            notebook.title = trimmed
            notebook.markSettingsModified()
        }
        save()
        itemToRename = nil
    }

    private func applyMove(to destination: Folder?) {
        guard let item = itemToMove else { return }
        switch item {
        case .folder(let folder):
            folder.parentFolder = destination
        case .notebook(let notebook):
            notebook.folder = destination
            notebook.markSettingsModified()
        }
        save()
        itemToMove = nil
    }

    private func deleteFolder(_ folder: Folder) {
        let pageIDs = allPageIDs(in: folder)
        cleanUpLinks(forPageIDs: pageIDs)
        deleteStoredFiles(forPageIDs: pageIDs)
        // Record the deletion so folder sync propagates it instead of the
        // items coming back from another device's older snapshot.
        SyncTombstones.merge(tombstones(for: folder))
        modelContext.delete(folder) // cascade delete rule removes subfolders/notebooks too
        save()
        SyncEngine.shared.pushOnBackground()
    }

    private func deleteNotebook(_ notebook: Notebook) {
        let pageIDs = Set((notebook.pages ?? []).map { $0.id })
        cleanUpLinks(forPageIDs: pageIDs)
        deleteStoredFiles(forPageIDs: pageIDs)
        SyncTombstones.merge([Tombstone(kind: .notebook, id: notebook.id, deletedAt: Date())])
        modelContext.delete(notebook) // cascade delete rule removes pages too
        save()
        SyncEngine.shared.pushOnBackground()
    }

    /// A tombstone for `folder` and everything the cascade delete will take
    /// with it (its notebooks and, recursively, its subfolders).
    private func tombstones(for folder: Folder) -> [Tombstone] {
        var stones = [Tombstone(kind: .folder, id: folder.id, deletedAt: Date())]
        for notebook in folder.notebooks ?? [] {
            stones.append(Tombstone(kind: .notebook, id: notebook.id, deletedAt: Date()))
        }
        for subfolder in folder.subfolders ?? [] {
            stones.append(contentsOf: tombstones(for: subfolder))
        }
        return stones
    }

    /// Removes the on-disk payloads for pages that are about to be deleted.
    /// The SwiftData cascade only takes the records; the drawing files and
    /// imported photos/PDFs live outside the database and would otherwise
    /// stay on disk (and in iCloud) forever - a whole notebook's worth at a
    /// time.
    private func deleteStoredFiles(forPageIDs pageIDs: Set<UUID>) {
        guard !pageIDs.isEmpty else { return }

        // Never removeItem on ink: it goes to trash/ (invariant 3).
        let store = DrawingStore.live
        for id in pageIDs {
            store.trashDrawing(forPageID: id)
        }

        // A multi-page PDF import shares one file across its pages, so only
        // drop imported files that nothing outside this deletion still uses.
        func belongsToDeletedPage(_ doc: ImportedDocument) -> Bool {
            doc.page.map { pageIDs.contains($0.id) } ?? false
        }
        let refsInside = Set(allImportedDocuments.filter(belongsToDeletedPage).map(\.fileRef))
        let refsOutside = Set(allImportedDocuments.filter { !belongsToDeletedPage($0) }.map(\.fileRef))
        for ref in refsInside.subtracting(refsOutside) where !ref.isEmpty {
            store.trashPayload(named: ref)
        }
    }

    /// Link stores its source/destination as raw UUIDs rather than a real
    /// SwiftData relationship, so deleting a page's owning notebook (or a
    /// folder full of notebooks) doesn't cascade-delete related Links
    /// automatically — we clean them up manually here to avoid leaving
    /// dangling references behind.
    private func cleanUpLinks(forPageIDs pageIDs: Set<UUID>) {
        Links.removeAll(touching: pageIDs, in: modelContext)
    }

    private func allPageIDs(in folder: Folder) -> Set<UUID> {
        var ids = Set((folder.notebooks ?? []).flatMap { ($0.pages ?? []).map { $0.id } })
        for sub in folder.subfolders ?? [] {
            ids.formUnion(allPageIDs(in: sub))
        }
        return ids
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            print("Failed to save library change: \(error)")
        }
    }
}

enum LibraryItem: Hashable {
    case folder(Folder)
    case notebook(Notebook)
}

/// Applies `.searchable` only when `enabled`. The library recurses (each folder
/// pushes another LibraryView), but the global search field belongs at the root
/// level only — a modifier can't be attached conditionally, so this wrapper
/// carries the gate.
private struct SearchableModifier: ViewModifier {
    @Binding var text: String
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.searchable(
                text: $text,
                placement: .automatic,   // valid on iOS/Catalyst and native macOS
                prompt: "Search notes"
            )
        } else {
            content
        }
    }
}

/// Title and first-page paper for a new notebook. A sheet rather than an
/// alert because an alert can hold text fields and buttons only, and the
/// paper used to be whatever Settings said with no say at creation.
private struct NewNotebookSheet: View {
    var onCreate: (_ title: String, _ template: String, _ coverStyle: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var template = AppSettings.defaultTemplate
    @State private var coverStyle = "default"

    var body: some View {
        NavigationStack {
            Form {
                TextField("Notebook title", text: $title)
                Picker("First Page", selection: $template) {
                    ForEach(PageTemplate.options, id: \.id) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("Cover")
                    Spacer()
                    ForEach(LibraryView.coverStyleOptions, id: \.name) { option in
                        Button {
                            coverStyle = option.name
                        } label: {
                            Circle()
                                .fill(NotebookCoverView.color(for: option.name))
                                .frame(width: 28, height: 28)
                                .overlay {
                                    if coverStyle == option.name {
                                        Image(systemName: "checkmark")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.label)
                        .accessibilityAddTraits(coverStyle == option.name ? .isSelected : [])
                    }
                }
            }
            .navigationTitle("New Notebook")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(title, template, coverStyle)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
