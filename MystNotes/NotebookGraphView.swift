import SwiftUI

/// M2: the map of one notebook. Pages are cards in a fixed 2000 x 2000 world
/// you can pan and zoom; links are curved edges; named regions of ink (nodes)
/// orbit their page as amber chips; tags are small capsule nodes.
///
/// Layout (`GraphForceLayout`) runs off the main thread and only places cards
/// the user hasn't moved. Everything drawn lives in one container that is
/// scaled and offset as a whole, so panning and zooming move a transform and
/// never re-lay-out a card.
struct NotebookGraphView: View {
    let pages: [Page]
    let links: [Link]
    /// Positions the user set, in fractions of the world (`Notebook.graphPositions`).
    var positions: [UUID: CGPoint]
    /// A card was dropped at this position, in fractions of the world.
    var onMove: (UUID, CGPoint) -> Void
    /// Node links whose ink is gone; their chips are drawn grey.
    var goneNodeIDs: Set<UUID>
    /// Each page's artwork, for thumbnails (the caller already has it; a
    /// `@Query` here would run once per card).
    var documents: [UUID: [ImportedDocument]]
    /// Pages of other notebooks that links from or to this notebook reach:
    /// ghost cards. A tap on one calls `onSelect` with its (foreign) page id.
    var foreignPages: [UUID: GraphForeignPage]
    let onSelect: (UUID) -> Void

    init(pages: [Page], links: [Link],
         positions: [UUID: CGPoint] = [:],
         onMove: @escaping (UUID, CGPoint) -> Void = { _, _ in },
         goneNodeIDs: Set<UUID> = [],
         documents: [UUID: [ImportedDocument]] = [:],
         foreignPages: [UUID: GraphForeignPage] = [:],
         onSelect: @escaping (UUID) -> Void) {
        self.pages = pages
        self.links = links
        self.positions = positions
        self.onMove = onMove
        self.goneNodeIDs = goneNodeIDs
        self.documents = documents
        self.foreignPages = foreignPages
        self.onSelect = onSelect
    }

    // MARK: State

    @State private var viewport = GraphViewport()
    @GestureState private var pinch = PinchState()
    @GestureState private var pan = CGSize.zero
    /// The force layout's last answer.
    @State private var computed: [GraphNodeID: CGPoint] = [:]
    /// Positions dropped this session, in world points, until the caller's
    /// `positions` catches up (so a dropped card never snaps back for a frame).
    @State private var localPlaced: [UUID: CGPoint] = [:]
    @State private var dragging: Dragging?
    @State private var selected: UUID?
    @State private var hovered: UUID?
    @State private var filter = GraphFilter()
    @State private var showingFilter = false
    @State private var didFit = false
    @State private var viewSize: CGSize = .zero

    private struct PinchState {
        var magnification: CGFloat = 1
        var anchor: UnitPoint = .center
    }

    private struct Dragging {
        var id: UUID
        var world: CGPoint
    }

    private static let space = "graphViewport"
    private static let inspectorInset: CGFloat = 168
    /// Thumbnails cost a render each; beyond this many pages, cards use an icon.
    private static let thumbnailPageLimit = 60

    // MARK: Pure helpers (kept as statics so tests drive them)

    static var cardSize: CGSize { GraphGeometry.cardSize }

    /// Links between two pages of this notebook, each pair once, never a self-link.
    static func edges(pages: [Page], links: [Link]) -> [(UUID, UUID)] {
        let ids = Set(pages.map(\.id))
        var seen = Set<[UUID]>()
        var result: [(UUID, UUID)] = []
        for l in links where l.sourcePageID != l.destinationPageID
            && ids.contains(l.sourcePageID) && ids.contains(l.destinationPageID) {
            if seen.insert([l.sourcePageID, l.destinationPageID]).inserted {
                result.append((l.sourcePageID, l.destinationPageID))
            }
        }
        return result
    }

    /// Pages on an ellipse inscribed in `size`, first page at the top,
    /// clockwise. Pure and deterministic. The force layout starts from this
    /// (with `size` the world).
    static func layout(pageIDs: [UUID], edges: [(UUID, UUID)], in size: CGSize) -> [UUID: CGPoint] {
        let n = pageIDs.count
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let rx = max(0, size.width / 2 - cardSize.width / 2 - 8)
        let ry = max(0, size.height / 2 - cardSize.height / 2 - 8)
        var out: [UUID: CGPoint] = [:]
        for (i, id) in pageIDs.enumerated() {
            if n == 1 { out[id] = center; continue }
            let a = -Double.pi / 2 + 2 * Double.pi * Double(i) / Double(n)
            out[id] = CGPoint(x: center.x + rx * cos(a), y: center.y + ry * sin(a))
        }
        return out
    }

