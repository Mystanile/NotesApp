import SwiftUI

// MARK: - Which nodes have lost their ink

/// What a node needs to be checked against its page's record, as plain
/// values: safe to hand to a background task (no model objects).
nonisolated struct NodeProbe: Sendable, Equatable {
    let id: UUID
    let pageID: UUID
    let strokeIDs: [String]
}

/// "Gone" is derived, never stored: a node whose strokes no longer resolve
/// in its page's record. Nothing is deleted because of it (M2 plan,
/// "Erase and placeholder behaviour").
nonisolated enum NodeInk {
    @MainActor
    static func probes(of nodes: [Link]) -> [NodeProbe] {
        nodes.map { NodeProbe(id: $0.id, pageID: $0.sourcePageID, strokeIDs: $0.strokeIDs ?? []) }
    }

    /// The probes whose ink is gone, judged by `regionExists(pageID, ids)`.
    /// A node whose ids don't parse can't be judged and is never "gone".
    static func goneIDs(_ probes: [NodeProbe], regionExists: (UUID, Set<UUID>) -> Bool) -> Set<UUID> {
        var gone: Set<UUID> = []
        for probe in probes {
            let ids = Set(probe.strokeIDs.compactMap(UUID.init(uuidString:)))
            guard !ids.isEmpty else { continue }
            if !regionExists(probe.pageID, ids) { gone.insert(probe.id) }
        }
        return gone
    }

    /// Reads each record through `DrawingStore.regionInk` (side-effect free).
    static func goneIDs(_ probes: [NodeProbe]) -> Set<UUID> {
        goneIDs(probes) { DrawingStore.regionInk(pageID: $0, ids: $1) != nil }
    }

    /// The same, off the main thread. `nonisolated static` and capture-free
    /// by construction, like `DrawingStore.saveDetached`: a `Task.detached`
    /// formed inside a main-actor view would run on the main thread.
    static func goneDetached(_ probes: [NodeProbe]) -> Task<Set<UUID>, Never> {
        Task.detached(priority: .utility) { goneIDs(probes) }
    }

    /// `goneDetached` with the record check injected (tests observe the
    /// thread it runs on, or point it at a temporary store).
    static func goneDetached(_ probes: [NodeProbe],
                             regionExists: @escaping @Sendable (UUID, Set<UUID>) -> Bool) -> Task<Set<UUID>, Never> {
        Task.detached(priority: .utility) { goneIDs(probes, regionExists: regionExists) }
    }

    /// What one page's probe left behind: the record it was judged against
    /// (date and size on disk), the nodes judged, and which of them are gone.
    struct PageResult: Equatable, Sendable {
        var stamp: InkStamp?
        var probeIDs: Set<UUID>
        var gone: Set<UUID>
    }

    /// Judges one page's nodes against its record in `store`, off the main
    /// thread - unless `previous` already was judged against the same record
    /// and the same nodes, in which case nothing is read and the result is
    /// nil. A page whose ink hasn't changed is never decoded again.
    static func recheckDetached(pageID: UUID, probes: [NodeProbe], previous: PageResult?,
                                store: DrawingStore) -> Task<PageResult?, Never> {
        Task.detached(priority: .utility) {
            let stamp = InkStamp(of: pageID, in: store)
            let ids = Set(probes.map(\.id))
            if let previous, previous.stamp == stamp, previous.probeIDs == ids { return nil }
            let gone = goneIDs(probes) { store.readRegionInk(pageID: $0, ids: $1) != nil }
            return PageResult(stamp: stamp, probeIDs: ids, gone: gone)
        }
    }
}

// MARK: - Connections panel

/// The open page's neighbourhood in one collapsible card: the pages that
/// link here, the pages it links to, the nodes on it, and a way into the
/// Page Map. Replaces the bare "Linked from" strip. Hidden when the page
/// has no connections at all.
struct ConnectionsPanel: View {
    struct Entry: Identifiable, Equatable {
        let id: UUID
        let label: String
    }

    struct NodeEntry: Identifiable, Equatable {
        let id: UUID
        let title: String
        let isGone: Bool
    }

    /// What the card shows, computed once per change by the parent: the
    /// lists only when the card is expanded (they cost a fetch), the count
    /// always.
    struct Snapshot: Equatable {
        var count = 0
        var linkedFrom: [Entry] = []
        var linksTo: [Entry] = []
        var nodes: [NodeEntry] = []
    }

    var count: Int
    var expanded: Binding<Bool>
    var linkedFrom: [Entry] = []
    var linksTo: [Entry] = []
    var nodes: [NodeEntry] = []
    var onSelectPage: (UUID) -> Void
    var onOpenPageMap: () -> Void
    /// The open page, the notebook it is in (for labels) and the callback
    /// that makes an explicit link to a similar page. A nil page id turns
    /// "Similar pages" off.
    var pageID: UUID? = nil
    var notebookID: UUID? = nil
    var onLinkSimilar: (UUID) -> Void = { _ in }

