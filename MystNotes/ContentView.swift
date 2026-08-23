import SwiftUI
import SwiftData

/// App root. Just hosts the NavigationStack and registers the two
/// navigation destinations once, at the top — pushed LibraryViews and
/// NotebookDetailViews don't need to re-register these themselves.
struct ContentView: View {
    @AppStorage(AppSettings.Keys.appearance) private var appearance = "system"

    var body: some View {
        NavigationStack {
            LibraryView(parentFolder: nil)
                .navigationDestination(for: Folder.self) { folder in
                    LibraryView(parentFolder: folder)
                }
                .navigationDestination(for: Notebook.self) { notebook in
                    NotebookDetailView(notebook: notebook)
                }
                .navigationDestination(for: SearchResult.self) { result in
                    NotebookDetailView(notebook: result.notebook, initialPageID: result.pageID)
                }
        }
        .preferredColorScheme(scheme)
    }

    private var scheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}
