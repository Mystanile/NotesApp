import SwiftUI

/// Sheet for picking which page (within the current notebook) a link
/// anchor should jump to.
struct LinkDestinationPickerView: View {
    let pages: [Page]
    /// Handed in by the parent, which already holds the query - a
    /// thumbnail no longer looks its own document up.
    var documentsByPageID: [UUID: ImportedDocument] = [:]
    var onSelect: (UUID) -> Void

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
                            PageThumbnailView(page: page, importedDocument: documentsByPageID[page.id])
                            Text("Page \(index + 1)")
                        }
                    }
                    .buttonStyle(.plain)
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
