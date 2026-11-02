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
    /// Every link in the library; its nodes fill the "Nodes" section.
    var links: [Link] = []
    var currentNotebookID: UUID? = nil
    /// (destination page, the node picked instead of the page, if any).
    var onSelect: (UUID, UUID?) -> Void

    /// A node as a row: its name, where it lives, and what is needed to
    /// check that its ink is still there.
    struct NodeChoice: Identifiable, Equatable {
        let id: UUID
        let pageID: UUID
        let title: String
        let subtitle: String
        let probe: NodeProbe
    }

    /// Every `kind == "node"` link whose page is in `notebooks`, by name.
    /// Plain links, mentions and transclusions are not choices.
    static func nodeChoices(links: [Link], notebooks: [Notebook]) -> [NodeChoice] {
        var pages: [UUID: Page] = [:]
        for notebook in notebooks { for page in notebook.pages ?? [] { pages[page.id] = page } }
        return links.compactMap { link -> NodeChoice? in
            guard Links.isNode(link), let page = pages[link.sourcePageID] else { return nil }
            return NodeChoice(id: link.id, pageID: page.id, title: link.title ?? "Node",
                              subtitle: "\(page.notebook?.title ?? "Notebook") · p. \(page.index + 1)",
                              probe: NodeProbe(id: link.id, pageID: page.id, strokeIDs: link.strokeIDs ?? []))
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    @State private var goneNodeIDs: Set<UUID> = []

    static func otherNotebooks(_ all: [Notebook], excluding id: UUID?) -> [Notebook] {
        all.filter { $0.id != id }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                    Button {
                        onSelect(page.id, nil)
                        dismiss()
                    } label: {
                        HStack {
                            PageThumbnailView(page: page, importedDocuments: documentsByPageID[page.id] ?? [])
                            Text("Page \(index + 1)")
                        }
                    }
                    .buttonStyle(.plain)
                }
                let choices = Self.nodeChoices(links: links, notebooks: PageTemplates.libraryNotebooks(notebooks))
                if !choices.isEmpty {
                    Section("Nodes") {
                        ForEach(choices) { choice in
                            let isGone = goneNodeIDs.contains(choice.id)
                            Button {
                                onSelect(choice.pageID, choice.id)
                                dismiss()
                            } label: {
                                HStack(spacing: Space.s) {
                                    Image(systemName: isGone ? "scribble.variable" : "scribble")
                                        .foregroundStyle(isGone ? Color.secondary : Palette.node)
                                    VStack(alignment: .leading, spacing: Space.xxs) {
                                        Text(choice.title).lineLimit(1)
                                        Text(isGone ? choice.subtitle + " · ink removed" : choice.subtitle)
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .foregroundStyle(isGone ? Color.secondary : Color.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                let others = Self.otherNotebooks(PageTemplates.libraryNotebooks(notebooks), excluding: currentNotebookID)
                if !others.isEmpty {
                    Section("Other Notebooks") {
                        ForEach(others, id: \.id) { other in
                            NavigationLink(other.title) {
                                List((other.pages ?? []).sorted { $0.index < $1.index }, id: \.id) { page in
                                    Button(LinkedFromStrip.label(for: page)) {
                                        onSelect(page.id, nil)
                                        dismiss()
                                    }
                                }
                                .navigationTitle(other.title)
                            }
                        }
                    }
                }
            }
            .task(id: links.count) {
                let probes = Self.nodeChoices(links: links, notebooks: PageTemplates.libraryNotebooks(notebooks)).map(\.probe)
                guard !probes.isEmpty else { return }
                let gone = await NodeInk.goneDetached(probes).value
                if !Task.isCancelled { goneNodeIDs = gone }
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
