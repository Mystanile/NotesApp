import Foundation
import CoreGraphics

extension Notebook {
    /// Page Map positions the user set, as fractions (0...1) of the Page Map's
    /// fixed 2000 x 2000 world (`GraphWorld`).
    ///
    /// Until Nov 2, 2026 these were fractions of whatever sheet the map was
    /// shown on. The JSON is unchanged, so nothing migrates: an old position
    /// simply means the same fraction of the world instead.
    var graphPositions: [UUID: CGPoint] {
        guard let data = graphLayout?.data(using: .utf8),
              let raw = try? JSONDecoder().decode([String: [Double]].self, from: data) else { return [:] }
        var result: [UUID: CGPoint] = [:]
        for (key, xy) in raw where xy.count == 2 {
            if let id = UUID(uuidString: key) { result[id] = CGPoint(x: xy[0], y: xy[1]) }
        }
        return result
    }

    /// Stores one card's position (clamped to the world) as a settings change.
    func setGraphPosition(_ point: CGPoint, forPageID id: UUID, at date: Date = Date()) {
        var raw = graphPositions.reduce(into: [String: [Double]]()) { $0[$1.key.uuidString] = [Double($1.value.x), Double($1.value.y)] }
        raw[id.uuidString] = [Double(min(max(point.x, 0), 1)), Double(min(max(point.y, 0), 1))]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        graphLayout = (try? encoder.encode(raw)).flatMap { String(data: $0, encoding: .utf8) }
        markSettingsModified(at: date)
    }
}

// MARK: - World

/// The Page Map's coordinate space: a fixed square. Saved positions are
/// fractions of it, so they mean the same thing on every screen.
nonisolated enum GraphWorld {
    static let size: CGFloat = 2000
    static var bounds: CGRect { CGRect(x: 0, y: 0, width: size, height: size) }

    static func point(fromFraction f: CGPoint) -> CGPoint {
        CGPoint(x: f.x * size, y: f.y * size)
    }

    /// Clamped to 0...1, as the stored form is.
    static func fraction(from p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x / size, 0), 1), y: min(max(p.y / size, 0), 1))
    }
}

// MARK: - Scene

/// A link as the graph reads it: plain values.
nonisolated struct GraphLinkInfo: Hashable, Sendable {
    var id: UUID
    var sourcePageID: UUID
    var destinationPageID: UUID
    var kind: String?
    var destinationKind: String?
    var destinationID: String?
    var title: String?

    @MainActor
    init(link: Link) {
        id = link.id
        sourcePageID = link.sourcePageID
        destinationPageID = link.destinationPageID
        kind = link.kind
        destinationKind = link.destinationKind
        destinationID = link.destinationID
        title = link.title
    }
}

nonisolated struct GraphEdge: Hashable, Sendable {
    var from: GraphNodeID
    var to: GraphNodeID
    var kind: EdgeKind
    /// Tag edges have no direction.
    var isDirected: Bool { kind != .tag }
}

/// A node (a `Link` of kind "node") shown beside the page it lives on.
nonisolated struct GraphChip: Hashable, Sendable {
    var linkID: UUID
    var pageID: UUID
    var title: String
}

/// A tag shared by some pages. Derived; never saved.
nonisolated struct GraphTag: Hashable, Sendable {
    var key: String
    var name: String
    var pageIDs: [UUID]
}

