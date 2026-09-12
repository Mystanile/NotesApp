import XCTest
@testable import Mystnotes

/// M0 task 13: a change in the sync folder reaches the engine while the
/// app is open. The cross-process / iCloud half was verified by hand on
/// the Mac (see SyncFolderWatcher); this pins the in-process contract.
@MainActor
final class SyncFolderWatcherTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("notebooks"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testCoordinatedWrites_atAnyDepth_coalesceIntoOneChange() async throws {
        var changes = 0
        var stopped = false
        let watcher = SyncFolderWatcher(url: directory, coalescingInterval: 0.3, stopAccess: { stopped = true }) {
            changes += 1
        }

        // Three writes in quick succession, one nested - a delivery burst.
        write("index.json", in: directory)
        write("tombstones.json", in: directory)
        write("notebooks/a.json", in: directory)

        // Presenter callbacks arrive about a second after the write.
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertEqual(changes, 1, "a burst of writes is one change")

        write("index.json", in: directory)
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertEqual(changes, 2, "a later write is another change")

        watcher.stop()
        XCTAssertTrue(stopped, "stop releases the folder")
        write("index.json", in: directory)
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertEqual(changes, 2, "nothing after stop")
    }

    /// A coordinated write, the way the engine and iCloud's daemon write.
    private func write(_ name: String, in dir: URL) {
        let url = dir.appendingPathComponent(name)
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { target in
            try? Data("{}".utf8).write(to: target, options: .atomic)
        }
        XCTAssertNil(error)
    }
}
