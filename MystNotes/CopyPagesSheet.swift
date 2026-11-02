import SwiftUI
import SwiftData

/// Sheet for copying pages out of the open notebook into another one.
/// Opened from a page's context menu in the page strip with that page
/// ticked; any other pages can be ticked too, then a destination notebook
/// picked. The copies are appended to the destination.
struct CopyPagesSheet: View {
    /// The open notebook's pages, in order.
    let pages: [Page]
    var documentsByPageID: [UUID: [ImportedDocument]] = [:]
    let currentNotebookID: UUID
    var onCopy: ([Page], Notebook) -> Void

    @Query(sort: \Notebook.title) private var notebooks: [Notebook]
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID>
    @State private var destination: Notebook?

    init(pages: [Page], documentsByPageID: [UUID: [ImportedDocument]] = [:],
         initialSelection: UUID, currentNotebookID: UUID,
         onCopy: @escaping ([Page], Notebook) -> Void) {
        self.init(pages: pages, documentsByPageID: documentsByPageID,
                  initialSelections: [initialSelection], currentNotebookID: currentNotebookID, onCopy: onCopy)
    }

    /// Several pages ticked at the start (the page grid's selection).
    init(pages: [Page], documentsByPageID: [UUID: [ImportedDocument]] = [:],
         initialSelections: Set<UUID>, currentNotebookID: UUID,
         onCopy: @escaping ([Page], Notebook) -> Void) {
        self.pages = pages
        self.documentsByPageID = documentsByPageID
        self.currentNotebookID = currentNotebookID
        self.onCopy = onCopy
        _selected = State(initialValue: initialSelections)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Pages") {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                        Button {
                            if selected.contains(page.id) { selected.remove(page.id) } else { selected.insert(page.id) }
                        } label: {
                            HStack {
                                PageThumbnailView(page: page, importedDocuments: documentsByPageID[page.id] ?? [])
                                Text("Page \(index + 1)")
                                Spacer()
                                Image(systemName: selected.contains(page.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(page.id) ? Color.accentColor : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section("Copy to") {
                    ForEach(PageTemplates.libraryNotebooks(notebooks).filter { $0.id != currentNotebookID }) { notebook in
                        Button {
                            destination = notebook
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(notebook.title)
                                    if let folder = notebook.folder {
                                        Text(folder.name).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if destination?.id == notebook.id {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Copy Pages")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Copy \(selected.count)") {
                        if let destination {
                            onCopy(pages.filter { selected.contains($0.id) }, destination)
                        }
                        dismiss()
                    }
                    .disabled(destination == nil || selected.isEmpty)
                }
            }
        }
    }
}
