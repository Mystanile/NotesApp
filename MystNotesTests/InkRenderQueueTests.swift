import XCTest
import PencilKit
@testable import Mystnotes

/// Off-screen ink is drawn on its own queue, never on Swift's cooperative
/// pool - where a page strip's worth of thumbnails deadlocked PencilKit on
/// the iPad and blanked every page (Sept 27, 2026). The deadlock itself
/// needs the device's Metal path; this pins the property that prevents it.
final class InkRenderQueueTests: XCTestCase {

    func testWork_runsOnTheInkQueue_notThePool() async {
        let label = await InkRenderQueue.run { String(cString: __dispatch_queue_get_label(nil)) }
        XCTAssertEqual(label, "MystNotes.InkRender")
    }

    /// A strip's worth and more of thumbnails at once all come back - one
    /// at a time on the queue, with the pool left free.
    func testManyThumbnailsAtOnce_allFinish() async {
        let requests = (0..<40).map { _ in
            PageThumbnailRequest(pageID: UUID(), inkStamp: "-", template: "lined", artwork: [],
                                 nominal: CGSize(width: 780, height: 1040), output: CGSize(width: 120, height: 160))
        }
        let rendered = await withTaskGroup(of: Bool.self) { group in
            for request in requests { group.addTask { await PageThumbnailRenderer.render(request) != nil } }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        XCTAssertEqual(rendered, requests.count)
    }
}
