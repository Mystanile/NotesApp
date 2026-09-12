import XCTest
@testable import Mystnotes

/// M0 task 15: one storage root. The only thing left of the iCloud
/// container path is a one-time adoption of whatever an earlier build
/// left there; this pins its rules.
final class FileStoreTests: XCTestCase {
    private var legacy: URL!
    private var local: URL!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileStoreTests-\(UUID().uuidString)")
        legacy = root.appendingPathComponent("legacy-cloud", isDirectory: true)
        local = root.appendingPathComponent("local", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: legacy.deletingLastPathComponent())
    }

    func testAdoptLegacyFiles_copiesPayloadsMissingLocally_neverOverwrites_neverRemoves() throws {
        try Data("cloud ink".utf8).write(to: legacy.appendingPathComponent("a.drawing"))
        try Data("cloud pdf".utf8).write(to: legacy.appendingPathComponent("b.pdf"))
        try Data("not a payload".utf8).write(to: legacy.appendingPathComponent("notes.txt"))
        try Data("local ink, newer".utf8).write(to: local.appendingPathComponent("a.drawing"))

        FileStore.adoptFiles(from: legacy, into: local)

        XCTAssertEqual(try Data(contentsOf: local.appendingPathComponent("a.drawing")), Data("local ink, newer".utf8),
                       "a file the app already has locally is the one it has been using - keep it")
        XCTAssertEqual(try Data(contentsOf: local.appendingPathComponent("b.pdf")), Data("cloud pdf".utf8),
                       "a payload only the container had comes home")
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.appendingPathComponent("notes.txt").path),
                       "only payload types are adopted")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: legacy.path)),
                       ["a.drawing", "b.pdf", "notes.txt"], "nothing is removed from the source")
    }

    func testURLForFile_isAlwaysUnderTheOneBaseDirectory() {
        let url = FileStore.url(for: "\(UUID().uuidString).drawing")
        XCTAssertEqual(url.deletingLastPathComponent(), FileStore.baseDirectory())
    }
}