    /// Computed positions (world points), overridden by saved ones (fractions
    /// of the world), then by a card being dragged (a world point). Saved
    /// positions for pages that are gone are ignored.
    static func placed(_ computed: [UUID: CGPoint], saved: [UUID: CGPoint],
                       dragging: (id: UUID, world: CGPoint)? = nil) -> [UUID: CGPoint] {
        var points = computed
        for (id, fraction) in saved where points[id] != nil {
            points[id] = GraphWorld.point(fromFraction: fraction)
        }
        if let dragging, points[dragging.id] != nil { points[dragging.id] = dragging.world }
        return points
    }

    // MARK: Body

    var body: some View {
        let scene = GraphScene.build(pages: pages, links: links, foreignPages: foreignPages)
        let input = layoutInput(scene)
        NavigationStack {
            GeometryReader { geo in
                content(scene: scene, input: input, size: geo.size)
                    .onChange(of: geo.size, initial: true) { _, new in
                        viewSize = new
                        fitIfNeeded(scene, input)
                    }
            }
            .navigationTitle("Page Map")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $filter.searchText, prompt: "Highlight pages")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { fit(scene, input, animated: true) } label: {
                        Label("Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
                    }
                    .accessibilityHint("Zooms to show every page")
                    Button { showingFilter.toggle() } label: {
                        Label("Filter", systemImage: filter.isActive
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                    }
                    .popover(isPresented: $showingFilter) {
                        GraphFilterPanel(filter: $filter, tags: scene.tags)
                            .presentationCompactAdaptation(.popover)
                    }
                }
            }
            .task(id: input) {
                let result = await GraphForceLayout.runDetached(input)
                guard !Task.isCancelled else { return }
                computed = result
                fitIfNeeded(scene, input)
            }
            .onChange(of: positions) { _, _ in localPlaced = [:] }
        }
    }

    // MARK: Layout plumbing

    /// Saved positions as fractions: the caller's, plus this session's drops.
    private func mergedSaved() -> [UUID: CGPoint] {
        var saved = positions
        for (id, world) in localPlaced { saved[id] = GraphWorld.fraction(from: world) }
        return saved
    }

    private func layoutInput(_ scene: GraphScene) -> GraphForceLayout.Input {
        let ids = scene.pages.map(\.id)
        let ellipse = Self.layout(pageIDs: ids, edges: [],
                                  in: CGSize(width: GraphWorld.size, height: GraphWorld.size))
        let saved = mergedSaved()
        var seeds: [GraphNodeID: CGPoint] = [:]
        var fixed = Set<GraphNodeID>()
        for id in ids {
            if let fraction = saved[id] {
                seeds[.page(id)] = GraphWorld.point(fromFraction: fraction)
                fixed.insert(.page(id))
            } else if let p = ellipse[id] {
                seeds[.page(id)] = p
            }
        }
        // A ghost starts outside the card it hangs from, away from the middle.
        let middle = CGPoint(x: GraphWorld.size / 2, y: GraphWorld.size / 2)
        for ghost in scene.ghosts {
            let anchors = scene.edges.compactMap { e -> CGPoint? in
                if e.from == .page(ghost.id) { if case .page(let o) = e.to { return seeds[.page(o)] } }
                if e.to == .page(ghost.id) { if case .page(let o) = e.from { return seeds[.page(o)] } }
                return nil
            }
            guard !anchors.isEmpty else { continue }
            let ax = anchors.map(\.x).reduce(0, +) / CGFloat(anchors.count)
            let ay = anchors.map(\.y).reduce(0, +) / CGFloat(anchors.count)
            let dx = ax - middle.x, dy = ay - middle.y
            let length = max((dx * dx + dy * dy).squareRoot(), 1)
            seeds[.page(ghost.id)] = CGPoint(x: ax + dx / length * 260, y: ay + dy / length * 260)
        }
        for tag in scene.tags {
            let pts = tag.pageIDs.compactMap { seeds[.page($0)] }
            guard !pts.isEmpty else { continue }
            seeds[.tag(tag.key)] = CGPoint(x: pts.map(\.x).reduce(0, +) / CGFloat(pts.count),
                                           y: pts.map(\.y).reduce(0, +) / CGFloat(pts.count))
        }
        return GraphForceLayout.Input(nodes: scene.layoutNodes, edges: scene.layoutPairs, seeds: seeds, fixed: fixed)
    }

    /// Every page's centre, without a drag in progress.
    private func pagePoints(_ scene: GraphScene, _ input: GraphForceLayout.Input) -> [UUID: CGPoint] {
        let middle = CGPoint(x: GraphWorld.size / 2, y: GraphWorld.size / 2)
        var base: [UUID: CGPoint] = [:]
        for page in scene.pages {
            base[page.id] = computed[.page(page.id)] ?? input.seeds[.page(page.id)] ?? middle
        }
        return Self.placed(base, saved: mergedSaved())
    }

    /// Every node's centre: pages, then tags, then chips orbiting their page.
    private func allPoints(_ scene: GraphScene, _ input: GraphForceLayout.Input,
                           pages base: [UUID: CGPoint]) -> [GraphNodeID: CGPoint] {
        let middle = CGPoint(x: GraphWorld.size / 2, y: GraphWorld.size / 2)
        var out: [GraphNodeID: CGPoint] = [:]
        for (id, p) in base { out[.page(id)] = p }
        for ghost in scene.ghosts {
            out[.page(ghost.id)] = computed[.page(ghost.id)] ?? input.seeds[.page(ghost.id)] ?? middle
        }
        if let dragging, out[.page(dragging.id)] != nil { out[.page(dragging.id)] = dragging.world }
        for tag in scene.tags {
            out[.tag(tag.key)] = computed[.tag(tag.key)] ?? input.seeds[.tag(tag.key)] ?? middle
        }
        let byPage = Dictionary(grouping: scene.chips, by: \.pageID)
        for (pageID, chips) in byPage {
            guard let centre = out[.page(pageID)] else { continue }
            for (chip, p) in zip(chips, GraphGeometry.chipCenters(around: centre, count: chips.count)) {
                out[.chip(chip.linkID)] = p
            }
        }
        return out
    }

    private func halfSize(_ node: GraphNodeID, _ scene: GraphScene) -> CGSize {
        switch node {
        case .page: return CGSize(width: GraphGeometry.cardSize.width / 2, height: GraphGeometry.cardSize.height / 2)
        case .chip: return CGSize(width: GraphGeometry.chipSize.width / 2, height: GraphGeometry.chipSize.height / 2)
        case .tag(let key):
            let name = scene.tags.first { $0.key == key }?.name ?? key
            let s = GraphGeometry.tagSize(name: name)
            return CGSize(width: s.width / 2, height: s.height / 2)
        }
    }

    private func contentRect(_ scene: GraphScene, _ points: [GraphNodeID: CGPoint]) -> CGRect? {
        var rect: CGRect?
        for (node, p) in points {
            let h = halfSize(node, scene)
            let r = CGRect(x: p.x - h.width, y: p.y - h.height, width: h.width * 2, height: h.height * 2)
            rect = rect.map { $0.union(r) } ?? r
        }
        return rect
    }

    // MARK: Viewport

    private func effectiveViewport(_ size: CGSize) -> GraphViewport {
        var v = viewport
        if pinch.magnification != 1 {
            v = v.zoomed(by: pinch.magnification,
                         around: CGPoint(x: pinch.anchor.x * size.width, y: pinch.anchor.y * size.height))
        }
        return v.panned(by: pan)
    }

    private func fit(_ scene: GraphScene, _ input: GraphForceLayout.Input, animated: Bool) {
        let points = allPoints(scene, input, pages: pagePoints(scene, input))
        let rect = contentRect(scene, points) ?? GraphWorld.bounds
        let target = GraphViewport.fitting(rect, in: viewSize)
        if animated {
            withAnimation(Motion.gentle) { viewport = target }
        } else {
            viewport = target
        }
    }

    /// The first fit, once the screen has a size and the layout has answered.
    private func fitIfNeeded(_ scene: GraphScene, _ input: GraphForceLayout.Input) {
        guard !didFit, viewSize.width > 0, viewSize.height > 0 else { return }
        guard !computed.isEmpty || scene.pages.isEmpty else { return }
        fit(scene, input, animated: false)
        withAnimation(Motion.gentle) { didFit = true }
    }

    private func center(on world: CGPoint) {
        withAnimation(Motion.gentle) {
            viewport = GraphViewport.centered(on: world, scale: max(viewport.scale, 0.8), in: viewSize,
                                              bottomInset: Self.inspectorInset)
        }
    }

    // MARK: Content

    private func content(scene: GraphScene, input: GraphForceLayout.Input, size: CGSize) -> some View {
        let basePages = pagePoints(scene, input)
        let centers = allPoints(scene, input, pages: basePages)
        let result = filter.apply(to: scene.pages)
        let eff = effectiveViewport(size)
        let focus = hovered ?? selected
        let degrees = scene.linkDegrees()
        let hasLinks = !scene.linkEdges.isEmpty
        let pageByID = Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let showThumbnails = scene.pages.count <= Self.thumbnailPageLimit && viewport.scale >= 0.5
        let selectedInfo = selected.flatMap { id in scene.pages.first { $0.id == id } }

        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.background)
                .overlay(Color.primary.opacity(0.025))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .updating($pan) { value, state, _ in state = value.translation }
                        .onEnded { value in viewport = viewport.panned(by: value.translation) })
                .onTapGesture(count: 2) { fit(scene, input, animated: true) }
                .onTapGesture { withAnimation(Motion.quick) { selected = nil } }
                .accessibilityHidden(true)

            // In an overlay so the 2000-point world never sizes the container.
            Color.clear
                .overlay(alignment: .topLeading) {
                    world(scene: scene, centers: centers, basePages: basePages, result: result, focus: focus,
                          degrees: degrees, hasLinks: hasLinks, pageByID: pageByID, showThumbnails: showThumbnails)
                        .frame(width: GraphWorld.size, height: GraphWorld.size, alignment: .topLeading)
                        .scaleEffect(eff.scale, anchor: .topLeading)
                        .offset(x: eff.offset.x, y: eff.offset.y)
                        .opacity(didFit ? 1 : 0)
                }
                .allowsHitTesting(didFit)

            if scene.linkEdges.isEmpty && scene.chips.isEmpty {
                GraphEmptyState(hasPages: !scene.pages.isEmpty)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, Space.xl)
                    .padding(.horizontal, Space.l)
                    .allowsHitTesting(false)
            }

            if !scene.pages.isEmpty {
                GraphMiniMapView(map: miniMap(scene, centers, eff, size), scene: scene, centers: centers,
                                 viewportRect: eff.visibleWorldRect(in: size),
                                 onJump: { point in
                                     viewport = GraphViewport.centered(on: point, scale: viewport.scale, in: size)
                                 })
                    .frame(width: 148, height: 108)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(Space.m)
                    .opacity(didFit ? 1 : 0)
            }

            if let info = selectedInfo {
                GraphInspector(info: info,
                               counts: scene.linkCounts(for: info.id),
                               onOpen: { onSelect(info.id) },
                               onCenter: { if let p = centers[.page(info.id)] { center(on: p) } })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(Space.m)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .coordinateSpace(name: Self.space)
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

    private func miniMap(_ scene: GraphScene, _ centers: [GraphNodeID: CGPoint],
                         _ eff: GraphViewport, _ size: CGSize) -> GraphMiniMap {
        var bounds = contentRect(scene, centers) ?? GraphWorld.bounds
        bounds = bounds.union(eff.visibleWorldRect(in: size)).insetBy(dx: -40, dy: -40)
        return GraphMiniMap(bounds: bounds, size: CGSize(width: 140, height: 100))
    }

    // MARK: World

    private func world(scene: GraphScene, centers: [GraphNodeID: CGPoint], basePages: [UUID: CGPoint],
                       result: GraphFilter.Result, focus: UUID?, degrees: [UUID: Int], hasLinks: Bool,
                       pageByID: [UUID: Page], showThumbnails: Bool) -> some View {
        let unlinked = hasLinks ? scene.unlinkedPageIDs : []
        let activeTags = filter.tags
        return ZStack(alignment: .topLeading) {
            GraphGridShape()
                .stroke(Color.primary.opacity(0.16),
                        style: StrokeStyle(lineWidth: 2.4, lineCap: .round, dash: [0.01, 40]))
                .frame(width: GraphWorld.size, height: GraphWorld.size)
                .allowsHitTesting(false)
            RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                .strokeBorder(Palette.separator, lineWidth: 2)
                .frame(width: GraphWorld.size, height: GraphWorld.size)
                .allowsHitTesting(false)

            // Tethers from a page to its chips.
            ForEach(scene.chips, id: \.linkID) { chip in
                if let a = centers[.page(chip.pageID)], let b = centers[.chip(chip.linkID)],
                   let curve = GraphGeometry.tether(from: a, aHalf: halfSize(.page(chip.pageID), scene),
                                                    to: b, bHalf: halfSize(.chip(chip.linkID), scene)) {
                    GraphEdgeView(curve: curve, style: .tether)
                        .opacity(result.dimmedPageIDs.contains(chip.pageID) ? GraphFilter.dimmedOpacity : 0.8)
                }
            }

            ForEach(scene.edges, id: \.self) { edge in
                if !result.hiddenEdgeKinds.contains(edge.kind),
                   let a = centers[edge.from], let b = centers[edge.to],
                   let curve = GraphGeometry.curve(from: a, aHalf: halfSize(edge.from, scene),
                                                   to: b, bHalf: halfSize(edge.to, scene)) {
                    GraphEdgeView(curve: curve,
                                  style: scene.isGhostEdge(edge) ? GraphEdgeStyle.of(edge.kind).ghosted : .of(edge.kind))
                        .opacity(edgeOpacity(edge, scene: scene, focus: focus, dimmed: result.dimmedPageIDs))
                        .animation(Motion.quick, value: focus)
                }
            }

            ForEach(scene.tags, id: \.key) { tag in
                if let p = centers[.tag(tag.key)] {
                    let isOn = activeTags.contains(tag.key)
                    let allDimmed = filter.dimsPages && tag.pageIDs.allSatisfy { result.dimmedPageIDs.contains($0) }
                    let size = GraphGeometry.tagSize(name: tag.name)
                    GraphTagView(name: tag.name, isOn: isOn)
                        .frame(width: size.width, height: size.height)
                        .opacity(allDimmed ? GraphFilter.dimmedOpacity : 1)
                        .onTapGesture { withAnimation(Motion.snappy) { filter = filter.togglingTag(tag.name) } }
                        .position(p)
                        .zIndex(1)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Tag \(tag.name), \(tag.pageIDs.count) pages")
                        .accessibilityAddTraits(.isButton)
                }
            }

            ForEach(scene.chips, id: \.linkID) { chip in
                if let p = centers[.chip(chip.linkID)] {
                    GraphChipView(title: chip.title, isGone: goneNodeIDs.contains(chip.linkID))
                        .frame(width: GraphGeometry.chipSize.width, height: GraphGeometry.chipSize.height)
                        .opacity(result.dimmedPageIDs.contains(chip.pageID) ? GraphFilter.dimmedOpacity : 1)
                        .onTapGesture { withAnimation(Motion.snappy) { selected = chip.pageID } }
                        .position(p)
                        .zIndex(2)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(goneNodeIDs.contains(chip.linkID)
                                            ? "Node \(chip.title), ink removed" : "Node \(chip.title)")
                        .accessibilityAddTraits(.isButton)
                }
            }

            ForEach(scene.ghosts, id: \.id) { ghost in
                if let p = centers[.page(ghost.id)] {
                    GraphGhostCard(info: ghost.info)
                        .frame(width: GraphGeometry.cardSize.width, height: GraphGeometry.cardSize.height)
                        .onTapGesture { onSelect(ghost.id) }
                        .position(p)
                        .zIndex(3)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(ghost.info.label), in another notebook")
                        .accessibilityHint("Double tap to open")
                        .accessibilityAddTraits(.isButton)
                }
            }

            ForEach(scene.pages, id: \.id) { info in
                if let p = centers[.page(info.id)], let start = basePages[info.id] {
                    let isSelected = selected == info.id
                    let degree = degrees[info.id] ?? 0
                    GraphPageCard(info: info, page: pageByID[info.id], documents: documents[info.id] ?? [],
                                  showThumbnail: showThumbnails, degree: degree, isSelected: isSelected,
                                  isMatch: result.highlightedPageIDs.contains(info.id),
                                  isHovered: hovered == info.id)
                        .frame(width: GraphGeometry.cardSize.width, height: GraphGeometry.cardSize.height)
                        .opacity(cardOpacity(info.id, dimmed: result.dimmedPageIDs, unlinked: unlinked))
                        .animation(Motion.gentle, value: result.dimmedPageIDs)
                        .onHover { inside in
                            if inside { hovered = info.id } else if hovered == info.id { hovered = nil }
                        }
                        .onTapGesture(count: 2) { onSelect(info.id) }
                        .onTapGesture { withAnimation(Motion.snappy) { selected = info.id } }
                        .gesture(
                            DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.space))
                                .onChanged { value in
                                    dragging = Dragging(id: info.id,
                                                        world: GraphViewport.dragTarget(start: start,
                                                                                        translation: value.translation,
                                                                                        scale: viewport.scale))
                                }
                                .onEnded { value in
                                    let target = GraphViewport.dragTarget(start: start, translation: value.translation,
                                                                          scale: viewport.scale)
                                    localPlaced[info.id] = target
                                    dragging = nil
                                    onMove(info.id, GraphWorld.fraction(from: target))
                                })
                        .position(p)
                        .zIndex(isSelected || dragging?.id == info.id ? 4 : 3)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Self.accessibilityLabel(for: info, degree: degree))
                        .accessibilityHint("Double tap to select. Use Open Page in the inspector to go there.")
                        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
    }

    static func accessibilityLabel(for info: GraphPageInfo, degree: Int) -> String {
        let title = (info.title?.isEmpty == false) ? ", \(info.title ?? "")" : ""
        return "Page \(info.index + 1)\(title), \(degree) \(degree == 1 ? "link" : "links")"
    }

    // MARK: Opacity

    private func cardOpacity(_ id: UUID, dimmed: Set<UUID>, unlinked: Set<UUID>) -> Double {
        if dimmed.contains(id) { return GraphFilter.dimmedOpacity }
        return unlinked.contains(id) ? 0.7 : 1
    }

    /// Edges touching the focused page stand out; the rest fade. A page
    /// the filter dimmed fades its edges too.
    private func edgeOpacity(_ edge: GraphEdge, scene: GraphScene, focus: UUID?, dimmed: Set<UUID>) -> Double {
        let a = scene.ownerPage(of: edge.from), b = scene.ownerPage(of: edge.to)
        if [a, b].contains(where: { $0.map { dimmed.contains($0) } ?? false }) { return 0.1 }
        guard let focus else { return 0.9 }
        return (a == focus || b == focus) ? 1 : 0.15
    }
}

