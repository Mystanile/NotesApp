import XCTest
@testable import Mystnotes

/// Spotlight item building and the stale-id diff, as pure functions over
/// value snapshots. Nothing here touches CoreSpotlight or SwiftData.
final class SpotlightTests: XCTestCase {

    private func notebook(_ title: String, folder: String? = nil, locked: Bool = false, templates: Bool = false,
                          pages: [SpotlightPageSnapshot] = []) -> SpotlightNotebookSnapshot {
        SpotlightNotebookSnapshot(id: UUID(), title: title, folderName: folder, pageCount: pages.count,
                                  isLocked: locked, isTemplates: templates, pages: pages)
    }

    private func page(_ index: Int, title: String? = nil, text: String = "") -> SpotlightPageSnapshot {
        SpotlightPageSnapshot(id: UUID(), index: index, title: title, text: text)
    }

    func testSpecs_idsTitlesAndDomains() {
        let titled = page(0, title: "Cell biology", text: "mitochondria")
        let plain = page(1)
        let nb = notebook("Biology", folder: "School", pages: [titled, plain])
        let specs = SpotlightItems.specs(from: [nb])

        XCTAssertEqual(specs.map(\.uniqueID),
                       ["notebook:\(nb.id.uuidString)", "page:\(titled.id.uuidString)", "page:\(plain.id.uuidString)"])
        XCTAssertEqual(specs[0].title, "Biology")
        XCTAssertEqual(specs[0].contentDescription, "2 pages \u{00B7} School")
        XCTAssertEqual(specs[1].title, "Cell biology")
        XCTAssertEqual(specs[1].contentDescription, "mitochondria")
        XCTAssertEqual(specs[2].title, "Page 2 \u{00B7} Biology")
        XCTAssertTrue(specs.allSatisfy { $0.domainID == nb.id.uuidString })
    }

    func testSpecs_leaveOutLockedAndTemplatesNotebooks() {
        let open = notebook("Open", pages: [page(0)])
        let locked = notebook("Diary", locked: true, pages: [page(0, text: "secret")])
        let templates = notebook("Templates", templates: true, pages: [page(0)])
        let specs = SpotlightItems.specs(from: [open, locked, templates])
        XCTAssertEqual(specs.count, 2)
        XCTAssertFalse(specs.contains { $0.title.contains("Diary") || $0.contentDescription.contains("secret") })
        XCTAssertFalse(specs.contains { $0.title.contains("Templates") })
    }

    func testDescription_isCappedAndCondensed() {
        let long = String(repeating: "word  \n", count: 200)
        let text = SpotlightItems.condensed([nil, long])
        XCTAssertLessThanOrEqual(text.count, SpotlightItems.descriptionLimit)
        XCTAssertFalse(text.contains("  "))
        XCTAssertFalse(text.contains("\n"))
        let spec = SpotlightItems.specs(from: [notebook("N", pages: [page(0, text: String(repeating: "a", count: 900))])])[1]
        XCTAssertEqual(spec.contentDescription.count, SpotlightItems.descriptionLimit)
    }

    func testStaleIDs_areThoseNoLongerPresent() {
        let stale = SpotlightItems.staleIDs(previous: ["page:a", "page:b", "notebook:c"], current: ["page:b", "page:d"])
        XCTAssertEqual(stale, ["notebook:c", "page:a"])
        XCTAssertEqual(SpotlightItems.staleIDs(previous: [], current: ["x"]), [])
    }

    func testChanged_onlyReturnsNewOrEditedItems() {
        let a = page(0, text: "one"), b = page(1, text: "two")
        let first = SpotlightItems.specs(from: [notebook("N", pages: [a, b])])
        var known: [String: String] = [:]
        for spec in first { known[spec.uniqueID] = SpotlightItems.fingerprint(spec) }
        XCTAssertTrue(SpotlightItems.changed(first, since: known).isEmpty)

        let edited = SpotlightPageSnapshot(id: a.id, index: 0, title: nil, text: "one more")
        let nb = SpotlightNotebookSnapshot(id: UUID(), title: "N", folderName: nil, pageCount: 2,
                                           isLocked: false, isTemplates: false, pages: [edited, b])
        let again = SpotlightItems.specs(from: [nb])
        // Everything under a new notebook id differs only by domain, which the
        // fingerprint ignores; the notebook row and the edited page differ by id/text.
        let changed = SpotlightItems.changed(again, since: known).map(\.uniqueID)
        XCTAssertTrue(changed.contains("page:\(a.id.uuidString)"))
        XCTAssertFalse(changed.contains("page:\(b.id.uuidString)"))
    }

    func testParse_roundTripsIdentifiers() {
        let id = UUID()
        XCTAssertEqual(SpotlightItems.parse(identifier: SpotlightItems.pageID(id)), .page(id))
        XCTAssertEqual(SpotlightItems.parse(identifier: SpotlightItems.notebookID(id)), .notebook(id))
        XCTAssertNil(SpotlightItems.parse(identifier: "page:nope"))
        XCTAssertNil(SpotlightItems.parse(identifier: id.uuidString))
    }

    func testIntentSearch_matchesTitleOrText_skipsLocked_andCaps() {
        let pages = (0..<8).map { page($0, title: "Note \($0)", text: "alpha beta") }
        let open = notebook("Open", pages: pages)
        let locked = notebook("Diary", locked: true, pages: [page(0, title: "alpha secret")])
        XCTAssertEqual(IntentSearch.titles(matching: "ALPHA", in: [open, locked]).count, 5)
        XCTAssertEqual(IntentSearch.titles(matching: "Note 3", in: [open]), ["Note 3"])
        XCTAssertTrue(IntentSearch.titles(matching: "secret", in: [open, locked]).isEmpty)
        XCTAssertTrue(IntentSearch.titles(matching: "  ", in: [open]).isEmpty)
    }
}
