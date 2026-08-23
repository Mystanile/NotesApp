import SwiftUI

/// Sheet for picking which page (within the current notebook) a link
/// anchor should jump to.
struct LinkDestinationPickerView: View {
    let pages: [Page]
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
                            PageThumbnailView(page: page)
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
