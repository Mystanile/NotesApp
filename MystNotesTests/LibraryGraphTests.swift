import XCTest
import SwiftData
@testable import Mystnotes

final class LibraryGraphTests: XCTestCase {
    @MainActor private static var container: ModelContainer?

    private func nb(_ title: String, folder: UUID? = nil, folderName: String? = nil,
                    modified: Date = Date(timeIntervalSince1970: 1_000)) -> LibraryMapNotebook {
        LibraryMapNotebook(id: UUID(), title: title, folderID: folder, folderName: folderName,
                           pageCount: 2, modifiedAt: modified)
    }

    /// Two pages per notebook: returns the map and the page ids by notebook.
    private func pages(_ notebooks: [LibraryMapNotebook]) -> (map: [UUID: UUID], ids: [UUID: [UUID]]) {
        var map: [UUID: UUID] = [:]
        var ids: [UUID: [UUID]] = [:]
        for n in notebooks {
            for _ in 0..<2 {
                let p = UUID()
                map[p] = n.id
                ids[n.id, default: []].append(p)
            }
        }
        return (map, ids)
    }

    func testAggregation_countsPairsAndWeights_andDropsIntraNotebookLinks() {
        let (a, b, c) = (nb("A"), nb("B"), nb("C"))
        let p = pages([a, b, c])
        let links: [(source: UUID, destination: UUID)] = [
            (p.ids[a.id]![0], p.ids[b.id]![0]),
            (p.ids[b.id]![1], p.ids[a.id]![1]),   // the reverse direction joins the same pair
            (p.ids[a.id]![0], p.ids[b.id]![1]),
            (p.ids[b.id]![0], p.ids[c.id]![0]),
            (p.ids[a.id]![0], p.ids[a.id]![1]),   // inside one notebook
            (p.ids[c.id]![0], UUID()),            // a deleted page
        ]
        let data = LibraryMapData.build(notebooks: [a, b, c], pageNotebook: p.map, links: links)
        XCTAssertEqual(data.edges.count, 2)
        let ab = data.edges.first { $0.touches(a.id) && $0.touches(b.id) }
        let bc = data.edges.first { $0.touches(b.id) && $0.touches(c.id) }
        XCTAssertEqual(ab?.count, 3)
        XCTAssertEqual(bc?.count, 1)
        XCTAssertEqual(data.linkCounts[a.id], 3)
        XCTAssertEqual(data.linkCounts[b.id], 4)
        XCTAssertEqual(data.linkCounts[c.id], 1)
        XCTAssertEqual(data.maxWeight, 3)
        XCTAssertEqual(data.neighbours(of: b.id).map(\.count), [3, 1])
    }

    func testAggregation_isDeterministic_andLayoutToo() {
        let ns = (0..<8).map { nb("N\($0)") }
        let p = pages(ns)
        var links: [(source: UUID, destination: UUID)] = []
        for i in 0..<ns.count { links.append((p.ids[ns[i].id]![0], p.ids[ns[(i + 1) % ns.count].id]![0])) }
        let first = LibraryMapData.build(notebooks: ns, pageNotebook: p.map, links: links)
        let second = LibraryMapData.build(notebooks: ns.reversed(), pageNotebook: p.map, links: links.reversed())
        XCTAssertEqual(first, second)
        let l1 = GraphForceLayout.run(LibraryMapData.layoutInput(first))
        let l2 = GraphForceLayout.run(LibraryMapData.layoutInput(second))
        XCTAssertEqual(l1, l2)
        XCTAssertEqual(l1.count, 8)
    }

    func testStrokeWidth_runsFromOneToSix() {
        XCTAssertEqual(LibraryMapData.strokeWidth(count: 1, maxCount: 1), 1)
        XCTAssertEqual(LibraryMapData.strokeWidth(count: 1, maxCount: 9), 1)
        XCTAssertEqual(LibraryMapData.strokeWidth(count: 9, maxCount: 9), 6)
        let mid = LibraryMapData.strokeWidth(count: 5, maxCount: 9)
        XCTAssertTrue(mid > 1 && mid < 6)
    }

    func testFilter_dimsNeverHides_andEmptyFilterKeepsAll() {
        let folder = UUID()
        let recent = Date(timeIntervalSince1970: 5_000)
        let a = nb("Calculus", folder: folder, folderName: "Maths", modified: recent)
        let b = nb("Biology", modified: Date(timeIntervalSince1970: 100))
        let all = [a, b]
        XCTAssertEqual(LibraryMapFilter().apply(to: all), LibraryMapFilter.Result())

        var f = LibraryMapFilter()
        f.folders = [folder]
        XCTAssertEqual(f.apply(to: all).dimmed, [b.id])

        f = LibraryMapFilter()
        f.since = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(f.apply(to: all).dimmed, [b.id])

        f = LibraryMapFilter()
        f.searchText = " calc "
        let r = f.apply(to: all)
        XCTAssertEqual(r.dimmed, [b.id])
        XCTAssertEqual(r.highlighted, [a.id])

        f.folders = [nil]   // unfiled only, and the search: nothing matches both
        XCTAssertEqual(f.apply(to: all).dimmed, [a.id, b.id])
        XCTAssertEqual(GraphFilter.dimmedOpacity, 0.15)
    }

    @MainActor
    func testMake_excludesTheTemplatesNotebook() throws {
        let container = try Self.container ?? ModelContainer(for: Folder.self, Notebook.self, Page.self, TypedTextBlock.self,
                                                             Sticker.self, ImportedDocument.self, Link.self,
                                                             configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        Self.container = container
        let context = container.mainContext
        let one = Notebook(title: "One"), two = Notebook(title: "Two"), templates = Notebook(title: "Templates")
        templates.role = PageTemplates.role
        var all: [Page] = []
        for n in [one, two, templates] {
            context.insert(n)
            let page = Page(index: 0, notebook: n)
            context.insert(page)
            n.pages = [page]
            all.append(page)
        }
        let links = [Link(sourcePageID: all[0].id, destinationPageID: all[1].id),
                     Link(sourcePageID: all[0].id, destinationPageID: all[2].id),
                     Link(sourcePageID: all[2].id, destinationPageID: all[1].id)]
        links.forEach { context.insert($0) }

        let data = LibraryMapData.make(notebooks: [one, two, templates], links: links)
        XCTAssertEqual(Set(data.notebooks.map(\.id)), [one.id, two.id])
        XCTAssertEqual(data.edges.count, 1)
        XCTAssertEqual(data.edges.first?.count, 1)
    }
}