/// Everything the map draws, derived from pages and links. Pure.
nonisolated struct GraphScene: Sendable {
    var pages: [GraphPageInfo] = []
    var edges: [GraphEdge] = []
    var chips: [GraphChip] = []
    var tags: [GraphTag] = []
    /// Chip link id -> the page it sits on.
    var chipOwners: [UUID: UUID] = [:]

    /// Edges that come from links, not from tags.
    var linkEdges: [GraphEdge] { edges.filter { $0.kind != .tag } }

    @MainActor
    static func build(pages: [Page], links: [Link]) -> GraphScene {
        build(pages: pages.map(GraphPageInfo.init(page:)), links: links.map(GraphLinkInfo.init(link:)))
    }

    static func build(pages: [GraphPageInfo], links: [GraphLinkInfo]) -> GraphScene {
        let sortedPages = pages.sorted { ($0.index, $0.id.uuidString) < ($1.index, $1.id.uuidString) }
        let pageIDs = Set(sortedPages.map(\.id))

        var chips: [GraphChip] = []
        for l in links where l.kind == "node" && pageIDs.contains(l.sourcePageID) {
            let title = l.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            chips.append(GraphChip(linkID: l.id, pageID: l.sourcePageID, title: title.isEmpty ? "Node" : title))
        }
        chips.sort { ($0.title, $0.linkID.uuidString) < ($1.title, $1.linkID.uuidString) }
        let chipIDs = Set(chips.map(\.linkID))

        var seen = Set<GraphEdge>()
        var edges: [GraphEdge] = []
        for l in links where pageIDs.contains(l.sourcePageID) {
            let kind: EdgeKind
            switch l.kind {
            case nil: kind = .explicit
            case "mention": kind = .mention
            case "transclusion": kind = .transclusion
            default: continue   // "node" (a chip) and kinds a later build wrote
            }
            let to: GraphNodeID
            if l.destinationKind == "region" || l.kind == "transclusion",
               let raw = l.destinationID, let nodeID = UUID(uuidString: raw), chipIDs.contains(nodeID) {
                to = .chip(nodeID)
            } else if pageIDs.contains(l.destinationPageID), l.destinationPageID != l.sourcePageID {
                to = .page(l.destinationPageID)
            } else {
                continue   // a self-link, an unfinished link, or another notebook's page
            }
            let edge = GraphEdge(from: .page(l.sourcePageID), to: to, kind: kind)
            if seen.insert(edge).inserted { edges.append(edge) }
        }

        var names: [String: String] = [:]
        var byKey: [String: [UUID]] = [:]
        for page in sortedPages {
            // The same normalization as `PageTags` (which is main-actor): trim,
            // drop leading "#", ignore case.
            var onPage = Set<String>()
            for raw in page.tags {
                var tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                while tag.hasPrefix("#") { tag.removeFirst() }
                tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = tag.lowercased()
                guard !tag.isEmpty, onPage.insert(key).inserted else { continue }
                if names[key] == nil { names[key] = tag }
                byKey[key, default: []].append(page.id)
            }
        }
        let tags = byKey.keys.sorted().map { GraphTag(key: $0, name: names[$0] ?? $0, pageIDs: byKey[$0] ?? []) }
        for tag in tags {
            for id in tag.pageIDs { edges.append(GraphEdge(from: .tag(tag.key), to: .page(id), kind: .tag)) }
        }

        edges.sort { ($0.from.sortKey, $0.to.sortKey, $0.kind.rawValue) < ($1.from.sortKey, $1.to.sortKey, $1.kind.rawValue) }
        let owners = Dictionary(chips.map { ($0.linkID, $0.pageID) }, uniquingKeysWith: { first, _ in first })
        return GraphScene(pages: sortedPages, edges: edges, chips: chips, tags: tags, chipOwners: owners)
    }

    func chips(on pageID: UUID) -> [GraphChip] { chips.filter { $0.pageID == pageID } }

    /// The page a node belongs to: itself, or a chip's page. Tags have none.
    func ownerPage(of node: GraphNodeID) -> UUID? {
        switch node {
        case .page(let id): return id
        case .chip(let id): return chipOwners[id]
        case .tag: return nil
        }
    }

    /// Distinct other pages linking to `pageID` and linked from it, counting
    /// a link to one of its nodes as a link to the page. Tags don't count.
    func linkCounts(for pageID: UUID) -> (from: Int, to: Int) {
        var sources = Set<UUID>(), destinations = Set<UUID>()
        for e in linkEdges {
            guard let a = ownerPage(of: e.from), let b = ownerPage(of: e.to), a != b else { continue }
            if b == pageID { sources.insert(a) }
            if a == pageID { destinations.insert(b) }
        }
        return (sources.count, destinations.count)
    }

    /// How many link edges touch each page (a link to one of its nodes counts
    /// for the page; a page's link to its own node counts for nothing).
    func linkDegrees() -> [UUID: Int] {
        var degree: [UUID: Int] = [:]
        for e in linkEdges {
            guard let a = ownerPage(of: e.from), let b = ownerPage(of: e.to), a != b else { continue }
            degree[a, default: 0] += 1
            degree[b, default: 0] += 1
        }
        return degree
    }

    /// Pages with no link edge at all.
    var unlinkedPageIDs: Set<UUID> {
        let degree = linkDegrees()
        return Set(pages.map(\.id).filter { degree[$0] == nil })
    }

    /// The nodes the force layout places: pages, then tags.
    var layoutNodes: [GraphNodeID] { pages.map { GraphNodeID.page($0.id) } + tags.map { GraphNodeID.tag($0.key) } }

    /// Edges as the layout sees them: a chip stands for its page.
    var layoutPairs: [GraphForceLayout.Pair] {
        func resolve(_ n: GraphNodeID) -> GraphNodeID { ownerPage(of: n).map { GraphNodeID.page($0) } ?? n }
        var seen = Set<GraphForceLayout.Pair>()
        var out: [GraphForceLayout.Pair] = []
        for e in edges {
            let pair = GraphForceLayout.Pair(a: resolve(e.from), b: resolve(e.to))
            if pair.a != pair.b, seen.insert(pair).inserted { out.append(pair) }
        }
        return out
    }
}

