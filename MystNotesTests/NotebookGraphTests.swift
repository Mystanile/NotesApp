import XCTest
import SwiftData
import SwiftUI
@testable import Mystnotes

final class NotebookGraphTests: XCTestCase {
    @MainActor private static var container: ModelContainer?

    func testLayout_isDeterministic_insideSize_withDistinctPoints() {
        let ids = (0..<7).map { _ in UUID() }
        let size = CGSize(width: 600, height: 500)
        let a = NotebookGraphView.layout(pageIDs: ids, edges: [], in: size)
        let b = NotebookGraphView.layout(pageIDs: ids, edges: [], in: size)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 7)
        XCTAssertEqual(Set(a.values.map { "\($0.x),\($0.y)" }).count, 7)
        for p in a.values { XCTAssertTrue(CGRect(origin: .zero, size: size).contains(p)) }
    }

    func testEdges_dropSelfLinksAndForeignPages() {
        let nb = Notebook(title: "N")
        let pages = (0..<3).map { Page(index: $0, notebook: nb) }
        let links = [
            Link(sourcePageID: pages[0].id, destinationPageID: pages[1].id),
            Link(sourcePageID: pages[0].id, destinationPageID: pages[1].id),
            Link(sourcePageID: pages[2].id, destinationPageID: pages[2].id),
            Link(sourcePageID: pages[1].id, destinationPageID: UUID()),
            Link(sourcePageID: UUID(), destinationPageID: pages[0].id),
        ]
        let e = NotebookGraphView.edges(pages: pages, links: links)
        XCTAssertEqual(e.count, 1)
        XCTAssertEqual(e[0].0, pages[0].id)
        XCTAssertEqual(e[0].1, pages[1].id)
    }

    @MainActor
    func testRender_writesPicture() async throws {
        let container = try Self.container ?? ModelContainer(for: Folder.self, Notebook.self, Page.self, TypedTextBlock.self,
                                                             Sticker.self, ImportedDocument.self, Link.self,
                                                             configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        Self.container = container
        let context = container.mainContext
        let nb = Notebook(title: "Map")
        context.insert(nb)
        let pages = (0..<6).map { Page(index: $0, notebook: nb) }
        pages[1].title = "Worked example"
        pages.forEach { context.insert($0) }
        nb.pages = pages
        let links = [(0, 1), (1, 3), (3, 0), (4, 1)].map { Link(sourcePageID: pages[$0.0].id, destinationPageID: pages[$0.1].id) }
        links.forEach { context.insert($0) }
        try context.save()

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 700, height: 600)
        window.rootViewController = UIHostingController(rootView: NotebookGraphView(pages: pages, links: links) { _ in })
        window.makeKeyAndVisible()
        defer { window.rootViewController = nil; window.isHidden = true }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("graph.png")
        try XCTUnwrap(image.pngData()).write(to: url)
        print("[shot] \(url.path)")
    }

    // MARK: Placement and the world

    func testPlaced_savedPositionsWin_andADragMovesOnlyItsCard() {
        // Changed Nov 2, 2026: saved fractions now mean fractions of the fixed
        // 2000 x 2000 world, not of the sheet, so the sheet size is gone from
        // the signature and a drag is a world point.
        let a = UUID(), b = UUID()
        let computed = [a: CGPoint(x: 100, y: 100), b: CGPoint(x: 300, y: 100)]
        let placed = NotebookGraphView.placed(computed, saved: [a: CGPoint(x: 0.5, y: 0.25), UUID(): CGPoint(x: 0, y: 0)],
                                              dragging: (b, CGPoint(x: 280, y: 130)))
        XCTAssertEqual(placed[a], CGPoint(x: 1000, y: 500))
        XCTAssertEqual(placed[b], CGPoint(x: 280, y: 130))
        XCTAssertEqual(placed.count, 2, "a saved position for a page that's gone is ignored")
    }

    @MainActor
    func testWorldFractions_roundTrip_andDoNotDependOnTheSheet() {
        let fraction = CGPoint(x: 0.3, y: 0.8)
        let world = GraphWorld.point(fromFraction: fraction)
        XCTAssertEqual(world.x, 600, accuracy: 1e-9)
        XCTAssertEqual(world.y, 1600, accuracy: 1e-9)
        XCTAssertEqual(GraphWorld.fraction(from: world).x, fraction.x, accuracy: 1e-12)
        XCTAssertEqual(GraphWorld.fraction(from: world).y, fraction.y, accuracy: 1e-12)
        XCTAssertEqual(GraphWorld.fraction(from: CGPoint(x: -50, y: 9_000)), CGPoint(x: 0, y: 1), "clamped like the stored form")

        // Whatever size the sheet is, the same saved fraction lands on the same world point.
        let id = UUID()
        for sheet in [CGSize(width: 700, height: 600), CGSize(width: 1366, height: 1024)] {
            _ = sheet   // the sheet no longer takes part: that is the point
            let placed = NotebookGraphView.placed([id: .zero], saved: [id: fraction])
            XCTAssertEqual(placed[id]?.x ?? .nan, world.x, accuracy: 1e-9)
            XCTAssertEqual(placed[id]?.y ?? .nan, world.y, accuracy: 1e-9)
        }

        // And through the stored JSON.
        let nb = Notebook(title: "N")
        nb.setGraphPosition(fraction, forPageID: id)
        XCTAssertEqual(nb.graphPositions[id], fraction)
    }

    func testDragMaths_divideByTheZoom_andStayInTheWorld() {
        let start = CGPoint(x: 100, y: 100)
        XCTAssertEqual(GraphViewport.dragTarget(start: start, translation: CGSize(width: 40, height: -20), scale: 2),
                       CGPoint(x: 120, y: 90))
        XCTAssertEqual(GraphViewport.dragTarget(start: start, translation: CGSize(width: 40, height: -20), scale: 0.5),
                       CGPoint(x: 180, y: 60))
        XCTAssertEqual(GraphViewport.dragTarget(start: start, translation: CGSize(width: -1000, height: 99_999), scale: 1),
                       CGPoint(x: 0, y: GraphWorld.size))
    }

    func testViewport_zoomKeepsTheAnchor_clampsTheScale_andFits() {
        let v = GraphViewport(scale: 1, offset: CGPoint(x: 10, y: 20))
        let anchor = CGPoint(x: 300, y: 200)
        let before = v.toWorld(anchor)
        let zoomed = v.zoomed(by: 2, around: anchor)
        XCTAssertEqual(zoomed.scale, 2, accuracy: 1e-9)
        let after = zoomed.toWorld(anchor)
        XCTAssertEqual(before.x, after.x, accuracy: 1e-9)
        XCTAssertEqual(before.y, after.y, accuracy: 1e-9)
        XCTAssertEqual(v.zoomed(by: 100, around: anchor).scale, GraphViewport.maxScale)
        XCTAssertEqual(v.zoomed(by: 0.001, around: anchor).scale, GraphViewport.minScale)

        let size = CGSize(width: 800, height: 600)
        let content = CGRect(x: 500, y: 700, width: 1000, height: 400)
        let fit = GraphViewport.fitting(content, in: size)
        let visible = fit.visibleWorldRect(in: size)
        XCTAssertTrue(visible.contains(content), "fit shows all of the content")
        XCTAssertEqual(visible.midX, content.midX, accuracy: 0.001)
        let tiny = GraphViewport.fitting(CGRect(x: 900, y: 900, width: 100, height: 50), in: size)
        XCTAssertEqual(tiny.scale, GraphViewport.maxFitScale, "fit doesn't blow a small map up")
    }

    // MARK: Force layout

    private func forceInput(count: Int, edges: [(Int, Int)], fixed: [Int: CGPoint] = [:]) -> (GraphForceLayout.Input, [GraphNodeID]) {
        let ids = (0..<count).map { _ in UUID() }
        let nodes = ids.map { GraphNodeID.page($0) }
        let ellipse = NotebookGraphView.layout(pageIDs: ids, edges: [],
                                               in: CGSize(width: GraphWorld.size, height: GraphWorld.size))
        var seeds: [GraphNodeID: CGPoint] = [:]
        for (i, id) in ids.enumerated() { seeds[.page(id)] = fixed[i] ?? ellipse[id] }
        let pairs = edges.map { GraphForceLayout.Pair(a: nodes[$0.0], b: nodes[$0.1]) }
        return (GraphForceLayout.Input(nodes: nodes, edges: pairs, seeds: seeds,
                                       fixed: Set(fixed.keys.map { nodes[$0] })), nodes)
    }

    func testForceLayout_isDeterministic_andInsideTheWorld() {
        let (input, nodes) = forceInput(count: 9, edges: [(0, 1), (1, 2), (2, 3), (5, 6)])
        let a = GraphForceLayout.run(input), b = GraphForceLayout.run(input)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 9)
        for node in nodes {
            let p = try? XCTUnwrap(a[node])
            XCTAssertTrue(GraphWorld.bounds.contains(p ?? CGPoint(x: -1, y: -1)))
        }
        XCTAssertEqual(Set(a.values.map { "\($0.x),\($0.y)" }).count, 9, "no two cards on the same point")
    }

    func testForceLayout_linkedPagesEndCloserThanUnlinked() {
        // Two groups whose members alternate around the seed ellipse, so
        // the layout has to pull each group together; two pages stay unlinked.
        // (A perfectly symmetric graph, e.g. two interleaved triples and
        // nothing else, can sit in a symmetric local minimum; that is a
        // property of force layouts, not a bug, so the fixture avoids it.)
        let groupA = [0, 2, 4], groupB = [1, 3, 5]
        var edges: [(Int, Int)] = []
        for group in [groupA, groupB] { for x in group { for y in group where x < y { edges.append((x, y)) } } }
        let (input, nodes) = forceInput(count: 8, edges: edges)
        let out = GraphForceLayout.run(input)
        func dist(_ i: Int, _ j: Int) -> CGFloat {
            let p = out[nodes[i]]!, q = out[nodes[j]]!
            return hypot(p.x - q.x, p.y - q.y)
        }
        let linked = Set(edges.map { [$0.0, $0.1] })
        var linkedSum: CGFloat = 0, linkedN: CGFloat = 0, otherSum: CGFloat = 0, otherN: CGFloat = 0
        for i in 0..<8 { for j in (i + 1)..<8 {
            if linked.contains([i, j]) { linkedSum += dist(i, j); linkedN += 1 } else { otherSum += dist(i, j); otherN += 1 }
        } }
        XCTAssertLessThan(linkedSum / linkedN, 0.6 * otherSum / otherN)
    }

    func testForceLayout_leavesSavedPositionsExactly_andPlacesTheRest() {
        let pinned = [0: CGPoint(x: 400, y: 400), 3: CGPoint(x: 1500, y: 1200)]
        let (input, nodes) = forceInput(count: 5, edges: [(0, 1), (1, 2), (3, 4)], fixed: pinned)
        let out = GraphForceLayout.run(input)
        XCTAssertEqual(out[nodes[0]], pinned[0])
        XCTAssertEqual(out[nodes[3]], pinned[3])
        XCTAssertNotEqual(out[nodes[1]], input.seeds[nodes[1]], "an unplaced card moves")
        // A neighbour of a pinned card ends nearer it than a stranger does.
        let d01 = hypot(out[nodes[1]]!.x - 400, out[nodes[1]]!.y - 400)
        let d41 = hypot(out[nodes[4]]!.x - 400, out[nodes[4]]!.y - 400)
        XCTAssertLessThan(d01, d41)
    }

    func testForceLayout_emptyAndSingle() {
        XCTAssertTrue(GraphForceLayout.run(GraphForceLayout.Input(nodes: [], edges: [], seeds: [:], fixed: [])).isEmpty)
        let only = GraphNodeID.page(UUID())
        let out = GraphForceLayout.run(GraphForceLayout.Input(nodes: [only], edges: [], seeds: [only: CGPoint(x: 5, y: 6)], fixed: []))
        XCTAssertEqual(out[only], CGPoint(x: 5, y: 6))
    }

    func testForceLayout_detachedMatchesDirect() async {
        let (input, _) = forceInput(count: 6, edges: [(0, 1)])
        let result = await GraphForceLayout.runDetached(input)
        XCTAssertEqual(result, GraphForceLayout.run(input))
    }

    // MARK: Scene: edge kinds, chips, tags

    /// A node link without a ModelContext (`Links.makeNode` saves).
    @MainActor
    private func makeNode(on page: Page, title: String) -> Link {
        let link = Link(sourcePageID: page.id, destinationPageID: page.id)
        link.kind = "node"; link.destinationKind = "region"; link.title = title
        return link
    }

    private func scenePages(_ n: Int, in nb: Notebook) -> [Page] { (0..<n).map { Page(index: $0, notebook: nb) } }

    @MainActor
    func testScene_edgeKindFollowsTheLinkShape() {
        let nb = Notebook(title: "N")
        let p = scenePages(4, in: nb)
        let node = makeNode(on: p[1], title: "Proof")
        let plain = Link(sourcePageID: p[0].id, destinationPageID: p[1].id)
        let mention = Link(sourcePageID: p[0].id, destinationPageID: p[2].id); mention.kind = "mention"
        let transclusion = Link(sourcePageID: p[3].id, destinationPageID: p[1].id)
        transclusion.kind = "transclusion"; transclusion.destinationKind = "region"; transclusion.destinationID = node.id.uuidString
        let toNode = Link(sourcePageID: p[2].id, destinationPageID: p[1].id)
        toNode.destinationKind = "region"; toNode.destinationID = node.id.uuidString
        let foreign = Link(sourcePageID: p[0].id, destinationPageID: UUID())
        let unfinished = Link(sourcePageID: p[0].id, destinationPageID: p[0].id)

        let scene = GraphScene.build(pages: p, links: [plain, mention, transclusion, toNode, foreign, unfinished, node])
        func edge(_ from: UUID, _ to: GraphNodeID) -> EdgeKind? {
            scene.edges.first { $0.from == .page(from) && $0.to == to }?.kind
        }
        XCTAssertEqual(edge(p[0].id, .page(p[1].id)), .explicit)
        XCTAssertEqual(edge(p[0].id, .page(p[2].id)), .mention)
        XCTAssertEqual(edge(p[3].id, .chip(node.id)), .transclusion)
        XCTAssertEqual(edge(p[2].id, .chip(node.id)), .explicit, "a link to a region targets the chip, not the page")
        XCTAssertNil(edge(p[2].id, .page(p[1].id)))
        XCTAssertEqual(scene.edges.count, 4, "foreign, unfinished and the node itself draw no edge")
        XCTAssertEqual(scene.chips.map(\.title), ["Proof"])
        XCTAssertEqual(scene.chips.first?.pageID, p[1].id)
    }

    @MainActor
    func testScene_aRegionLinkWhoseNodeIsGoneFallsBackToThePage() {
        let nb = Notebook(title: "N")
        let p = scenePages(2, in: nb)
        let l = Link(sourcePageID: p[0].id, destinationPageID: p[1].id)
        l.destinationKind = "region"; l.destinationID = UUID().uuidString
        let scene = GraphScene.build(pages: p, links: [l])
        XCTAssertEqual(scene.edges, [GraphEdge(from: .page(p[0].id), to: .page(p[1].id), kind: .explicit)])
    }

    @MainActor
    func testScene_tagNodesAreDerived_andAddNoLinkEdges() {
        let nb = Notebook(title: "N")
        let p = scenePages(3, in: nb)
        let links = [Link(sourcePageID: p[0].id, destinationPageID: p[1].id)]
        let before = GraphScene.build(pages: p, links: links)
        p[0].tags = ["Physics", "exam"]
        p[1].tags = ["physics"]
        p[2].tags = ["#Exam", "  "]
        let after = GraphScene.build(pages: p, links: links)
        XCTAssertEqual(links.count, 1, "the links are never touched")
        XCTAssertEqual(after.linkEdges, before.linkEdges)
        XCTAssertEqual(after.tags.map(\.key), ["exam", "physics"])
        XCTAssertEqual(after.tags.first { $0.key == "physics" }?.name, "Physics", "first spelling wins")
        XCTAssertEqual(after.tags.first { $0.key == "physics" }?.pageIDs.count, 2)
        XCTAssertEqual(after.edges.filter { $0.kind == .tag }.count, 4)
        XCTAssertTrue(after.edges.filter { $0.kind == .tag }.allSatisfy { !$0.isDirected })
        XCTAssertTrue(before.tags.isEmpty)
    }

    @MainActor
    func testScene_countsAndUnlinkedPages() {
        let nb = Notebook(title: "N")
        let p = scenePages(4, in: nb)
        let node = makeNode(on: p[1], title: "N1")
        let links = [Link(sourcePageID: p[0].id, destinationPageID: p[1].id),
                     Link(sourcePageID: p[2].id, destinationPageID: p[1].id), node]
        let toNode = Link(sourcePageID: p[1].id, destinationPageID: p[1].id)   // its own node: not a link to another page
        toNode.destinationKind = "region"; toNode.destinationID = node.id.uuidString
        let scene = GraphScene.build(pages: p, links: links + [toNode])
        XCTAssertEqual(scene.linkCounts(for: p[1].id).from, 2)
        XCTAssertEqual(scene.linkCounts(for: p[1].id).to, 0)
        XCTAssertEqual(scene.linkCounts(for: p[0].id).to, 1)
        XCTAssertEqual(scene.unlinkedPageIDs, [p[3].id])
        XCTAssertEqual(scene.linkDegrees()[p[1].id], 2)
    }

    // MARK: Geometry

    func testChips_orbitDeterministically_andClearTheCard() {
        let page = CGPoint(x: 1000, y: 1000)
        let a = GraphGeometry.chipCenters(around: page, count: 5)
        XCTAssertEqual(a, GraphGeometry.chipCenters(around: page, count: 5))
        XCTAssertEqual(Set(a.map { "\($0.x),\($0.y)" }).count, 5)
        let card = CGRect(x: 1000 - 84, y: 1000 - 52, width: 168, height: 104)
        for c in GraphGeometry.chipCenters(around: page, count: 11) {
            let r = CGRect(x: c.x - 66, y: c.y - 15, width: 132, height: 30)
            XCTAssertFalse(r.intersects(card))
        }
        XCTAssertTrue(GraphGeometry.chipCenters(around: page, count: 0).isEmpty)
    }

    func testCurve_stopsAtTheBorders_andBowsOppositeWays() {
        let a = CGPoint(x: 200, y: 200), b = CGPoint(x: 700, y: 260)
        let half = CGSize(width: 84, height: 52)
        let ab = try! XCTUnwrap(GraphGeometry.curve(from: a, aHalf: half, to: b, bHalf: half))
        let ba = try! XCTUnwrap(GraphGeometry.curve(from: b, aHalf: half, to: a, bHalf: half))
        let cardA = CGRect(x: 200 - 84, y: 200 - 52, width: 168, height: 104)
        let cardB = CGRect(x: 700 - 84, y: 260 - 52, width: 168, height: 104)
        XCTAssertFalse(cardA.insetBy(dx: 1, dy: 1).contains(ab.start))
        XCTAssertTrue(cardA.insetBy(dx: -8, dy: -8).contains(ab.start))
        XCTAssertTrue(cardB.insetBy(dx: -8, dy: -8).contains(ab.end))
        XCTAssertNotEqual(ab.control, ba.control, "opposite links don't overlap")
        XCTAssertNil(GraphGeometry.curve(from: a, aHalf: half, to: CGPoint(x: 230, y: 210), bHalf: half), "overlapping cards: no edge")
    }

    func testTagHue_isStable_andAvoidsAmber() {
        XCTAssertEqual(GraphGeometry.tagHue("Physics"), GraphGeometry.tagHue("physics"))
        for name in ["a", "exam", "physics", "x y z", "日本"] {
            let h = GraphGeometry.tagHue(name)
            XCTAssertTrue(h >= 0.16 && h <= 0.96)
        }
    }

    // MARK: Filter

    private func infos() -> (pages: [GraphPageInfo], ids: [UUID]) {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let pages = [
            GraphPageInfo(index: 0, title: "Kinematics", tags: ["Physics"], modifiedAt: now, text: "velocity and acceleration"),
            GraphPageInfo(index: 1, title: "Poetry", tags: ["english"], modifiedAt: now.addingTimeInterval(-86_400 * 20), text: ""),
            GraphPageInfo(index: 2, title: nil, tags: ["physics", "exam"], modifiedAt: nil, text: "Newton"),
        ]
        return (pages, pages.map(\.id))
    }

    func testFilter_emptyDimsAndHidesNothing() {
        let (pages, _) = infos()
        let r = GraphFilter().apply(to: pages)
        XCTAssertEqual(r, GraphFilter.Result())
        XCTAssertFalse(GraphFilter().isActive)
        var spaces = GraphFilter(); spaces.searchText = "   "
        XCTAssertTrue(spaces.apply(to: pages).dimmedPageIDs.isEmpty, "whitespace is not a search")
    }

    func testFilter_perCriterion() {
        let (pages, ids) = infos()
        var tag = GraphFilter(); tag.tags = ["physics"]
        XCTAssertEqual(tag.apply(to: pages).dimmedPageIDs, [ids[1]], "tags compare without case")

        var since = GraphFilter(); since.since = Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(-86_400 * 7)
        XCTAssertEqual(since.apply(to: pages).dimmedPageIDs, [ids[1], ids[2]], "a page with no date doesn't match")

        var search = GraphFilter(); search.searchText = "newton"
        let r = search.apply(to: pages)
        XCTAssertEqual(r.dimmedPageIDs, [ids[0], ids[1]])
        XCTAssertEqual(r.highlightedPageIDs, [ids[2]])
        search.searchText = "poet"
        XCTAssertEqual(search.apply(to: pages).highlightedPageIDs, [ids[1]], "titles match")
        search.searchText = "exam"
        XCTAssertEqual(search.apply(to: pages).highlightedPageIDs, [ids[2]], "tags match")

        var kinds = GraphFilter(); kinds = kinds.toggling(.mention)
        XCTAssertEqual(kinds.apply(to: pages).hiddenEdgeKinds, [.mention])
        XCTAssertTrue(kinds.apply(to: pages).dimmedPageIDs.isEmpty, "hiding an edge kind never dims a card")
    }

    func testFilter_combinedCriteriaAllHaveToMatch() {
        let (pages, ids) = infos()
        var f = GraphFilter()
        f.tags = ["physics"]
        f.since = Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(-86_400)
        f.searchText = "velocity"
        let r = f.apply(to: pages)
        XCTAssertEqual(r.dimmedPageIDs, [ids[1], ids[2]])
        XCTAssertEqual(r.highlightedPageIDs, [ids[0]])
        XCTAssertTrue(f.isActive)
    }

    func testFilter_kindToggles() {
        var f = GraphFilter()
        XCTAssertTrue(EdgeKind.allCases.allSatisfy { f.shows($0) })
        f = f.toggling(.tag).toggling(.mention)
        XCTAssertFalse(f.shows(.tag)); XCTAssertFalse(f.shows(.mention)); XCTAssertTrue(f.shows(.explicit))
        f = f.toggling(.tag).toggling(.mention)
        XCTAssertEqual(f, GraphFilter(), "everything back on is the empty filter")
        var last = GraphFilter(kinds: [.explicit])
        last = last.toggling(.explicit)
        XCTAssertEqual(last.kinds, [.explicit], "the last visible kind stays")
    }

    func testAccessibilityLabel() {
        XCTAssertEqual(NotebookGraphView.accessibilityLabel(for: GraphPageInfo(index: 2, title: "Optics"), degree: 3),
                       "Page 3, Optics, 3 links")
        XCTAssertEqual(NotebookGraphView.accessibilityLabel(for: GraphPageInfo(index: 0), degree: 1), "Page 1, 1 link")
    }
}
