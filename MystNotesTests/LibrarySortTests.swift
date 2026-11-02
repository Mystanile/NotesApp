import XCTest
@testable import Mystnotes

/// The library's sort and Custom-order maths. Pure value logic: no SwiftData.
final class LibrarySortTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ title: String, created: Double = 0, modified: Double = 0,
                      order: Double? = nil, id: UUID = UUID()) -> LibrarySortItem {
        LibrarySortItem(id: id, title: title,
                        created: base.addingTimeInterval(created), modified: base.addingTimeInterval(modified),
                        manualOrder: order)
    }

    private func titles(_ items: [LibrarySortItem], _ key: LibrarySortKey, ascending: Bool = true) -> [String] {
        LibrarySort.sorted(items, by: LibrarySortOrder(key: key, ascending: ascending)) { $0 }.map(\.title)
    }

    // MARK: Keys and directions

    func testTitle_ignoresCaseAndSortsNumbersNaturally() {
        let items = [item("banana"), item("Cherry"), item("apple"), item("Item 10"), item("Item 2")]
        XCTAssertEqual(titles(items, .title), ["apple", "banana", "Cherry", "Item 2", "Item 10"])
        XCTAssertEqual(titles(items, .title, ascending: false), ["Item 10", "Item 2", "Cherry", "banana", "apple"])
    }

    func testDateEdited_newestFirstWhenDescending() {
        let items = [item("a", modified: 10), item("b", modified: 30), item("c", modified: 20)]
        XCTAssertEqual(titles(items, .modified, ascending: false), ["b", "c", "a"])
        XCTAssertEqual(titles(items, .modified, ascending: true), ["a", "c", "b"])
    }

    func testDateCreated_usesCreationNotEdit() {
        let items = [item("a", created: 30, modified: 1), item("b", created: 10, modified: 99), item("c", created: 20, modified: 50)]
        XCTAssertEqual(titles(items, .created, ascending: true), ["b", "c", "a"])
        XCTAssertEqual(titles(items, .created, ascending: false), ["a", "c", "b"])
    }

    func testTies_fallBackToTitleThenId_soTheOrderIsStable() {
        let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let high = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let items = [item("same", id: high), item("same", id: low), item("Alpha", id: UUID())]
        let sorted = LibrarySort.sorted(items, by: LibrarySortOrder(key: .modified, ascending: false)) { $0 }
        XCTAssertEqual(sorted.map(\.title), ["Alpha", "same", "same"])
        XCTAssertEqual(sorted.dropFirst().map(\.id), [low, high])
        let reversed = LibrarySort.sorted(Array(items.reversed()), by: LibrarySortOrder(key: .modified, ascending: false)) { $0 }
        XCTAssertEqual(sorted, reversed)
    }

    // MARK: Custom

    func testCustom_followsManualOrder_andIgnoresDirection() {
        let items = [item("c", order: 3), item("a", order: 1), item("b", order: 2)]
        XCTAssertEqual(titles(items, .custom, ascending: true), ["a", "b", "c"])
        XCTAssertEqual(titles(items, .custom, ascending: false), ["a", "b", "c"])
    }

    func testCustom_nilOrderSortsLast_newestEditFirst() {
        let items = [item("old", modified: 1), item("second", order: 2), item("new", modified: 9), item("first", order: 1)]
        XCTAssertEqual(titles(items, .custom), ["first", "second", "new", "old"])
    }

    func testCustom_negativeAndFractionalOrdersSort() {
        let items = [item("b", order: 0.5), item("a", order: -3), item("c", order: 0.75)]
        XCTAssertEqual(titles(items, .custom), ["a", "b", "c"])
    }

    // MARK: manualOrder(movingTo:in:)

    func testMidpoint_betweenTwoNeighbours() {
        let result = LibrarySort.manualOrder(movingTo: 1, in: [1.0, 3.0])
        XCTAssertEqual(result.value, 2.0)
        XCTAssertNil(result.renumber)
    }

    func testFirstAndLast_stepOneFromTheNeighbour() {
        XCTAssertEqual(LibrarySort.manualOrder(movingTo: 0, in: [1.0, 3.0]).value, 0.0)
        XCTAssertEqual(LibrarySort.manualOrder(movingTo: 2, in: [1.0, 3.0]).value, 4.0)
        XCTAssertEqual(LibrarySort.manualOrder(movingTo: 0, in: [-5.0]).value, -6.0)
    }

    func testAloneInTheLevel_getsOne() {
        let result = LibrarySort.manualOrder(movingTo: 0, in: [])
        XCTAssertEqual(result.value, 1.0)
        XCTAssertNil(result.renumber)
    }

    func testIndexOutOfRange_isClamped() {
        XCTAssertEqual(LibrarySort.manualOrder(movingTo: 99, in: [1.0, 2.0]).value, 3.0)
        XCTAssertEqual(LibrarySort.manualOrder(movingTo: -4, in: [1.0, 2.0]).value, 0.0)
    }

    func testGapUnderOneMillionth_renumbersTheWholeLevel() {
        let result = LibrarySort.manualOrder(movingTo: 1, in: [1.0, 1.0 + 1e-7, 5.0])
        XCTAssertNil(result.value)
        XCTAssertEqual(result.renumber, [1.0, 2.0, 3.0, 4.0])
    }

    func testGapJustAboveTheLimit_isStillSplit() throws {
        let result = LibrarySort.manualOrder(movingTo: 1, in: [1.0, 1.0 + 4e-6])
        XCTAssertEqual(try XCTUnwrap(result.value), 1.0 + 2e-6, accuracy: 1e-12)
        XCTAssertNil(result.renumber)
    }

    func testRepeatedlyDroppingIntoTheSameGap_eventuallyRenumbers() {
        var orders: [Double?] = [1.0, 2.0]
        var renumbered = false
        for _ in 0..<40 {
            let result = LibrarySort.manualOrder(movingTo: 1, in: orders)
            if let value = result.value {
                orders = [1.0, value]   // the item just placed is the next upper neighbour
            } else {
                XCTAssertEqual(result.renumber?.count, orders.count + 1)
                renumbered = true
                break
            }
        }
        XCTAssertTrue(renumbered, "halving the same gap must hit the 1e-6 floor and renumber")
    }

    func testNeighbourWithoutAnOrder_renumbers_exceptBeforeTheUnordered() {
        // Between two unordered items: nothing to take a midpoint of.
        XCTAssertEqual(LibrarySort.manualOrder(movingTo: 1, in: [nil, nil]).renumber, [1.0, 2.0, 3.0])
        // At the front of an all-unordered level.
        XCTAssertEqual(LibrarySort.manualOrder(movingTo: 0, in: [nil]).renumber, [1.0, 2.0])
        // After the last numbered item, in front of unordered ones: unordered sort after.
        let result = LibrarySort.manualOrder(movingTo: 1, in: [4.0, nil])
        XCTAssertEqual(result.value, 5.0)
        // Unordered before it: its predecessor has no number.
        XCTAssertEqual(LibrarySort.manualOrder(movingTo: 1, in: [nil, 7.0]).renumber, [1.0, 2.0, 3.0])
    }

    // MARK: assignments, seed, shifted

    func testAssignments_writeOnlyTheMovedItem_whenThereIsRoom() {
        let a = UUID(), b = UUID(), c = UUID()
        let orders = [a: 1.0, b: 2.0, c: 3.0]
        // c dropped between a and b.
        let result = LibrarySort.assignments(finalOrder: [a, c, b], moved: c, orders: orders)
        XCTAssertEqual(result, [c: 1.5])
    }

    func testAssignments_renumberEveryItem_whenTheGapIsGone() {
        let a = UUID(), b = UUID(), c = UUID()
        let orders = [a: 1.0, b: 1.0 + 1e-9, c: 9.0]
        let result = LibrarySort.assignments(finalOrder: [a, c, b], moved: c, orders: orders)
        XCTAssertEqual(result, [a: 1.0, c: 2.0, b: 3.0])
    }

    func testAssignments_forAnUnorderedLevel_numberTheArrangement() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(LibrarySort.assignments(finalOrder: [b, a], moved: b, orders: [:]), [b: 1.0, a: 2.0])
    }

    func testSeed_numbersTheVisibleOrder() {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertEqual(LibrarySort.seed(visibleOrder: [c, a, b]), [c: 1.0, a: 2.0, b: 3.0])
    }

    func testShifted_movesOnePlace_andStopsAtTheEnds() {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertEqual(LibrarySort.shifted([a, b, c], moving: b, by: 1), [a, c, b])
        XCTAssertEqual(LibrarySort.shifted([a, b, c], moving: b, by: -1), [b, a, c])
        XCTAssertNil(LibrarySort.shifted([a, b, c], moving: a, by: -1))
        XCTAssertNil(LibrarySort.shifted([a, b, c], moving: c, by: 1))
        XCTAssertNil(LibrarySort.shifted([a, b, c], moving: UUID(), by: 1))
    }

    // MARK: Folder order storage

    func testFolderOrder_roundTripsThroughItsJSON() {
        let a = UUID(), b = UUID()
        let data = AppSettings.encodeFolderOrder([a: 1.5, b: -2])
        XCTAssertEqual(AppSettings.decodeFolderOrder(data), [a: 1.5, b: -2])
        XCTAssertEqual(AppSettings.decodeFolderOrder(Data()), [:])
        XCTAssertEqual(AppSettings.decodeFolderOrder(Data("garbage".utf8)), [:])
    }
}