// MARK: - Geometry

nonisolated enum GraphGeometry {
    static let cardSize = CGSize(width: 168, height: 104)
    static let chipSize = CGSize(width: 132, height: 30)
    static let tagHeight: CGFloat = 26

    static func tagSize(name: String) -> CGSize {
        CGSize(width: min(max(CGFloat(name.count) * 7.5 + 34, 64), 170), height: tagHeight)
    }

    /// Where chips sit around a page card: evenly spaced, the first at the
    /// upper right, each pushed out until it clears the card. More than
    /// eight start a second ring. Deterministic.
    static func chipCenters(around page: CGPoint, count: Int) -> [CGPoint] {
        guard count > 0 else { return [] }
        let perRing = 8
        let cardRect = CGRect(x: page.x - cardSize.width / 2, y: page.y - cardSize.height / 2,
                              width: cardSize.width, height: cardSize.height).insetBy(dx: -12, dy: -12)
        var out: [CGPoint] = []
        for i in 0..<count {
            let ring = i / perRing
            let inRing = min(perRing, count - ring * perRing)
            let angle = -Double.pi / 4 + 2 * Double.pi * Double(i % perRing) / Double(inRing) + Double(ring) * Double.pi / 8
            let ux = cos(angle), uy = sin(angle)
            var r = 40.0
            var centre = page
            while r < 800 {
                centre = CGPoint(x: page.x + ux * r, y: page.y + uy * r)
                let rect = CGRect(x: centre.x - chipSize.width / 2, y: centre.y - chipSize.height / 2,
                                  width: chipSize.width, height: chipSize.height)
                if !rect.intersects(cardRect) { break }
                r += 4
            }
            let extra = Double(ring) * 40
            out.append(CGPoint(x: centre.x + ux * extra, y: centre.y + uy * extra))
        }
        return out
    }

    /// A gently bowed edge: start and end on the two rectangles' borders, one
    /// control point beside the midpoint. A to B and B to A bow to opposite
    /// sides, so a pair of links never overlaps.
    struct Curve: Equatable, Sendable {
        var start: CGPoint
        var control: CGPoint
        var end: CGPoint

        /// Unit direction the curve arrives with, for the arrowhead.
        var arrivalDirection: CGPoint {
            let dx = end.x - control.x, dy = end.y - control.y
            let len = max((dx * dx + dy * dy).squareRoot(), 0.001)
            return CGPoint(x: dx / len, y: dy / len)
        }

        var bounds: CGRect {
            let xs = [start.x, control.x, end.x], ys = [start.y, control.y, end.y]
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
    }

    /// `nil` when the shapes touch or overlap, so there is no room for an edge.
    static func curve(from a: CGPoint, aHalf: CGSize, to b: CGPoint, bHalf: CGSize, gap: CGFloat = 4) -> Curve? {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 1 else { return nil }
        let bow = min(len * 0.12, 60)
        let control = CGPoint(x: (a.x + b.x) / 2 - dy / len * bow, y: (a.y + b.y) / 2 + dx / len * bow)
        guard let start = clip(centre: a, half: aHalf, toward: control, gap: gap),
              let end = clip(centre: b, half: bHalf, toward: control, gap: gap) else { return nil }
        let sx = end.x - start.x, sy = end.y - start.y
        guard (sx * sx + sy * sy).squareRoot() > 8 else { return nil }
        return Curve(start: start, control: control, end: end)
    }

    /// A straight line between two shapes, for the tether to a node chip.
    static func tether(from a: CGPoint, aHalf: CGSize, to b: CGPoint, bHalf: CGSize) -> Curve? {
        guard var c = curve(from: a, aHalf: aHalf, to: b, bHalf: bHalf, gap: 2) else { return nil }
        c.control = CGPoint(x: (c.start.x + c.end.x) / 2, y: (c.start.y + c.end.y) / 2)
        return c
    }

    /// Where the ray from `centre` toward `target` leaves the rectangle.
    static func clip(centre: CGPoint, half: CGSize, toward target: CGPoint, gap: CGFloat) -> CGPoint? {
        let dx = target.x - centre.x, dy = target.y - centre.y
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 0.001 else { return nil }
        let ux = dx / len, uy = dy / len
        let t = min(half.width / max(abs(ux), 0.001), half.height / max(abs(uy), 0.001)) + gap
        guard t < len else { return nil }
        return CGPoint(x: centre.x + ux * t, y: centre.y + uy * t)
    }

    /// A stable hue for a tag, avoiding amber (reserved for nodes). Not
    /// `hashValue`: that changes on every launch.
    static func tagHue(_ name: String) -> Double {
        let sum = name.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 997 }
        return 0.16 + Double(sum % 100) / 100 * 0.8
    }
}

