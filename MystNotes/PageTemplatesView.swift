import SwiftUI
import SwiftData
import PDFKit
import UniformTypeIdentifiers

/// Custom page templates (Nov 2, 2026).
///
/// A template is one page of a real notebook whose `role` is "templates":
/// the page's bottom artwork row is the template art (a PDF page or an
/// image), and its paper, shape and name come along. Because it is an
/// ordinary notebook, sync, export, Rebuild Index and the trash already
/// cover it (invariants 3, 4 and 9) - this file adds no storage of its own.
/// Only the library hides it.
enum PageTemplates {
    /// The value of `Notebook.role` that marks the templates notebook.
    static let role = "templates"

    static func isTemplatesNotebook(_ notebook: Notebook) -> Bool {
        notebook.role == role
    }

    /// The notebooks the library shows: everything but the templates one.
    static func libraryNotebooks(_ notebooks: [Notebook]) -> [Notebook] {
        notebooks.filter { !isTemplatesNotebook($0) }
    }

    /// The templates notebook, or nil when there is none and `create` is
    /// false. If two devices each made one before they first synced, every
    /// device settles on the same one - the oldest, ties broken by id - so
    /// the templates stay in a single place.
    static func templatesNotebook(in context: ModelContext, create: Bool) -> Notebook? {
        let all = (try? context.fetch(FetchDescriptor<Notebook>())) ?? []
        if let existing = canonical(in: all) { return existing }
        guard create else { return nil }
        let notebook = Notebook(title: "Templates")
        notebook.role = role
        notebook.markSettingsModified()
        context.insert(notebook)
        return notebook
    }