// MARK: - Edges

private struct GraphEdgeStyle {
    var color: Color
    var dash: [CGFloat]
    var width: CGFloat
    var hasArrow: Bool

    static func of(_ kind: EdgeKind) -> GraphEdgeStyle {
        switch kind {
        case .explicit: return GraphEdgeStyle(color: Palette.edgeExplicit, dash: [], width: 2, hasArrow: true)
        case .mention: return GraphEdgeStyle(color: Palette.edgeMention, dash: [8, 6], width: 1.8, hasArrow: true)
        case .transclusion:
            return GraphEdgeStyle(color: Palette.edgeExplicit.opacity(0.75), dash: [12, 4, 2, 4], width: 1.8, hasArrow: true)
        case .tag: return GraphEdgeStyle(color: Palette.edgeTag, dash: [0.5, 6], width: 2.2, hasArrow: false)
        }
    }

    /// The same edge, dashed, for one that reaches another notebook.
    var ghosted: GraphEdgeStyle {
        GraphEdgeStyle(color: color.opacity(0.7), dash: [5, 5], width: width, hasArrow: hasArrow)
    }

    /// Page to its node chips.
    static let tether = GraphEdgeStyle(color: Palette.node.opacity(0.85), dash: [], width: 1.6, hasArrow: false)
}

