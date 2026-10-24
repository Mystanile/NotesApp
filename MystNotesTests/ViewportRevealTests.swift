import XCTest
@testable import Mystnotes

/// The page's layers (paper, PDF, images, text) are hidden after a page
/// change until the canvas reports its fit. If that report never comes,
/// they must not stay hidden forever (Oct 24, 2026).
final class ViewportRevealTests: XCTestCase {

    @MainActor
    func testLayers_showAnyway_whenTheCanvasNeverReportsItsFit() async throws {
        let viewport = CanvasViewport()
        viewport.reset(for: UUID())
        XCTAssertFalse(viewport.hasSynced)
        try await Task.sleep(for: .seconds(CanvasViewport.revealAfter + 0.5))
        XCTAssertTrue(viewport.hasSynced, "with no fit reported, the layers show after the timeout")
    }

    @MainActor
    func testANewerPageChange_restartsTheWait() async throws {
        let viewport = CanvasViewport()
        viewport.reset(for: UUID())
        try await Task.sleep(for: .seconds(CanvasViewport.revealAfter * 0.75))
        viewport.reset(for: UUID())
        try await Task.sleep(for: .seconds(CanvasViewport.revealAfter * 0.5))
        XCTAssertFalse(viewport.hasSynced, "the first page's timer must not reveal the second page early")
        try await Task.sleep(for: .seconds(CanvasViewport.revealAfter))
        XCTAssertTrue(viewport.hasSynced)
    }
}
