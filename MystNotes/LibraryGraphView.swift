import SwiftUI
import SwiftData

// MARK: - Model (pure)

/// What the Library Map needs to know about one notebook, as plain values:
/// aggregated, filtered and laid out off the main actor and in tests.
nonisolated struct LibraryMapNotebook: Hashable, Sendable {
    var id: UUID
    var title: String
    var coverStyle: String
    var folderID: UUID?
    var folderName: String?
    var pageCount: Int
    var modifiedAt: Date
    var isLocked: Bool

    init(id: UUID = UUID(), title: String = "", coverStyle: String = "default", folderID: UUID? = nil,
         folderName: String? = nil, pageCount: Int = 0, modifiedAt: Date = Date(), isLocked: Bool = false) {
        self.id = id
        self.title = title
        self.coverStyle = coverStyle
        self.folderID = folderID
        self.folderName = folderName
        self.pageCount = pageCount
        self.modifiedAt = modifiedAt
        self.isLocked = isLocked
    }

    @MainActor
    init(notebook: Notebook) {
        self.init(id: notebook.id, title: notebook.title, coverStyle: notebook.coverStyle,
                  folderID: notebook.folder?.id, folderName: notebook.folder?.name,
                  pageCount: notebook.pages?.count ?? 0, modifiedAt: notebook.modifiedAt,
                  isLocked: notebook.isLocked == true)
    }

    var displayTitle: String { title.isEmpty ? "Untitled" : title }
}

/// All the links between two notebooks, as one edge.
nonisolated struct LibraryMapEdge: Hashable, Sendable {
    /// `a.uuidString < b.uuidString`: an edge has no direction here.
    var a: UUID
    var b: UUID
    var count: Int

    func touches(_ id: UUID) -> Bool { a == id || b == id }
    func other(than id: UUID) -> UUID { a == id ? b : a }
}

