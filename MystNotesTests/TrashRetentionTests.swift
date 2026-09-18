import XCTest
@testable import Mystnotes

/// M0's last open decision: trashed payloads are kept 30 days, then
/// removed. This is the **only** place in the app that removes a payload
/// (invariant 3), so it gets the most suspicious tests in the suite: that
/// it refuses anything that isn't a trash directory, that it only takes
/// what is genuinely past its time, and that it reads the age from the
/// name rather than from a timestamp a sync provider can rewrite.
final class TrashRetentionTests: XCTestCase {
    private var root: URL!
    private var trash: URL!
    private let day: TimeInterval = 24 * 60 * 60

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrashRetentionTests-\(UUID().uuidString)", isDirectory: true)
        trash = root.appendingPathComponent(TrashRetention.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: - Helpers

    /// Puts a payload in `trash/` exactly as `DrawingStore.moveToTrash`
    /// would, `age` ago.
    @discardableResult
    private func trashed(_ base: String = UUID().uuidString, age: TimeInterval,
                         tag: String = "deleted", ext: String = "strokes",
                         bytes: Int = 64, now: Date = Date()) throws -> URL {
        let stamp = Int(now.addingTimeInterval(-age).timeIntervalSince1970 * 1000)
        let url = trash.appendingPathComponent("\(base)-\(stamp)-\(tag).\(ext)")
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    private func names(in directory: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }

    // MARK: - The sweep

    func testSweep_removesOnlyWhatIsPastTheRetentionPeriod() throws {
        let now = Date()
        let old = try trashed(age: 31 * day, now: now)
        let justOld = try trashed(age: 30 * day + 60, now: now)
        let recent = try trashed(age: 29 * day, now: now)
        let today = try trashed(age: 60, now: now)

        let swept = TrashRetention.sweep(trash, olderThan: TrashRetention.defaultPeriod, now: now)

        XCTAssertEqual(swept.removed, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: justOld.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path), "29 days is inside the period")
        XCTAssertTrue(FileManager.default.fileExists(atPath: today.path))
    }

    /// The whole point of the mechanism: a page deleted this morning is
    /// still there tonight, and tomorrow, and in four weeks.
    func testSweep_leavesEverythingAloneForThirtyDays() throws {
        let now = Date()
        for age in [0, 1, 7, 14, 29] {
            try trashed(age: Double(age) * day, now: now)
        }
        let swept = TrashRetention.sweep(trash, olderThan: TrashRetention.defaultPeriod, now: now)
        XCTAssertEqual(swept.removed, 0)
        XCTAssertEqual(try names(in: trash).count, 5)
    }

    /// The guard that stands between a wrong argument and someone's
    /// notebook. `files/` is not `files/trash/`.
    func testSweep_refusesADirectoryThatIsNotTrash() throws {
        let payloads = root.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: payloads, withIntermediateDirectories: true)
        let ink = payloads.appendingPathComponent("\(UUID().uuidString).strokes")
        try Data("real ink".utf8).write(to: ink)

        let swept = TrashRetention.sweep(payloads, olderThan: 1, now: Date().addingTimeInterval(10 * 365 * 24 * 3600))

        XCTAssertEqual(swept.removed, 0)
        XCTAssertEqual(try Data(contentsOf: ink), Data("real ink".utf8))
    }

    func testSweep_ofAMissingOrEmptyDirectoryIsHarmless() {
        let missing = root.appendingPathComponent("nope", isDirectory: true)
            .appendingPathComponent(TrashRetention.directoryName, isDirectory: true)
        XCTAssertEqual(TrashRetention.sweep(missing, olderThan: 1, now: Date()).removed, 0)
        XCTAssertEqual(TrashRetention.sweep(trash, olderThan: 1, now: Date()).removed, 0)
    }

    func testSweep_withNoRetentionPeriodDoesNothing() throws {
        try trashed(age: 400 * day)
        XCTAssertEqual(TrashRetention.sweep(trash, olderThan: 0, now: Date()).removed, 0,
                       "a zero period is a misconfiguration, not an instruction to empty the trash")
    }

    /// A sync provider rewrites modification dates when it downloads a
    /// file. The age has to come from the name, which travels unchanged,
    /// or an evicted item that came back yesterday would look one day old
    /// forever - and one the provider dated *earlier* would be swept
    /// before its time.
    func testAge_comesFromTheName_notTheModificationDate() throws {
        let now = Date()
        let old = try trashed(age: 90 * day, now: now)
        // As if iCloud had just re-downloaded it.
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: old.path)