    @Environment(\.modelContext) private var modelContext
    @State private var similar: [Entry] = []

    /// Recomputed when the card opens, the page changes, or its links do.
    private var similarKey: SimilarKey {
        SimilarKey(pageID: pageID, expanded: expanded.wrappedValue,
                   linked: Set(linkedFrom.map(\.id)).union(linksTo.map(\.id)))
    }

    private struct SimilarKey: Equatable {
        let pageID: UUID?
        let expanded: Bool
        let linked: Set<UUID>
    }

    var body: some View {
        if count > 0 {
            VStack(alignment: .leading, spacing: Space.m) {
                header
                if expanded.wrappedValue {
                    if !linkedFrom.isEmpty {
                        ConnectionSection(title: "Linked from", entries: linkedFrom, onSelect: onSelectPage)
                    }
                    if !linksTo.isEmpty {
                        ConnectionSection(title: "Links to", entries: linksTo, onSelect: onSelectPage)
                    }
                    if !nodes.isEmpty {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            SectionLabel("Nodes on this page")
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: Space.s) {
                                    ForEach(nodes) { node in
                                        Button(action: onOpenPageMap) { nodeChip(node) }
                                            .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    if !similar.isEmpty {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            SectionLabel("Similar pages")
                            ForEach(similar) { entry in
                                HStack(spacing: Space.s) {
                                    Button { onSelectPage(entry.id) } label: {
                                        Text(entry.label)
                                            .font(Typography.caption)
                                            .lineLimit(1)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.vertical, Space.xs)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    Button("Link") {
                                        onLinkSimilar(entry.id)
                                        similar.removeAll { $0.id == entry.id }
                                    }
                                    .font(Typography.caption.weight(.semibold))
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .accessibilityLabel("Link to \(entry.label)")
                                }
                            }
                        }
                    }
                    Button(action: onOpenPageMap) {
                        Label("Open Page Map", systemImage: "point.3.connected.trianglepath.dotted")
                            .font(Typography.label)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Space.s)
                            .foregroundStyle(Color.accentColor)
                            .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                                .fill(Color.accentColor.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Space.m)
            .frame(maxWidth: 340, alignment: .leading)
            .surfaceCard()
            .padding(Space.m)
            .animation(Motion.snappy, value: expanded.wrappedValue)
            .task(id: similarKey) { await refreshSimilar() }
        }
    }

    /// Top five by cosine between page vectors, minus this page and the pages
    /// already linked either way. The scoring runs off the main actor.
    private func refreshSimilar() async {
        guard expanded.wrappedValue, let pageID else { similar = []; return }
        let excluded = Set(linkedFrom.map(\.id)).union(linksTo.map(\.id)).union([pageID])
        let hits = await SemanticSearch.similarDetached(to: pageID, limit: 12, excluding: excluded).value
        guard !Task.isCancelled else { return }
        let pages = SemanticResolver.pages(for: hits, in: modelContext).prefix(5)
        similar = pages.map { .init(id: $0.id, label: LinkedFromStrip.label(for: $0, currentNotebookID: notebookID)) }
    }

    private var header: some View {
        Button { expanded.wrappedValue.toggle() } label: {
            HStack(spacing: Space.s) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(Color.accentColor)
                Text("Connections").font(Typography.headline)
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, Space.s - 2)
                    .padding(.vertical, Space.xxs)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                Spacer(minLength: Space.s)
                Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expanded.wrappedValue ? "Collapse connections" : "Expand connections")
    }

    private func nodeChip(_ node: NodeEntry) -> some View {
        HStack(spacing: Space.xs) {
            Image(systemName: node.isGone ? "scribble.variable" : "scribble").imageScale(.small)
            Text(node.title).lineLimit(1)
        }
        .font(Typography.caption.weight(.semibold))
        .foregroundStyle(node.isGone ? Color.secondary : Color.black.opacity(0.82))
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.xs + 2)
        .background(Capsule().fill(node.isGone ? Color.secondary.opacity(0.18) : Palette.node))
    }
}

/// One titled list of pages, capped at five with the rest in a menu.
private struct ConnectionSection: View {
    let title: String
    let entries: [ConnectionsPanel.Entry]
    let onSelect: (UUID) -> Void

    var body: some View {
        let parts = LinkedFromStrip.split(entries)
        VStack(alignment: .leading, spacing: Space.xs) {
            SectionLabel(title)
            ForEach(parts.shown) { entry in
                Button { onSelect(entry.id) } label: {
                    Text(entry.label)
                        .font(Typography.caption)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Space.xs)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if !parts.hidden.isEmpty {
                Menu {
                    ForEach(parts.hidden) { entry in
                        Button(entry.label) { onSelect(entry.id) }
                    }
                } label: {
                    Text("and \(parts.hidden.count) more")
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