    private static func canonical(in notebooks: [Notebook]) -> Notebook? {
        notebooks.filter(isTemplatesNotebook).min {
            ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString)
        }
    }

    /// The templates, in the order the user keeps them.
    static func templates(in context: ModelContext) -> [Page] {
        templates(in: (try? context.fetch(FetchDescriptor<Notebook>())) ?? [])
    }

    /// Same, from notebooks a view already holds (its `@Query`).
    static func templates(in notebooks: [Notebook]) -> [Page] {
        (canonical(in: notebooks)?.pages ?? []).sorted { $0.index < $1.index }
    }

    static func displayName(_ page: Page) -> String {
        let name = (page.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Template \(page.index + 1)" : name
    }

    /// Puts a new page into `notebook` at `index` (pages from there on move
    /// down one, and are marked modified so the new order syncs) with the
    /// shape, paper and artwork of `source` - and no ink, text or stickers.
    ///
    /// Only the bottom artwork row comes along, shared by file name as the
    /// pages of one PDF import already share theirs. From an ordinary page
    /// that row counts only when it is the page's paper (`paperOnly`), so a
    /// photo placed on a page is not mistaken for its template; a template
    /// page's own art is always taken, an image included.
    @discardableResult
    static func insertPage(copyingPaperOf source: Page, into notebook: Notebook, at index: Int,
                           title: String? = nil, paperOnly: Bool,
                           in context: ModelContext, now: Date = Date()) -> Page {
        for other in notebook.pages ?? [] where other.index >= index {
            other.index += 1
            other.markModified(at: now)
        }
        let page = Page(index: index, type: source.type, template: source.template, notebook: notebook)
        page.aspectRatio = source.aspectRatio
        page.title = title
        context.insert(page)
        if let art = ImportedDocument.stack(on: source.id, in: source.importedDocuments ?? []).first,
           !paperOnly || ArtworkLayer(art).isPaper {
            let copy = ImportedDocument(sourceType: art.sourceType, fileRef: art.fileRef,
                                        pdfPageIndex: art.pdfPageIndex, page: page)
            (copy.frameX, copy.frameY, copy.frameWidth, copy.frameHeight) =
                (art.frameX, art.frameY, art.frameWidth, art.frameHeight)
            copy.rotationDegrees = art.rotationDegrees
            (copy.cropX, copy.cropY, copy.cropWidth, copy.cropHeight) =
                (art.cropX, art.cropY, art.cropWidth, art.cropHeight)
            context.insert(copy)
            page.backgroundRef = art.fileRef
        }
        if !(notebook.pages ?? []).contains(where: { $0.id == page.id }) {
            notebook.pages = (notebook.pages ?? []) + [page]
        }
        page.markModified(at: now)
        return page
    }

    /// Saves `page`'s paper as a new template at the end of the templates
    /// notebook. Returns nil for a page that is not a paged one.
    @discardableResult
    static func saveAsTemplate(_ page: Page, in context: ModelContext) -> Page? {
        guard page.type == "paged",
              let notebook = templatesNotebook(in: context, create: true) else { return nil }
        let count = (notebook.pages ?? []).count
        let name = (page.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return insertPage(copyingPaperOf: page, into: notebook, at: count,
                          title: name.isEmpty ? "Template \(count + 1)" : name,
                          paperOnly: true, in: context)
    }

    /// Makes templates from a picked PDF (one per PDF page) or image (one),
    /// at the end of the templates notebook, named after the file. Returns
    /// how many it made; 0, and nothing written to the library, when the
    /// data is neither.
    @discardableResult
    static func importTemplates(from data: Data, fileName: String, in context: ModelContext) async -> Int {
        guard let kind = ImportedFileType.of(data) else { return 0 }
        let document = kind.isPDF ? PDFDocument(data: data) : nil
        if kind.isPDF && (document?.pageCount ?? 0) == 0 { return 0 }
        guard let fileRef = await NotebookDetailView.writeImport(data, extension: kind.fileExtension),
              let notebook = templatesNotebook(in: context, create: true) else { return 0 }

        let base = (fileName as NSString).deletingPathExtension
        let name = base.isEmpty ? "Template" : base
        let start = ((notebook.pages ?? []).map(\.index).max() ?? -1) + 1
        var made: [Page] = []
        if let document {
            NotebookImport.appendPDFPages(document, storedAs: fileRef, to: notebook, startingAt: start, in: context)
            made = (notebook.pages ?? []).filter { $0.index >= start }.sorted { $0.index < $1.index }
        } else {
            let page = NotebookImport.appendImagePage(storedAs: fileRef, to: notebook, at: start, in: context)
            // A picture used as paper fills the page, and the page takes
            // its shape - not a photo floating on a default-sized sheet.
            if let aspect = ImportedArtwork.aspectRatio(fileRef: fileRef, pdfPageIndex: 0),
               let art = page.importedDocuments?.first {
                page.aspectRatio = aspect
                (art.frameX, art.frameY, art.frameWidth, art.frameHeight) = (0, 0, 1, 1)
            }
            made = [page]
        }
        for (offset, page) in made.enumerated() {
            page.title = made.count > 1 ? "\(name) \(offset + 1)" : name
            page.markModified()
        }
        do {
            try context.save()
        } catch {
            AppLog.note("templates", "Failed to save imported templates: \(error)")
        }
        return made.count
    }

    /// Renames a template. An empty name goes back to the numbered default.
    static func rename(_ page: Page, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        page.title = trimmed.isEmpty ? nil : trimmed
        page.markModified()
    }
}

// MARK: - Manage screen

/// Settings > Page Templates, and the page strip's Manage Templates: the
/// templates as a grid, with rename, delete and "from file".
struct PageTemplatesView: View {
    @Environment(\.modelContext) private var modelContext
    // One query each for the whole grid; the cells are handed their data
    // (a `@Query` per cell re-fetches once per thumbnail).
    @Query private var notebooks: [Notebook]
    @Query private var importedDocuments: [ImportedDocument]

    @State private var showingImporter = false
    @State private var renaming: Page?
    @State private var renameText = ""
    @State private var message: String?

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: Space.l)]

    private var templates: [Page] { PageTemplates.templates(in: notebooks) }

    var body: some View {
        let stacks = ImportedDocument.stacksByPage(importedDocuments)
        ScrollView {
            if templates.isEmpty {
                ContentUnavailableView {
                    Label("No templates yet", systemImage: "doc.on.doc")
                } description: {
                    Text("Make one from a PDF or a picture, or open a page and choose Save Page as Template in the page strip's + menu.")
                } actions: {
                    Button("New Template from File…") { showingImporter = true }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.top, Space.xxl)
            } else {
                LazyVGrid(columns: columns, spacing: Space.l) {
                    ForEach(templates, id: \.id) { page in
                        cell(page, documents: stacks[page.id] ?? [])
                    }
                }
                .padding(Space.l)
            }
        }
        .navigationTitle("Page Templates")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingImporter = true
                } label: {
                    Label("New Template from File…", systemImage: "plus")
                }
            }
        }
        // The only `.fileImporter` on this view.
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.pdf, .png, .jpeg, .heic],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await importFiles(urls) }
        }
        .alert("Rename Template", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let page = renaming {
                    PageTemplates.rename(page, to: renameText)
                    save("Failed to rename the template")
                }
                renaming = nil
            }
        }
        .alert("Page Templates", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private func cell(_ page: Page, documents: [ImportedDocument]) -> some View {
        VStack(spacing: Space.s) {
            PageThumbnailView(page: page, importedDocuments: documents, height: 160)
            Text(PageTemplates.displayName(page))
                .font(Typography.label)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(Space.s)
        .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Color.primary.opacity(0.04)))
        .contentShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        .contextMenu {
            Button {
                renameText = page.title ?? ""
                renaming = page
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
            Button(role: .destructive) {
                delete(page)
            } label: {
                Label("Delete Template", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(PageTemplates.displayName(page))
        .accessibilityAction(named: "Rename") {
            renameText = page.title ?? ""
            renaming = page
        }
        .accessibilityAction(named: "Delete") { delete(page) }
    }

    private func importFiles(_ urls: [URL]) async {
        var failed: [String] = []
        for url in urls {
            guard let data = await NotebookImport.readFile(at: url),
                  await PageTemplates.importTemplates(from: data, fileName: url.lastPathComponent,
                                                      in: modelContext) > 0 else {
                failed.append(url.lastPathComponent)
                continue
            }
        }
        if !failed.isEmpty {
            message = "Couldn't use \(failed.joined(separator: ", ")) as a template."
        }
    }

    /// Through the same deletion as any page, so the page's file goes to
    /// `trash/` (and stays while another template still uses it) and a
    /// tombstone lets sync remove it elsewhere.
    private func delete(_ page: Page) {
        guard let notebook = page.notebook else { return }
        PageDeletion.delete(page, from: notebook, in: modelContext, drawingStore: DrawingStore.live)
        save("Failed to delete the template")
    }

    private func save(_ failure: String) {
        do {
            try modelContext.save()
        } catch {
            AppLog.note("templates", "\(failure): \(error)")
        }
    }
}