        let entry = try XCTUnwrap(TrashRetention.entries(in: trash).first)
        XCTAssertEqual(entry.trashedAt.timeIntervalSince1970,
                       now.addingTimeInterval(-90 * day).timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(TrashRetention.sweep(trash, olderThan: TrashRetention.defaultPeriod, now: now).removed, 1)
    }

    func testUnparseableName_fallsBackToItsModificationDate() throws {
        let url = trash.appendingPathComponent("something-a-user-dropped-in.png")
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-90 * day)],
                                             ofItemAtPath: url.path)

        let entry = try XCTUnwrap(TrashRetention.entries(in: trash).first)
        XCTAssertEqual(entry.tag, "unknown")
        XCTAssertEqual(TrashRetention.sweep(trash, olderThan: TrashRetention.defaultPeriod, now: Date()).removed, 1)
    }

    // MARK: - Names

    func testParse_readsTheStampAndTagFromTheEnd() {
        // The base is a UUID, which has dashes of its own.
        let parsed = TrashRetention.parse("6E5F6E3C-0F5B-4C2A-9A1E-2B7D9C0A1F33-1758200000000-conflict.strokes")
        XCTAssertEqual(parsed.tag, "conflict")
        XCTAssertEqual(parsed.trashedAt?.timeIntervalSince1970 ?? 0, 1758200000, accuracy: 0.001)

        XCTAssertNil(TrashRetention.parse("plain.strokes").tag)
        XCTAssertNil(TrashRetention.parse("a-b-c.strokes").trashedAt, "the stamp has to be a number")
    }

    /// The names the app actually writes. If `moveToTrash`'s format ever
    /// changes, this fails rather than the sweep silently falling back to
    /// modification dates.
    func testEveryTagTheAppWritesRoundTrips() throws {
        let now = Date()
        for tag in ["deleted", "conflict", "unreadable", "orphan"] {
            let source = root.appendingPathComponent("\(UUID().uuidString).strokes")
            try Data("ink".utf8).write(to: source)
            DrawingStore.moveToTrash(source, tag: tag)
        }
        let entries = TrashRetention.entries(in: trash)
        XCTAssertEqual(Set(entries.map(\.tag)), ["deleted", "conflict", "unreadable", "orphan"])
        for entry in entries {
            XCTAssertEqual(entry.trashedAt.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 5,
                           "a freshly trashed file is new, so it survives the sweep")
        }
        XCTAssertEqual(TrashRetention.sweep(trash, olderThan: TrashRetention.defaultPeriod, now: now).removed, 0)
    }

    // MARK: - The Settings readout

    func testSummary_countsSizesAndFindsTheOldest() throws {
        let now = Date()
        try trashed(age: 2 * day, bytes: 100, now: now)
        try trashed(age: 40 * day, bytes: 250, now: now)
        try trashed(age: 10 * day, bytes: 50, now: now)

        let summary = TrashRetention.summary(of: [trash])
        XCTAssertEqual(summary.count, 3)
        XCTAssertEqual(summary.bytes, 400)
        XCTAssertEqual(try XCTUnwrap(summary.age(at: now)) / day, 40, accuracy: 0.01)
        XCTAssertFalse(summary.isEmpty)

        XCTAssertTrue(TrashRetention.summary(of: []).isEmpty)
    }

    func testEmptyNow_takesEverything_butOnlyFromTrash() throws {
        try trashed(age: 0)
        try trashed(age: 1)
        let keep = root.appendingPathComponent("not-trash.strokes")
        try Data("ink".utf8).write(to: keep)

        let emptied = TrashRetention.emptyNow([trash, root])
        XCTAssertEqual(emptied.removed, 2)
        XCTAssertTrue(try names(in: trash).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path), "the root isn't a trash directory")
    }

    func testLocalDirectories_areThePayloadTrashAndTheMirrors() {
        let payloads = URL(fileURLWithPath: "/tmp/payloads")
        let mirror = URL(fileURLWithPath: "/tmp/payloads/Library")
        let directories = TrashRetention.localDirectories(payloads: payloads, mirror: mirror)
        XCTAssertEqual(directories.map(\.path), [
            "/tmp/payloads/trash",
            "/tmp/payloads/Library/notebooks/trash",
            "/tmp/payloads/Library/files/trash"
        ])
        for directory in directories {
            XCTAssertEqual(directory.lastPathComponent, TrashRetention.directoryName,
                           "every one of these is passed straight to sweep")
        }
    }
}
