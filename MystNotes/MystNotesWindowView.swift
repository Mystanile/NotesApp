import SwiftUI
import SwiftData

/// Resolves a SwiftData PersistentIdentifier (passed in via openWindow)
/// back into an actual Notebook and shows it standalone in its own
/// window — no library chrome around it, since this window's whole
/// purpose is focused side-by-side viewing in Split View.
struct NotebookWindowView: View {
    let notebookID: PersistentIdentifier?

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationStack {
            if let notebookID, let notebook = modelContext.model(for: notebookID) as? Notebook {
                NotebookDetailView(notebook: notebook)
            } else {
                ContentUnavailableView(
                    "Notebook Not Found",
                    systemImage: "book.closed",
                    description: Text("This notebook may have been deleted.")
                )
            }
        }
    }
}