/// M2 task 12: the library as a graph. Nodes are notebooks, an edge is every
/// link between two of them. Built once by `build`, not per frame.
nonisolated struct LibraryMapData: Sendable, Equatable {
    /// Sorted by id, so every launch lays out the same.
    var notebooks: [LibraryMapNotebook] = []
    var edges: [LibraryMapEdge] = []
    /// Links that touch each notebook (a notebook with none is absent).
    var linkCounts: [UUID: Int] = [:]

    var maxWeight: Int { edges.map(\.count).max() ?? 0 }

    /// Pure core. `pageNotebook` maps a page id to its notebook; pages that
    /// aren't in it (the templates notebook's, or deleted ones) drop their
    /// links. Links inside one notebook never count.
    static func build(notebooks: [LibraryMapNotebook], pageNotebook: [UUID: UUID],
                      links: [(source: UUID, destination: UUID)]) -> LibraryMapData {
        let known = Set(notebooks.map(\.id))
        var weights: [UUID: [UUID: Int]] = [:]
        for link in links {
            guard let s = pageNotebook[link.source], let d = pageNotebook[link.destination],
                  s != d, known.contains(s), known.contains(d) else { continue }
            let (a, b) = s.uuidString < d.uuidString ? (s, d) : (d, s)
            weights[a, default: [:]][b, default: 0] += 1
        }
        var edges: [LibraryMapEdge] = []
        for (a, row) in weights { for (b, n) in row { edges.append(LibraryMapEdge(a: a, b: b, count: n)) } }
        edges.sort { ($0.a.uuidString, $0.b.uuidString) < ($1.a.uuidString, $1.b.uuidString) }
        var counts: [UUID: Int] = [:]
        for e in edges { counts[e.a, default: 0] += e.count; counts[e.b, default: 0] += e.count }
        return LibraryMapData(notebooks: notebooks.sorted { $0.id.uuidString < $1.id.uuidString },
                              edges: edges, linkCounts: counts)
    }

    /// From the models. The templates notebook is left out.
    @MainActor
    static func make(notebooks stored: [Notebook], links: [Link]) -> LibraryMapData {
        let shown = PageTemplates.libraryNotebooks(stored)
        var pageNotebook: [UUID: UUID] = [:]
        for notebook in shown { for page in notebook.pages ?? [] { pageNotebook[page.id] = notebook.id } }
        return build(notebooks: shown.map { LibraryMapNotebook(notebook: $0) }, pageNotebook: pageNotebook,
                     links: links.map { ($0.sourcePageID, $0.destinationPageID) })
    }

    /// The notebooks linked to `id`, most links first (ties by id).
    func neighbours(of id: UUID) -> [(id: UUID, count: Int)] {
        edges.filter { $0.touches(id) }
            .map { (id: $0.other(than: id), count: $0.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.id.uuidString < $1.id.uuidString }
    }

    var folders: [(id: UUID, name: String)] {
        var seen = Set<UUID>()
        var out: [(id: UUID, name: String)] = []
        for n in notebooks {
            if let id = n.folderID, seen.insert(id).inserted { out.append((id, n.folderName ?? "")) }
        }
        return out.sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
    }

    /// 1 pt for the lightest edge, 6 pt for the heaviest.
    static func strokeWidth(count: Int, maxCount: Int) -> CGFloat {
        guard maxCount > 1, count > 1 else { return 1 }
        return 1 + 5 * CGFloat(min(count, maxCount) - 1) / CGFloat(maxCount - 1)
    }

    @MainActor
    static func layoutInput(_ data: LibraryMapData) -> GraphForceLayout.Input {
        let ids = data.notebooks.map(\.id)
        // Start on an ellipse, as the Page Map does, so the result never depends on chance.
        let ring = NotebookGraphView.layout(pageIDs: ids, edges: [],
                                            in: CGSize(width: GraphWorld.size, height: GraphWorld.size))
        var seeds: [GraphNodeID: CGPoint] = [:]
        for id in ids { seeds[.page(id)] = ring[id] }
        return GraphForceLayout.Input(nodes: ids.map { .page($0) },
                                      edges: data.edges.map { GraphForceLayout.Pair(a: .page($0.a), b: .page($0.b)) },
                                      seeds: seeds, fixed: [])
    }
}

/// What the user narrowed the library map to. Never hides a notebook: those
/// that don't match are dimmed.
nonisolated struct LibraryMapFilter: Equatable, Sendable {
    /// Folder ids; `nil` stands for "not in a folder". Empty means all.
    var folders: Set<UUID?> = []
    var since: Date?
    var searchText: String = ""

    var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isActive: Bool { !folders.isEmpty || since != nil || !query.isEmpty }

    struct Result: Equatable, Sendable {
        var dimmed: Set<UUID> = []
        var highlighted: Set<UUID> = []
    }

    func apply(to notebooks: [LibraryMapNotebook]) -> Result {
        var result = Result()
        guard isActive else { return result }
        let needle = query
        for n in notebooks {
            var matches = true
            if !folders.isEmpty { matches = matches && folders.contains(n.folderID) }
            if let since { matches = matches && n.modifiedAt >= since }
            if !needle.isEmpty {
                let hit = n.title.localizedStandardContains(needle)
                    || (n.folderName?.localizedStandardContains(needle) ?? false)
                matches = matches && hit
                if hit { result.highlighted.insert(n.id) }
            }
            if !matches { result.dimmed.insert(n.id) }
        }
        result.highlighted.subtract(result.dimmed)
        return result
    }
}

// MARK: - View

/// M2 task 12: the Library Map. Notebooks are cards in a fixed 2000 x 2000
/// world you can pan and zoom; an edge's width is how many links join two
/// notebooks. Same viewport maths and layout as the Page Map.
struct LibraryGraphView: View {
    let notebooks: [Notebook]
    let onOpenNotebook: (Notebook) -> Void
    /// Offered in the inspector when the caller can open a notebook straight
    /// onto its Page Map.
    var onOpenPageMap: ((Notebook) -> Void)? = nil

    @Query private var links: [Link]
    @Environment(\.dismiss) private var dismiss

    @State private var data: LibraryMapData?
    @State private var computed: [GraphNodeID: CGPoint] = [:]
    @State private var viewport = GraphViewport()
    @GestureState private var pinch = PinchState()
    @GestureState private var pan = CGSize.zero
    @State private var selected: UUID?
    @State private var hovered: UUID?
    @State private var filter = LibraryMapFilter()
    @State private var sinceDays: Int?
    @State private var showingFilter = false
    @State private var didFit = false
    @State private var viewSize: CGSize = .zero

    private struct PinchState {
        var magnification: CGFloat = 1
        var anchor: UnitPoint = .center
    }

    private static let inspectorInset: CGFloat = 168
    private static let half = CGSize(width: GraphGeometry.cardSize.width / 2, height: GraphGeometry.cardSize.height / 2)

    /// Recompute the aggregation only when this changes.
    private var dataKey: Int {
        var h = Hasher()
        h.combine(links.count)
        h.combine(notebooks.count)
        for n in notebooks {
            h.combine(n.id); h.combine(n.title); h.combine(n.coverStyle); h.combine(n.role)
            h.combine(n.folder?.id); h.combine(n.pages?.count ?? 0); h.combine(n.isLocked)
        }
        return h.finalize()
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                content(size: geo.size)
                    .onChange(of: geo.size, initial: true) { _, new in
                        viewSize = new
                        fitIfNeeded()
                    }
            }
            .navigationTitle("Library Map")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $filter.searchText, prompt: "Highlight notebooks")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { fit(animated: true) } label: {
                        Label("Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
                    }
                    .accessibilityHint("Zooms to show every notebook")
                    Button { showingFilter.toggle() } label: {
                        Label("Filter", systemImage: filter.isActive
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                    }
                    .popover(isPresented: $showingFilter) {
                        LibraryMapFilterPanel(filter: $filter, sinceDays: $sinceDays, folders: data?.folders ?? [])
                            .presentationCompactAdaptation(.popover)
                    }
                }
            }
            // The aggregation: one pass over the pages and links, when they change.
            .task(id: dataKey) {
                data = LibraryMapData.make(notebooks: notebooks, links: links)
            }
            .task(id: data.map { LibraryMapData.layoutInput($0) }) {
                guard let data else { return }
                // ponytail: persist if asked
                let result = await GraphForceLayout.runDetached(LibraryMapData.layoutInput(data))
                guard !Task.isCancelled else { return }
                computed = result
                fitIfNeeded()
            }
        }
    }

    // MARK: Geometry

    private func point(_ id: UUID) -> CGPoint {
        computed[.page(id)] ?? CGPoint(x: GraphWorld.size / 2, y: GraphWorld.size / 2)
    }

    private func contentRect() -> CGRect {
        var rect: CGRect?
        for n in data?.notebooks ?? [] {
            let p = point(n.id)
            let r = CGRect(x: p.x - Self.half.width, y: p.y - Self.half.height,
                           width: Self.half.width * 2, height: Self.half.height * 2)
            rect = rect.map { $0.union(r) } ?? r
        }
        return rect ?? GraphWorld.bounds
    }

    private func effectiveViewport(_ size: CGSize) -> GraphViewport {
        var v = viewport
        if pinch.magnification != 1 {
            v = v.zoomed(by: pinch.magnification,
                         around: CGPoint(x: pinch.anchor.x * size.width, y: pinch.anchor.y * size.height))
        }
        return v.panned(by: pan)
    }

    private func fit(animated: Bool) {
        let target = GraphViewport.fitting(contentRect(), in: viewSize)
        if animated { withAnimation(Motion.gentle) { viewport = target } } else { viewport = target }
    }

    private func fitIfNeeded() {
        guard !didFit, viewSize.width > 0, viewSize.height > 0, let data else { return }
        guard !computed.isEmpty || data.notebooks.isEmpty else { return }
        fit(animated: false)
        withAnimation(Motion.gentle) { didFit = true }
    }

    private func center(on world: CGPoint) {
        withAnimation(Motion.gentle) {
            viewport = GraphViewport.centered(on: world, scale: max(viewport.scale, 0.8), in: viewSize,
                                              bottomInset: Self.inspectorInset)
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(size: CGSize) -> some View {
        if let data {
            mapContent(data: data, size: size)
        } else {
            Color.clear.frame(width: size.width, height: size.height)
        }
    }

    private func mapContent(data: LibraryMapData, size: CGSize) -> some View {
        let result = filter.apply(to: data.notebooks)
        let eff = effectiveViewport(size)
        let focus = hovered ?? selected
        let byID = Dictionary(uniqueKeysWithValues: data.notebooks.map { ($0.id, $0) })
        let selectedInfo = selected.flatMap { byID[$0] }

        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.background)
                .overlay(Color.primary.opacity(0.025))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .updating($pan) { value, state, _ in state = value.translation }
                        .onEnded { value in viewport = viewport.panned(by: value.translation) })
                .onTapGesture(count: 2) { fit(animated: true) }
                .onTapGesture { withAnimation(Motion.quick) { selected = nil } }
                .accessibilityHidden(true)

            Color.clear
                .overlay(alignment: .topLeading) {
                    world(data: data, result: result, focus: focus)
                        .frame(width: GraphWorld.size, height: GraphWorld.size, alignment: .topLeading)
                        .scaleEffect(eff.scale, anchor: .topLeading)
                        .offset(x: eff.offset.x, y: eff.offset.y)
                        .opacity(didFit ? 1 : 0)
                }
                .allowsHitTesting(didFit)

            if data.edges.isEmpty {
                LibraryMapEmptyState(hasNotebooks: !data.notebooks.isEmpty)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, Space.xl)
                    .padding(.horizontal, Space.l)
                    .allowsHitTesting(false)
            }

            if !data.notebooks.isEmpty {
                LibraryMapMiniMap(map: miniMap(eff, size), data: data, points: computed,
                                  viewportRect: eff.visibleWorldRect(in: size),
                                  onJump: { viewport = GraphViewport.centered(on: $0, scale: viewport.scale, in: size) })
                    .frame(width: 148, height: 108)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(Space.m)
                    .opacity(didFit ? 1 : 0)
            }

            if let info = selectedInfo, let notebook = notebooks.first(where: { $0.id == info.id }) {
                LibraryMapInspector(info: info,
                                    neighbours: data.neighbours(of: info.id).prefix(4).compactMap { n in
                                        byID[n.id].map { (info: $0, count: n.count) }
                                    },
                                    totalLinks: data.linkCounts[info.id] ?? 0,
                                    onSelect: { id in
                                        withAnimation(Motion.snappy) { selected = id }
                                        center(on: point(id))
                                    },
                                    onOpen: { onOpenNotebook(notebook) },
                                    onOpenPageMap: onOpenPageMap.map { open in { open(notebook) } },
                                    onCenter: { center(on: point(info.id)) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(Space.m)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .gesture(
            MagnifyGesture()
                .updating($pinch) { value, state, _ in
                    state = PinchState(magnification: value.magnification, anchor: value.startAnchor)
                }
                .onEnded { value in
                    viewport = viewport.zoomed(by: value.magnification,
                                               around: CGPoint(x: value.startAnchor.x * size.width,
                                                               y: value.startAnchor.y * size.height))
                })
        .animation(Motion.gentle, value: selected)
    }

    private func miniMap(_ eff: GraphViewport, _ size: CGSize) -> GraphMiniMap {
        let bounds = contentRect().union(eff.visibleWorldRect(in: size)).insetBy(dx: -40, dy: -40)
        return GraphMiniMap(bounds: bounds, size: CGSize(width: 140, height: 100))
    }

    private func world(data: LibraryMapData, result: LibraryMapFilter.Result, focus: UUID?) -> some View {
        let maxWeight = data.maxWeight
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                .strokeBorder(Palette.separator, lineWidth: 2)
                .frame(width: GraphWorld.size, height: GraphWorld.size)
                .allowsHitTesting(false)

            ForEach(data.edges, id: \.self) { edge in
                if let curve = GraphGeometry.curve(from: point(edge.a), aHalf: Self.half,
                                                   to: point(edge.b), bHalf: Self.half) {
                    let active = focus.map { edge.touches($0) } ?? false
                    let dimmed = result.dimmed.contains(edge.a) || result.dimmed.contains(edge.b)
                    LibraryMapEdgeView(curve: curve, count: edge.count,
                                       width: LibraryMapData.strokeWidth(count: edge.count, maxCount: maxWeight),
                                       showsLabel: active)
                        .opacity(dimmed ? GraphFilter.dimmedOpacity
                                 : (focus == nil || active ? 1 : 0.25))
                        .animation(Motion.quick, value: focus)
                }
            }

            ForEach(data.notebooks, id: \.id) { info in
                let isSelected = selected == info.id
                let links = data.linkCounts[info.id] ?? 0
                LibraryMapCard(info: info, links: links, isSelected: isSelected,
                               isMatch: result.highlighted.contains(info.id), isHovered: hovered == info.id)
                    .frame(width: GraphGeometry.cardSize.width, height: GraphGeometry.cardSize.height)
                    .opacity(result.dimmed.contains(info.id) ? GraphFilter.dimmedOpacity
                             : (links == 0 && !data.edges.isEmpty ? 0.6 : 1))
                    .animation(Motion.gentle, value: result.dimmed)
                    .onHover { inside in
                        if inside { hovered = info.id } else if hovered == info.id { hovered = nil }
                    }
                    .onTapGesture(count: 2) {
                        if let notebook = notebooks.first(where: { $0.id == info.id }) { onOpenNotebook(notebook) }
                    }
                    .onTapGesture { withAnimation(Motion.snappy) { selected = info.id } }
                    .position(point(info.id))
                    .zIndex(isSelected ? 3 : 2)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(info.displayTitle), \(info.pageCount) page\(info.pageCount == 1 ? "" : "s"), \(links) link\(links == 1 ? "" : "s")"
                                        + (info.isLocked ? ", locked" : ""))
                    .accessibilityHint("Double tap to select. Use Open Notebook in the inspector to go there.")
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

// MARK: - Pieces

private struct LibraryMapCard: View {
    let info: LibraryMapNotebook
    let links: Int
    let isSelected: Bool
    let isMatch: Bool
    let isHovered: Bool

    private var tint: Color? {
        info.folderName.map { Color(hue: GraphGeometry.tagHue($0), saturation: 0.45, brightness: 0.9) }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
        HStack(spacing: 0) {
            Rectangle()
                .fill(LinearGradient(colors: [NotebookCoverView.color(for: info.coverStyle).opacity(0.88),
                                              NotebookCoverView.color(for: info.coverStyle)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.xs) {
                    Text(info.displayTitle)
                        .font(Typography.headline)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if info.isLocked {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if let folder = info.folderName {
                    Text(folder).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                }
                Text("\(info.pageCount) page\(info.pageCount == 1 ? "" : "s") \u{00B7} \(links) link\(links == 1 ? "" : "s")")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(Space.s + 2)
        }
        .background(shape.fill(.regularMaterial))
        .background(shape.fill((tint ?? .clear).opacity(0.28)))
        .clipShape(shape)
        .overlay(shape.strokeBorder(isSelected || isMatch ? Palette.selectionRing
                                    : (tint ?? Color.primary).opacity(tint == nil ? 0.08 : 0.5),
                                    lineWidth: isSelected || isMatch ? 3 : 1))
        .shadow(color: .black.opacity(isSelected || isHovered ? 0.22 : 0.1), radius: isSelected ? 14 : 6, y: 3)
        .scaleEffect(isHovered ? 1.03 : 1)
        .animation(Motion.quick, value: isHovered)
    }
}

private struct LibraryMapEdgeShape: Shape {
    let curve: GraphGeometry.Curve

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: curve.start)
        p.addQuadCurve(to: curve.end, control: curve.control)
        return p
    }
}

private struct LibraryMapEdgeView: View {
    let curve: GraphGeometry.Curve
    let count: Int
    let width: CGFloat
    let showsLabel: Bool

    var body: some View {
        // The curve's midpoint, t = 0.5.
        let mid = CGPoint(x: 0.25 * curve.start.x + 0.5 * curve.control.x + 0.25 * curve.end.x,
                          y: 0.25 * curve.start.y + 0.5 * curve.control.y + 0.25 * curve.end.y)
        ZStack(alignment: .topLeading) {
            LibraryMapEdgeShape(curve: curve)
                .stroke(Palette.edgeExplicit.opacity(0.7), style: StrokeStyle(lineWidth: width, lineCap: .round))
            if showsLabel {
                Text("\(count)")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .padding(.horizontal, Space.s)
                    .padding(.vertical, Space.xxs)
                    .background(Capsule().fill(.regularMaterial))
                    .overlay(Capsule().strokeBorder(Palette.separator, lineWidth: Metrics.hairline))
                    .position(mid)
            }
        }
        .frame(width: GraphWorld.size, height: GraphWorld.size, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct LibraryMapInspector: View {
    let info: LibraryMapNotebook
    let neighbours: [(info: LibraryMapNotebook, count: Int)]
    let totalLinks: Int
    let onSelect: (UUID) -> Void
    let onOpen: () -> Void
    let onOpenPageMap: (() -> Void)?
    let onCenter: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(info.displayTitle).font(Typography.headline).lineLimit(1)
                Text("\(info.pageCount) page\(info.pageCount == 1 ? "" : "s") \u{00B7} \(totalLinks) link\(totalLinks == 1 ? "" : "s") to other notebooks")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                if neighbours.isEmpty {
                    Text("Not linked to another notebook yet")
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Space.xs) {
                            ForEach(Array(neighbours.enumerated()), id: \.offset) { _, n in
                                Button { onSelect(n.info.id) } label: {
                                    Chip(title: "\(n.info.displayTitle) \u{00B7} \(n.count)")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: Space.s) {
                Button(action: onOpen) {
                    Label("Open Notebook", systemImage: "arrow.up.right.square").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                if let onOpenPageMap {
                    Button(action: onOpenPageMap) {
                        Label("Open Page Map", systemImage: "point.3.connected.trianglepath.dotted")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                Button(action: onCenter) {
                    Label("Center", systemImage: "scope").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .frame(width: 170)
        }
        .padding(Space.l)
        .surfaceCard()
        .frame(maxWidth: 620)
        .accessibilityElement(children: .contain)
    }
}

private struct LibraryMapEmptyState: View {
    let hasNotebooks: Bool

    var body: some View {
        VStack(spacing: Space.s) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(Palette.node)
            Text(hasNotebooks ? "No links between notebooks yet" : "Nothing to map yet")
                .font(Typography.title)
            Text("Link a page in one notebook to a page in another and the two notebooks connect here. Lasso some ink and choose Link This To\u{2026}, then pick a page in another notebook, or type [[ in a text box to mention one.")
                .font(Typography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(Space.xl)
        .frame(maxWidth: 440)
        .surfaceCard(radius: Radius.l)
        .accessibilityElement(children: .combine)
    }
}

private struct LibraryMapMiniMap: View {
    let map: GraphMiniMap
    let data: LibraryMapData
    let points: [GraphNodeID: CGPoint]
    let viewportRect: CGRect
    let onJump: (CGPoint) -> Void

    var body: some View {
        // Copied out of `self` so the renderer closure touches only values.
        let dataCopy = self.data, pointsCopy = self.points, mapCopy = self.map, viewCopy = self.viewportRect
        let accent = Color.accentColor
        return Canvas { ctx, _ in
            for n in dataCopy.notebooks {
                guard let p = pointsCopy[.page(n.id)] else { continue }
                let r = mapCopy.toMini(CGRect(x: p.x - GraphGeometry.cardSize.width / 2, y: p.y - GraphGeometry.cardSize.height / 2,
                                          width: GraphGeometry.cardSize.width, height: GraphGeometry.cardSize.height))
                ctx.fill(Path(roundedRect: r.insetBy(dx: -0.5, dy: -0.5), cornerRadius: 1.5),
                         with: .color(accent.opacity(0.55)))
            }
            let v = mapCopy.toMini(viewCopy)
            ctx.stroke(Path(roundedRect: v, cornerRadius: 2), with: .color(accent), lineWidth: 1.5)
            ctx.fill(Path(roundedRect: v, cornerRadius: 2), with: .color(accent.opacity(0.08)))
        }
        .padding(Space.xs)
        .surfaceCard(radius: Radius.m)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    onJump(map.toWorld(CGPoint(x: value.location.x - Space.xs, y: value.location.y - Space.xs)))
                })
        .accessibilityLabel("Map overview")
        .accessibilityHint("Drag to move around the map")
    }
}

private struct LibraryMapFilterPanel: View {
    @Binding var filter: LibraryMapFilter
    @Binding var sinceDays: Int?
    let folders: [(id: UUID, name: String)]

    private static let presets: [(days: Int?, title: String)] = [
        (nil, "Any time"), (7, "7 days"), (30, "30 days"), (90, "90 days")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.s) {
                SectionLabel("Edited since")
                HStack(spacing: Space.xs) {
                    ForEach(Array(Self.presets.enumerated()), id: \.offset) { _, preset in
                        Button {
                            sinceDays = preset.days
                            filter.since = preset.days.flatMap { Calendar.current.date(byAdding: .day, value: -$0, to: Date()) }
                        } label: {
                            Chip(title: preset.title, isSelected: sinceDays == preset.days)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            VStack(alignment: .leading, spacing: Space.s) {
                SectionLabel("Folders")
                if folders.isEmpty {
                    Text("No notebooks are in a folder.").font(Typography.caption).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            ForEach(Array(folders.enumerated()), id: \.offset) { _, folder in
                                let on = filter.folders.contains(folder.id)
                                Button {
                                    if on { filter.folders.remove(folder.id) } else { filter.folders.insert(folder.id) }
                                } label: {
                                    Chip(title: folder.name.isEmpty ? "Untitled Folder" : folder.name, systemImage: "folder",
                                         isSelected: on,
                                         tint: Color(hue: GraphGeometry.tagHue(folder.name), saturation: 0.55, brightness: 0.7))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            }
            Text("Notebooks that don't match fade; none are hidden.")
                .font(Typography.caption)
                .foregroundStyle(.secondary)
            if filter.isActive {
                Button("Clear Filters") { filter = LibraryMapFilter(); sinceDays = nil }
                    .buttonStyle(.bordered)
            }
        }
        .padding(Space.l)
        .frame(width: 340)
    }
}
