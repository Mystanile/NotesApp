import XCTest
@testable import Mystnotes

/// The page sidebar's reorder maths: where a dragged row lands, how its
/// neighbours slide, and the auto-scroll step.
final class PageSidebarReorderTests: XCTestCase {
    private let h: CGFloat = 100
    private let gap: CGFloat = 14   // stride 114

    private func target(_ dragY: CGFloat, from origin: Int, count: Int = 5) -> Int {
        SidebarReorderModel.targetIndex(dragY: dragY, originIndex: origin, rowHeight: h, spacing: gap, count: count)
    }

    func testNoDrag_staysPut() {
        XCTAssertEqual(target(0, from: 2), 2)
    }

    func testDragDown_crossesAtHalfAStride() {
        XCTAssertEqual(target(56, from: 1), 1)
        XCTAssertEqual(target(58, from: 1), 2)
        XCTAssertEqual(target(114 * 2, from: 1), 3)
    }

    func testDragUp_crossesAtHalfAStride() {
        XCTAssertEqual(target(-56, from: 3), 3)
        XCTAssertEqual(target(-58, from: 3), 2)
        XCTAssertEqual(target(-114 * 3, from: 3), 0)
    }

    func testClampsToTheEnds() {
        XCTAssertEqual(target(100_000, from: 1), 4)
        XCTAssertEqual(target(-100_000, from: 3), 0)
        XCTAssertEqual(target(.infinity, from: 2), 2)
        XCTAssertEqual(target(.nan, from: 2), 2)
    }

    func testSingleAndEmptyLists() {
        XCTAssertEqual(target(500, from: 0, count: 1), 0)
        XCTAssertEqual(target(500, from: 0, count: 0), 0)
    }

    func testNeighbourOffsets_dragDown() {
        // Row 1 dragged onto slot 3: rows 2 and 3 slide up one stride.
        let offsets = (0..<5).map { SidebarReorderModel.offset(forRow: $0, origin: 1, target: 3, rowStride: 114) }
        XCTAssertEqual(offsets, [0, 0, -114, -114, 0])
    }

    func testNeighbourOffsets_dragUp() {
        // Row 3 dragged onto slot 1: rows 1 and 2 slide down one stride.
        let offsets = (0..<5).map { SidebarReorderModel.offset(forRow: $0, origin: 3, target: 1, rowStride: 114) }
        XCTAssertEqual(offsets, [0, 114, 114, 0, 0])
    }

    func testNeighbourOffsets_noMove() {
        let offsets = (0..<5).map { SidebarReorderModel.offset(forRow: $0, origin: 2, target: 2, rowStride: 114) }
        XCTAssertEqual(offsets, [0, 0, 0, 0, 0])
    }

    func testSlotOffset() {
        XCTAssertEqual(SidebarReorderModel.slotOffset(origin: 1, target: 3, rowStride: 114), 228)
        XCTAssertEqual(SidebarReorderModel.slotOffset(origin: 3, target: 1, rowStride: 114), -228)
    }

    func testDragState_countsAutoScrollTowardTheTarget() {
        var d = SidebarDragState(pageID: UUID(), originIndex: 0, count: 10, rowHeight: h,
                                 startScrollOffset: 0, scrollOffset: 0)
        d.translation = 0
        XCTAssertEqual(d.targetIndex, 0)
        // The finger didn't move, but the list scrolled two strides.
        d.scrollOffset = 228
        XCTAssertEqual(d.contentDelta, 228)
        XCTAssertEqual(d.targetIndex, 2)
        XCTAssertEqual(d.liftedViewportTop, d.startViewportTop)
    }

    func testEdgeScrollStep() {
        let f = { (y: CGFloat) in SidebarReorderModel.edgeScrollStep(pointerY: y, viewportHeight: 600, edge: 60, maxStep: 12) }
        XCTAssertEqual(f(300), 0)
        XCTAssertEqual(f(60), 0)
        XCTAssertEqual(f(30), -6, accuracy: 0.001)
        XCTAssertEqual(f(-20), -12, accuracy: 0.001)
        XCTAssertEqual(f(570), 6, accuracy: 0.001)
        XCTAssertEqual(f(900), 12, accuracy: 0.001)
    }

    func testClampedOffset() {
        XCTAssertEqual(SidebarReorderModel.clampedOffset(-5, min: 0, max: 400), 0)
        XCTAssertEqual(SidebarReorderModel.clampedOffset(500, min: 0, max: 400), 400)
        XCTAssertEqual(SidebarReorderModel.clampedOffset(100, min: 0, max: 400), 100)
        XCTAssertEqual(SidebarReorderModel.clampedOffset(100, min: 0, max: -10), 0)
    }

    // MARK: Press-and-hold hit-testing

    private var frames: [Int: CGRect] {
        // Three rows of 100 with a 14 gap, 10 pt in from the left.
        [0: CGRect(x: 10, y: 0, width: 120, height: 100),
         1: CGRect(x: 10, y: 114, width: 120, height: 100),
         2: CGRect(x: 10, y: 228, width: 120, height: 100)]
    }

    func testRowIndex_findsTheRowUnderThePress() {
        XCTAssertEqual(SidebarReorderModel.rowIndex(at: CGPoint(x: 50, y: 50), frames: frames), 0)
        XCTAssertEqual(SidebarReorderModel.rowIndex(at: CGPoint(x: 50, y: 120), frames: frames), 1)
        XCTAssertEqual(SidebarReorderModel.rowIndex(at: CGPoint(x: 129, y: 327), frames: frames), 2)
    }

    func testRowIndex_gapsAndOutsideAreNoRow() {
        XCTAssertNil(SidebarReorderModel.rowIndex(at: CGPoint(x: 50, y: 107), frames: frames))
        XCTAssertNil(SidebarReorderModel.rowIndex(at: CGPoint(x: 5, y: 50), frames: frames))
        XCTAssertNil(SidebarReorderModel.rowIndex(at: CGPoint(x: 50, y: 400), frames: frames))
        XCTAssertNil(SidebarReorderModel.rowIndex(at: CGPoint(x: 50, y: .nan), frames: frames))
        XCTAssertNil(SidebarReorderModel.rowIndex(at: CGPoint(x: 50, y: 50), frames: [:]))
    }

    func testRowIndex_overlapPicksTheLowestIndex() {
        let overlapping: [Int: CGRect] = [3: CGRect(x: 0, y: 0, width: 50, height: 50),
                                          2: CGRect(x: 0, y: 0, width: 50, height: 50)]
        XCTAssertEqual(SidebarReorderModel.rowIndex(at: CGPoint(x: 10, y: 10), frames: overlapping), 2)
    }

    func testMenuCorner_isTheTopTrailing44() {
        let frame = frames[0]!
        XCTAssertTrue(SidebarReorderModel.isInMenuCorner(CGPoint(x: 120, y: 20), of: frame))
        XCTAssertFalse(SidebarReorderModel.isInMenuCorner(CGPoint(x: 60, y: 20), of: frame))
        XCTAssertFalse(SidebarReorderModel.isInMenuCorner(CGPoint(x: 120, y: 60), of: frame))
    }
}