/// One edge: its own small frame around the curve, so no layer is world-sized.
private struct GraphEdgeView: View {
    let curve: GraphGeometry.Curve
    let style: GraphEdgeStyle

    var body: some View {
        let frame = curve.bounds.insetBy(dx: -16, dy: -16)
        ZStack {
            CurveShape(curve: curve, origin: frame.origin)
                .stroke(style.color, style: StrokeStyle(lineWidth: style.width, lineCap: .round, dash: style.dash))
            if style.hasArrow {
                ArrowShape(tip: curve.end, direction: curve.arrivalDirection, origin: frame.origin)
                    .stroke(style.color, style: StrokeStyle(lineWidth: style.width, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: frame.width, height: frame.height)
        .position(x: frame.midX, y: frame.midY)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct CurveShape: Shape {
    let curve: GraphGeometry.Curve
    let origin: CGPoint

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: curve.start.x - origin.x, y: curve.start.y - origin.y))
        p.addQuadCurve(to: CGPoint(x: curve.end.x - origin.x, y: curve.end.y - origin.y),
                       control: CGPoint(x: curve.control.x - origin.x, y: curve.control.y - origin.y))
        return p
    }
}

private struct ArrowShape: Shape {
    let tip: CGPoint
    let direction: CGPoint
    let origin: CGPoint

    func path(in rect: CGRect) -> Path {
        let t = CGPoint(x: tip.x - origin.x, y: tip.y - origin.y)
        let length: CGFloat = 11, half: CGFloat = 5.5
        let normal = CGPoint(x: -direction.y, y: direction.x)
        var p = Path()
        p.move(to: CGPoint(x: t.x - direction.x * length + normal.x * half, y: t.y - direction.y * length + normal.y * half))
        p.addLine(to: t)
        p.addLine(to: CGPoint(x: t.x - direction.x * length - normal.x * half, y: t.y - direction.y * length - normal.y * half))
        return p
    }
}

/// Horizontal rules every 40 points, stroked with a near-zero dash and round
/// caps, which draws one dot per 40 points: a dotted grid as a single path.
private struct GraphGridShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        var y: CGFloat = 0
        while y <= rect.height {
            p.move(to: CGPoint(x: 0, y: y))
            p.addLine(to: CGPoint(x: rect.width, y: y))
            y += 40
        }
        return p
    }
}

