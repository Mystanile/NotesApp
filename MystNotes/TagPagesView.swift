import SwiftUI

enum TagPages {
    static func label(for page: Page) -> String {
        var text = "\(page.notebook?.title ?? "Untitled") · p. \(page.index + 1)"
        if let name = page.title, !name.isEmpty { text += " · \(name)" }
        return text
    }
}

/// The pages carrying one tag; a tap opens the notebook at that page
/// (same destination as a search hit).
struct TagPagesView: View {
    let tag: PageTags.Tag

    var body: some View {
        List(tag.pages.filter { $0.notebook != nil }, id: \.id) { page in
            NavigationLink(value: SearchResult(notebook: page.notebook!, pageID: page.id,
                                               pageNumber: page.index + 1, snippet: "")) {
                Text(TagPages.label(for: page))
            }
        }
        .navigationTitle("#\(tag.name)")
    }
}
