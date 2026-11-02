import SwiftUI

/// Sheet for picking which page (within the current notebook) a link
/// anchor should jump to.
struct LinkDestinationPickerView: View {
    let pages: [Page]
    /// Each page's artwork, handed in by the parent, which already holds
    /// the query - a thumbnail no longer looks its own documents up.
    var documentsByPageID: [UUID: [ImportedDocument]] = [:]
    /// Every notebook, for the "Other Notebooks" section (this one is dropped).
    var notebooks: [Notebook] = []
    var currentNotebookID: UUID? = nil
    var onSelect: (UUID) -> Void

    static func otherNotebooks(_ all: [Notebook], excluding id: UUID?) -> [Notebook] {
        all.filter { $0.id != id }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                    Button {
                        onSelect(page.id)
                        dismiss()
                    } label: {
                        HStack {
                            PageThumbnailView(page: page, importedDocuments: documentsByPageID[page.id] ?? [])
                            Text("Page \(index + 1)")
                        }
                    }
                    .buttonStyle(.plain)
                }
                let others = Self.otherNotebooks(PageTemplates.libraryNotebooks(notebooks), excluding: currentNotebookID)
                if !others.isEmpty {
                    Section("Other Notebooks") {
                        ForEach(others, id: \.id) { other in
                            NavigationLink(other.title) {
                                List((other.pages ?? []).sorted { $0.index < $1.index }, id: \.id) { page in
                                    Button(LinkedFromStrip.label(for: page)) {
                                        onSelect(page.id)
                                        dismiss()
                                    }
                                }
                                .navigationTitle(other.title)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Link to Page")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