// MARK: - Nodes

private struct GraphPageCard: View {
    let info: GraphPageInfo
    let page: Page?
    let documents: [ImportedDocument]
    let showThumbnail: Bool
    let degree: Int
    let isSelected: Bool
    let isMatch: Bool
    let isHovered: Bool

    private var hasTitle: Bool { !(info.title ?? "").isEmpty }

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            leading
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("p. \(info.index + 1)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(hasTitle ? (info.title ?? "") : "Untitled")
                    .font(Typography.label)
                    .foregroundStyle(hasTitle ? Color.primary : Color.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                HStack(spacing: Space.xs) {
                    ForEach(Array(info.tags.prefix(4).enumerated()), id: \.offset) { _, tag in
                        Circle()
                            .fill(Color(hue: GraphGeometry.tagHue(tag), saturation: 0.5, brightness: 0.85))
                            .frame(width: 7, height: 7)
                    }
                    Spacer(minLength: 0)
                    if degree > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "link").imageScale(.small)
                            Text("\(degree)").monospacedDigit()
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, Space.xs + 1)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(Space.s)
        .surfaceCard(radius: Radius.m, elevated: isSelected || isHovered)
        .overlay {
            RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                .strokeBorder(Palette.selectionRing, lineWidth: isSelected ? 3 : (isMatch ? 2 : 0))
                .opacity(isSelected || isMatch ? 1 : 0)
        }
        .scaleEffect(isHovered && !isSelected ? 1.02 : 1)
        .animation(Motion.quick, value: isHovered)
        .animation(Motion.snappy, value: isSelected)
    }

