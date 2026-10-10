import SwiftUI

/// M2: read-only map of one notebook. Pages sit on a circle in page order;
/// each `Link` is an arrow from its source page to its destination.
struct NotebookGraphView: View {
    let pages: [Page]
    let links: [Link]
    let onSelect: (UUID) -> Void

    private static let cardSize = CGSize(width: 110, height: 44)

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

    /// Pages on a circle, first page at the top, clockwise. Pure and deterministic.
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

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let sorted = pages.sorted { $0.index < $1.index }
                let edges = Self.edges(pages: sorted, links: links)
                let points = Self.layout(pageIDs: sorted.map(\.id), edges: edges, in: geo.size)
                let linked = Set(edges.flatMap { [$0.0, $0.1] })
                ZStack {
                    Canvas { ctx, _ in
                        for (a, b) in edges {
                            guard let p = points[a], let q = points[b] else { continue }
                            let d = CGPoint(x: q.x - p.x, y: q.y - p.y)
                            let len = hypot(d.x, d.y)
                            guard len > 0 else { continue }
                            let u = CGPoint(x: d.x / len, y: d.y / len)
                            // Stop at the card's edge rather than its centre.
                            let inset = min(Self.cardSize.width / 2 / max(abs(u.x), 0.001),
                                            Self.cardSize.height / 2 / max(abs(u.y), 0.001)) + 3
                            guard len > 2 * inset else { continue }
                            let s = CGPoint(x: p.x + u.x * inset, y: p.y + u.y * inset)
                            let e = CGPoint(x: q.x - u.x * inset, y: q.y - u.y * inset)
                            var path = Path()
                            path.move(to: s); path.addLine(to: e)
                            let l = CGPoint(x: -u.y, y: u.x)
                            path.move(to: e)
                            path.addLine(to: CGPoint(x: e.x - u.x * 10 + l.x * 5, y: e.y - u.y * 10 + l.y * 5))
                            path.move(to: e)
                            path.addLine(to: CGPoint(x: e.x - u.x * 10 - l.x * 5, y: e.y - u.y * 10 - l.y * 5))
                            ctx.stroke(path, with: .color(.accentColor), lineWidth: 1.5)
                        }
                    }
                    ForEach(sorted, id: \.id) { page in
                        if let pt = points[page.id] {
                            Button { onSelect(page.id) } label: {
                                Text(LinkedFromStrip.label(for: page))
                                    .font(.caption)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .padding(6)
                                    .frame(width: Self.cardSize.width, height: Self.cardSize.height)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.4)))
                            }
                            .buttonStyle(.plain)
                            .opacity(linked.contains(page.id) ? 1 : 0.45)
                            .position(pt)
                        }
                    }
                }
            }
            .navigationTitle("Page Map")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
