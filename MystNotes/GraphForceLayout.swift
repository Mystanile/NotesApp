import Foundation
import CoreGraphics

/// A node of the Page Map: a page, a node chip (a `Link` of kind "node") or a
/// derived tag. The id of a chip is its link's id.
nonisolated enum GraphNodeID: Hashable, Sendable {
    case page(UUID)
    case chip(UUID)
    /// The tag's lowercased name.
    case tag(String)

    /// A total order that doesn't depend on hashing, so layouts are the same
    /// on every launch.
    var sortKey: String {
        switch self {
        case .page(let id): return "p:" + id.uuidString
        case .chip(let id): return "c:" + id.uuidString
        case .tag(let key): return "t:" + key
        }
    }
}

/// M2 task 10: a Fruchterman-Reingold layout in a fixed 2000 x 2000 world.
///
/// Deterministic: same input, same output. Nothing here is random and no
/// dictionary is iterated while computing (their order differs per launch).
/// Nodes in `fixed` (a page the user placed) never move but still push the
/// others away and pull their neighbours.
///
/// Pure and `nonisolated`; `runDetached` is the only entry the view uses, so
/// 200 iterations of n-squared never run on the main thread (invariant 10).
nonisolated enum GraphForceLayout {
    static let worldSize: CGFloat = 2000
    static let iterations = 200
    /// Nodes stay this far from the world's edge.
    static let margin: CGFloat = 120

    struct Pair: Hashable, Sendable {
        var a: GraphNodeID
        var b: GraphNodeID
    }

    struct Input: Hashable, Sendable {
        /// In a fixed order; the result does not depend on `seeds`' or
        /// `fixed`'s order.
        var nodes: [GraphNodeID]
        var edges: [Pair]
        /// Where each node starts. A node with no seed starts at the centre.
        var seeds: [GraphNodeID: CGPoint]
        var fixed: Set<GraphNodeID>
    }

    static func run(_ input: Input) -> [GraphNodeID: CGPoint] {
        let nodes = input.nodes
        let n = nodes.count
        let world = Double(worldSize)
        let centre = CGPoint(x: world / 2, y: world / 2)
        guard n > 0 else { return [:] }

        var index: [GraphNodeID: Int] = [:]
        for (i, node) in nodes.enumerated() where index[node] == nil { index[node] = i }
        var x = nodes.map { Double((input.seeds[$0] ?? centre).x) }
        var y = nodes.map { Double((input.seeds[$0] ?? centre).y) }
        let pinned = nodes.map { input.fixed.contains($0) }
        guard n > 1 else { return Dictionary(uniqueKeysWithValues: [(nodes[0], CGPoint(x: x[0], y: y[0]))]) }

        var pairs: [(Int, Int)] = []
        var seen = Set<[Int]>()
        for edge in input.edges {
            guard let a = index[edge.a], let b = index[edge.b], a != b else { continue }
            if seen.insert([min(a, b), max(a, b)]).inserted { pairs.append((a, b)) }
        }

        // ponytail: O(n²), Barnes-Hut above ~500
        let k = min(max((world * world / Double(n)).squareRoot() * 0.5, 230), 420)
        let cutoff = 2.5 * k
        let gravity = 0.1
        let low = Double(margin), high = world - Double(margin)
        var temperature = world / 8
        let cooling = temperature / Double(iterations)

        var dx = [Double](repeating: 0, count: n)
        var dy = [Double](repeating: 0, count: n)
        for _ in 0..<iterations {
            for i in 0..<n { dx[i] = 0; dy[i] = 0 }
            // Repulsion, short-range so far clusters don't fling each other out.
            for i in 0..<n {
                for j in (i + 1)..<n {
                    var ex = x[i] - x[j], ey = y[i] - y[j]
                    var d = (ex * ex + ey * ey).squareRoot()
                    if d < 0.01 {
                        // Coincident: split along a direction fixed by the indices.
                        ex = cos(Double(i) * 2.4 + Double(j)); ey = sin(Double(i) * 2.4 + Double(j)); d = 1
                    }
                    guard d < cutoff else { continue }
                    let f = k * k / d
                    dx[i] += ex / d * f; dy[i] += ey / d * f
                    dx[j] -= ex / d * f; dy[j] -= ey / d * f
                }
            }
            // Attraction along edges.
            for (a, b) in pairs {
                let ex = x[a] - x[b], ey = y[a] - y[b]
                let d = max((ex * ex + ey * ey).squareRoot(), 0.01)
                let f = d * d / k
                dx[a] -= ex / d * f; dy[a] -= ey / d * f
                dx[b] += ex / d * f; dy[b] += ey / d * f
            }
            for i in 0..<n {
                dx[i] += (Double(centre.x) - x[i]) * gravity
                dy[i] += (Double(centre.y) - y[i]) * gravity
                guard !pinned[i] else { continue }
                let length = (dx[i] * dx[i] + dy[i] * dy[i]).squareRoot()
                guard length > 0 else { continue }
                let step = min(length, temperature)
                x[i] = min(max(x[i] + dx[i] / length * step, low), high)
                y[i] = min(max(y[i] + dy[i] / length * step, low), high)
            }
            temperature = max(temperature - cooling, 0.5)
        }

        var out: [GraphNodeID: CGPoint] = [:]
        for (i, node) in nodes.enumerated() { out[node] = CGPoint(x: x[i], y: y[i]) }
        return out
    }

    /// `run` on a background thread. A capture-free static wrapper, as in
    /// `SyncEngine.runDetached`: a `Task { }` formed in a view would inherit
    /// the main actor.
    static func runDetached(_ input: Input) async -> [GraphNodeID: CGPoint] {
        await Task.detached(priority: .userInitiated) { GraphForceLayout.run(input) }.value
    }
}