    @ViewBuilder
    private var leading: some View {
        if showThumbnail, let page {
            let aspect = PageGeometry.aspectRatio(page.aspectRatio)
            PageThumbnailView(page: page, importedDocuments: documents, height: min(80, 60 / aspect))
                .frame(width: 60, height: 80)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.s - 2, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                Image(systemName: "doc.text")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 36, height: 48)
        }
    }
}

/// A page of another notebook: translucent, dashed border, never saved.
private struct GraphGhostCard: View {
    let info: GraphForeignPage

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(info.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(info.title.isEmpty ? "Untitled" : info.title)
                .font(Typography.label)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right.square")
                .imageScale(.small)
                .foregroundStyle(.secondary)
        }
        .padding(Space.s)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
            .strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        .opacity(0.75)
    }
}

/// A node (named region of ink) as an amber pill.
private struct GraphChipView: View {
    let title: String
    let isGone: Bool

    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: isGone ? "scribble.variable" : "scribble")
                .imageScale(.small)
            Text(title)
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(isGone ? Color.secondary : Color.black.opacity(0.82))
        .padding(.horizontal, Space.s + 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Capsule().fill(isGone ? Color.secondary.opacity(0.18) : Palette.node))
        .overlay(Capsule().strokeBorder(isGone ? Color.secondary.opacity(0.4) : Color.black.opacity(0.12),
                                        style: StrokeStyle(lineWidth: 1, dash: isGone ? [3, 3] : [])))
        .shadow(color: .black.opacity(isGone ? 0 : 0.1), radius: 4, y: 2)
    }
}