// MARK: - Viewport

/// Pan and zoom of the map. `toScreen(w) = w * scale + offset`.
nonisolated struct GraphViewport: Equatable, Sendable {
    static let minScale: CGFloat = 0.3
    static let maxScale: CGFloat = 3
    /// Fit never magnifies beyond this, so a two-page map isn't enormous.
    static let maxFitScale: CGFloat = 1.25

    var scale: CGFloat = 1
    /// Where the world's origin is on screen.
    var offset: CGPoint = .zero

    func toScreen(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale + offset.x, y: p.y * scale + offset.y) }
    func toWorld(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - offset.x) / scale, y: (p.y - offset.y) / scale) }

    func visibleWorldRect(in size: CGSize) -> CGRect {
        let o = toWorld(.zero)
        return CGRect(x: o.x, y: o.y, width: size.width / scale, height: size.height / scale)
    }

    /// Zooms by `factor`, keeping the world point under `anchor` (a screen
    /// point) where it is. The scale is clamped to 0.3...3.
    func zoomed(by factor: CGFloat, around anchor: CGPoint) -> GraphViewport {
        let target = min(max(scale * factor, Self.minScale), Self.maxScale)
        let ratio = target / scale
        return GraphViewport(scale: target,
                             offset: CGPoint(x: anchor.x - (anchor.x - offset.x) * ratio,
                                             y: anchor.y - (anchor.y - offset.y) * ratio))
    }

    func panned(by t: CGSize) -> GraphViewport {
        GraphViewport(scale: scale, offset: CGPoint(x: offset.x + t.width, y: offset.y + t.height))
    }

    /// Scale and offset that show all of `content` with `padding` around it.
    /// `bottomInset` is screen space something else covers (the inspector).
    static func fitting(_ content: CGRect, in size: CGSize, padding: CGFloat = 56, bottomInset: CGFloat = 0) -> GraphViewport {
        guard content.width > 0, content.height > 0, size.width > 0, size.height > 0 else {
            return centered(on: CGPoint(x: GraphWorld.size / 2, y: GraphWorld.size / 2), scale: 1, in: size)
        }
        let availW = max(size.width - 2 * padding, 1)
        let availH = max(size.height - bottomInset - 2 * padding, 1)
        let s = min(max(min(availW / content.width, availH / content.height), minScale), maxFitScale)
        return GraphViewport(scale: s, offset: CGPoint(x: size.width / 2 - content.midX * s,
                                                       y: (size.height - bottomInset) / 2 - content.midY * s))
    }

    static func centered(on world: CGPoint, scale: CGFloat, in size: CGSize, bottomInset: CGFloat = 0) -> GraphViewport {
        let s = min(max(scale, minScale), maxScale)
        return GraphViewport(scale: s, offset: CGPoint(x: size.width / 2 - world.x * s,
                                                       y: (size.height - bottomInset) / 2 - world.y * s))
    }

    /// Where a dragged card is, in world points. A drag is measured on
    /// screen, so it divides by the zoom; the result stays inside the world.
    /// Computed from the gesture's own translation, never from what was last
    /// drawn (that was the one-frame lag).
    static func dragTarget(start: CGPoint, translation: CGSize, scale: CGFloat) -> CGPoint {
        let s = max(scale, 0.001)
        return CGPoint(x: min(max(start.x + translation.width / s, 0), GraphWorld.size),
                       y: min(max(start.y + translation.height / s, 0), GraphWorld.size))
    }
}

/// The mini-map's mapping between a rectangle of world and a small view.
nonisolated struct GraphMiniMap: Equatable, Sendable {
    var bounds: CGRect
    var size: CGSize

    var scale: CGFloat { min(size.width / max(bounds.width, 1), size.height / max(bounds.height, 1)) }
    private var origin: CGPoint {
        CGPoint(x: (size.width - bounds.width * scale) / 2, y: (size.height - bounds.height * scale) / 2)
    }

    func toMini(_ p: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + (p.x - bounds.minX) * scale, y: origin.y + (p.y - bounds.minY) * scale)
    }

    func toWorld(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - origin.x) / scale + bounds.minX, y: (p.y - origin.y) / scale + bounds.minY)
    }

    func toMini(_ r: CGRect) -> CGRect {
        let o = toMini(r.origin)
        return CGRect(x: o.x, y: o.y, width: r.width * scale, height: r.height * scale)
    }
}
