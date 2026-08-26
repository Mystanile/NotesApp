import SwiftUI
import SwiftData

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
    @Query(sort: \Notebook.title) private var allNotebooks: [Notebook]
    @Query private var allLinks: [Link]

    @State private var showingNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var showingNewNotebookAlert = false
    @State private var newNotebookTitle = ""

    @State private var itemToRename: LibraryItem?
    @State private var renameText = ""

    @State private var itemToMove: LibraryItem?
    @State private var showingMovePicker = false

    @State private var searchText = ""
    @State private var showingSettings = false

    private let gridColumns = [GridItem(.adaptive(minimum: 140), spacing: 16)]

    private var folders: [Folder] {
        allFolders.filter { $0.parentFolder?.id == parentFolder?.id }
    }

    private var notebooks: [Notebook] {
        allNotebooks.filter { $0.folder?.id == parentFolder?.id }
    }

    /// The most recently touched notebooks across the whole library
    /// (regardless of which folder they live in) — shown as a strip at the
    /// top of the root library so it doesn't open on a blank page.
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
            SettingsView()
        }
        .task(id: parentFolder?.id) {
            seedTutorialNotebookIfNeeded()
        }
    }

    /// Creates the "Welcome to Mystnotes" notebook once, the first time the
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
            VStack(alignment: .leading, spacing: 24) {
                if parentFolder == nil && !recentNotebooks.isEmpty {
                    sectionHeader("Recent")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(recentNotebooks, id: \.id) { notebook in
                                NavigationLink(value: notebook) {
                                    RecentNotebookCellView(notebook: notebook)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { notebookMenu(for: notebook) }
                            }
                        }
                        .padding(.horizontal, 2)
                        .padding(.vertical, 4)
                    }
                }

                if !folders.isEmpty {
                    sectionHeader("Folders")
                    LazyVGrid(columns: gridColumns, spacing: 16) {
                        ForEach(folders, id: \.id) { folder in
                            NavigationLink(value: folder) {
                                FolderCellView(folder: folder)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { folderMenu(for: folder) }
                        }
                    }
                }

                if !notebooks.isEmpty {
                    sectionHeader("Notebooks")
                    LazyVGrid(columns: gridColumns, spacing: 16) {
                        ForEach(notebooks, id: \.id) { notebook in
                            NavigationLink(value: notebook) {
                                NotebookCellView(notebook: notebook)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { notebookMenu(for: notebook) }
                        }
                    }
                }

                if folders.isEmpty && notebooks.isEmpty {
                    ContentUnavailableView(
                        "Nothing here yet",
                        systemImage: "tray",
                        description: Text("Create a folder or a notebook to get started.")
                    )
                    .padding(.top, 60)
                }
            }
            .padding()
        }
        .navigationTitle(parentFolder?.name ?? "My Library")
        .toolbar {
#if targetEnvironment(macCatalyst) || canImport(UIKit)
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        newFolderName = ""
                        showingNewFolderAlert = true
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                    Button {
                        newNotebookTitle = ""
                        showingNewNotebookAlert = true
                    } label: {
                        Label("New Notebook", systemImage: "book.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
#else
            // For macOS native, we use automatic placement for toolbar items
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button {
                        newFolderName = ""
                        showingNewFolderAlert = true
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                    Button {
                        newNotebookTitle = ""
                        showingNewNotebookAlert = true
                    } label: {
                        Label("New Notebook", systemImage: "book.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
#endif
            if parentFolder == nil {
                ToolbarItem(placement: .automatic) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
        }
        .alert("New Folder", isPresented: $showingNewFolderAlert) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { createFolder() }
        }
        .alert("New Notebook", isPresented: $showingNewNotebookAlert) {
            TextField("Notebook title", text: $newNotebookTitle)
            Button("Cancel", role: .cancel) {}
            Button("Create") { createNotebook() }
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

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func folderMenu(for folder: Folder) -> some View {
        Button {
            itemToRename = .folder(folder)
            renameText = folder.name
        } label: {
            Label("Rename", systemImage: "pencil")
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

    private let coverStyleOptions: [(name: String, label: String)] = [
        ("default", "Indigo"),
        ("sunset", "Sunset"),
        ("ocean", "Ocean"),
        ("forest", "Forest"),
        ("mono", "Mono"),
        ("berry", "Berry")
    ]

    @ViewBuilder
    private func notebookMenu(for notebook: Notebook) -> some View {
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
        Menu {
            ForEach(coverStyleOptions, id: \.name) { option in
                Button(option.label) {
                    notebook.coverStyle = option.name
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

    private func createFolder() {
        let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let folder = Folder(name: trimmed, parentFolder: parentFolder)
        modelContext.insert(folder)
        save()
    }

    private func createNotebook() {
        let trimmed = newNotebookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? "Untitled Notebook" : trimmed
        let notebook = Notebook(title: title, folder: parentFolder)
        let firstPage = Page(index: 0, type: "paged", template: AppSettings.defaultTemplate, notebook: notebook)
        notebook.pages = [firstPage]
        modelContext.insert(notebook)
        modelContext.insert(firstPage)
        save()
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
            notebook.modifiedAt = Date()
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
        }
        save()
        itemToMove = nil
    }

    private func deleteFolder(_ folder: Folder) {
        cleanUpLinks(forPageIDs: allPageIDs(in: folder))
        modelContext.delete(folder) // cascade delete rule removes subfolders/notebooks too
        save()
    }

    private func deleteNotebook(_ notebook: Notebook) {
        let pageIDs = Set((notebook.pages ?? []).map { $0.id })
        cleanUpLinks(forPageIDs: pageIDs)
        modelContext.delete(notebook) // cascade delete rule removes pages too
        save()
    }

    /// Link stores its source/destination as raw UUIDs rather than a real
    /// SwiftData relationship, so deleting a page's owning notebook (or a
    /// folder full of notebooks) doesn't cascade-delete related Links
    /// automatically — we clean them up manually here to avoid leaving
    /// dangling references behind.
    private func cleanUpLinks(forPageIDs pageIDs: Set<UUID>) {
        guard !pageIDs.isEmpty else { return }
        for link in allLinks where pageIDs.contains(link.sourcePageID) || pageIDs.contains(link.destinationPageID) {
            modelContext.delete(link)
        }
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