/// A derived tag: a small capsule. Tapping it filters to that tag.
private struct GraphTagView: View {
    let name: String
    let isOn: Bool

    var body: some View {
        Text("#\(name)")
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(isOn ? Color.white : Color.secondary)
            .padding(.horizontal, Space.s)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Capsule().fill(isOn ? Color.accentColor : Color.primary.opacity(0.07)))
            .overlay(Capsule().strokeBorder(Palette.separator, lineWidth: Metrics.hairline))
    }
}

// MARK: - Overlays

private struct GraphInspector: View {
    let info: GraphPageInfo
    let counts: (from: Int, to: Int)
    let onOpen: () -> Void
    let onCenter: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text((info.title ?? "").isEmpty ? "Untitled page" : (info.title ?? ""))
                    .font(Typography.headline)
                    .lineLimit(1)
                Text("Page \(info.index + 1)")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                Text("Linked from \(counts.from) \u{00B7} Links to \(counts.to)")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                if !info.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Space.xs) {
                            ForEach(info.tags, id: \.self) { tag in
                                Text("#\(tag)")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, Space.s)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color(hue: GraphGeometry.tagHue(tag),
                                                                     saturation: 0.45, brightness: 0.9).opacity(0.28)))
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: Space.s) {
                Button(action: onOpen) {
                    Label("Open Page", systemImage: "arrow.up.right.square").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button(action: onCenter) {
                    Label("Center", systemImage: "scope").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .frame(width: 150)
        }
        .padding(Space.l)
        .surfaceCard()
        .frame(maxWidth: 560)
        .accessibilityElement(children: .contain)
    }
}

