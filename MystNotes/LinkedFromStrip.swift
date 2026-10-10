import SwiftUI

/// M2's first slice (BACKLOG, "M2 design"): the pages that link to the
/// open one, so a link is followed both ways. Read-only; built from the
/// SwiftData index, so `LibraryRebuild` rebuilds it with everything else.
struct LinkedFromStrip: View {
    let sources: [Page]
    var currentNotebookID: UUID? = nil
    let onSelect: (UUID) -> Void

    /// Pages in `pages` with a link to `pageID`: each once, in page order,
    /// never the page itself. A link whose source page is gone isn't shown.
    static func sources(linkingTo pageID: UUID, links: [Link], pages: [Page]) -> [Page] {
        let ids = Set(links.lazy.filter { $0.destinationPageID == pageID && $0.sourcePageID != pageID }.map(\.sourcePageID))
        return pages.filter { ids.contains($0.id) }.sorted { $0.index < $1.index }
    }

    static func label(for page: Page) -> String {
        let number = "p. \(page.index + 1)"
        guard let title = page.title, !title.isEmpty else { return number }
        return "\(number) · \(title)"
    }

    /// "p. N · title" in the open notebook, "<Notebook> · p. N" elsewhere.
    static func label(for page: Page, currentNotebookID: UUID?) -> String {
        guard let nb = page.notebook, nb.id != currentNotebookID else { return label(for: page) }
        return "\(nb.title) · p. \(page.index + 1)"
    }

    var body: some View {
        if !sources.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("Linked from", systemImage: "arrow.turn.down.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(sources, id: \.id) { page in
                    Button(Self.label(for: page, currentNotebookID: currentNotebookID)) { onSelect(page.id) }
                        .font(.caption)
                        .lineLimit(1)
                }
            }
            .padding(10)
            .frame(maxWidth: 200, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(12)
        }
    }
}