private struct GraphEmptyState: View {
    let hasPages: Bool

    var body: some View {
        VStack(spacing: Space.s) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(Palette.node)
            Text(hasPages ? "No links yet" : "Nothing to map yet")
                .font(Typography.title)
            Text("Connect pages and they show up here as a graph. Lasso some ink and choose Link This To\u{2026}, or type [[ in a text box to mention another page.")
                .font(Typography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(Space.xl)
        .frame(maxWidth: 420)
        .surfaceCard(radius: Radius.l)
        .accessibilityElement(children: .combine)
    }
}

/// An overview of the world: a dot per node and the part you are looking at.
/// Drag on it to move the view.
private struct GraphMiniMapView: View {
    let map: GraphMiniMap
    let scene: GraphScene
    let centers: [GraphNodeID: CGPoint]
    let viewportRect: CGRect
    let onJump: (CGPoint) -> Void

    var body: some View {
        // Copied out of `self` so the renderer closure touches only values.
        let sceneCopy = self.scene, centersCopy = self.centers, mapCopy = self.map, viewCopy = self.viewportRect
        let accent = Color.accentColor, nodeColor = Palette.node
        return Canvas { ctx, _ in
            for page in sceneCopy.pages {
                guard let p = centersCopy[.page(page.id)] else { continue }
                let r = mapCopy.toMini(CGRect(x: p.x - GraphGeometry.cardSize.width / 2, y: p.y - GraphGeometry.cardSize.height / 2,
                                          width: GraphGeometry.cardSize.width, height: GraphGeometry.cardSize.height))
                ctx.fill(Path(roundedRect: r.insetBy(dx: -0.5, dy: -0.5), cornerRadius: 1.5),
                         with: .color(accent.opacity(0.55)))
            }
            for chip in sceneCopy.chips {
                guard let p = centersCopy[.chip(chip.linkID)] else { continue }
                let c = mapCopy.toMini(p)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)), with: .color(nodeColor))
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

// MARK: - Filter

private struct GraphFilterPanel: View {
    @Binding var filter: GraphFilter
    let tags: [GraphTag]

    private struct TimeRange {
        var title: String
        var days: Int?
    }

    private static let ranges = [
        TimeRange(title: "Any time", days: nil), TimeRange(title: "Today", days: 1),
        TimeRange(title: "7 days", days: 7), TimeRange(title: "30 days", days: 30),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                section("Link types") {
                    ForEach(EdgeKind.allCases, id: \.self) { kind in
                        Button {
                            withAnimation(Motion.snappy) { filter = filter.toggling(kind) }
                        } label: {
                            Chip(title: kind.title, systemImage: kind.systemImage, isSelected: filter.shows(kind))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(filter.shows(kind) ? .isSelected : [])
                    }
                }
                section("Edited") {
                    ForEach(Self.ranges, id: \.title) { range in
                        let selected = selectedDays == range.days
                        Button {
                            withAnimation(Motion.snappy) {
                                filter.since = range.days.flatMap {
                                    Calendar.current.date(byAdding: .day, value: -$0, to: Date())
                                }
                            }
                        } label: {
                            Chip(title: range.title, isSelected: selected)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                section("Tags") {
                    if tags.isEmpty {
                        Text("Tag a page to filter by it here.")
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(tags, id: \.key) { tag in
                        Button {
                            withAnimation(Motion.snappy) { filter = filter.togglingTag(tag.name) }
                        } label: {
                            Chip(title: "#\(tag.name)", isSelected: filter.tags.contains(tag.key),
                                 tint: Color(hue: GraphGeometry.tagHue(tag.name), saturation: 0.55, brightness: 0.7))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(filter.tags.contains(tag.key) ? .isSelected : [])
                    }
                }
                if filter.isActive {
                    Button("Clear Filters", role: .destructive) {
                        withAnimation(Motion.snappy) {
                            let text = filter.searchText
                            filter = GraphFilter()
                            filter.searchText = text
                        }
                    }
                    .font(Typography.label)
                }
            }
            .padding(Space.l)
        }
        .frame(width: 340)
        .frame(minHeight: 280, maxHeight: 460)
    }

    /// The preset closest to the current `since`, if any.
    private var selectedDays: Int? {
        guard let since = filter.since else { return nil }
        let days = Calendar.current.dateComponents([.day], from: since, to: Date()).day ?? 0
        return [1, 7, 30].min { abs($0 - days) < abs($1 - days) }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionLabel(title)
            GraphChipFlow(spacing: Space.s) { content() }
        }
    }
}

/// Chips wrapped onto as many rows as the width needs.
private struct GraphChipFlow: Layout {
    var spacing: CGFloat = Space.s

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            width = max(width, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
