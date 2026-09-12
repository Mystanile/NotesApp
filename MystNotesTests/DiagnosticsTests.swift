import XCTest
@testable import Mystnotes

/// M0 task 21. MetricKit itself can only be exercised on a device; what a
/// unit test can pin is everything around it: the log keeps its tail, a
/// payload written where the reporter puts them ends up in the export,
/// and the export is a real archive.
final class DiagnosticsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Diagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testLog_appendsLines_andTrimKeepsTheTailOnWholeLines() throws {
        let log = directory.appendingPathComponent("app.log")
        for i in 0..<200 { AppLog.append("line \(i) " + String(repeating: "x", count: 100) + "\n", to: log) }
        let full = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(full.hasPrefix("line 0 "))

        AppLog.trim(log, to: 2_000)
        let trimmed = try String(contentsOf: log, encoding: .utf8)
        XCTAssertLessThanOrEqual(trimmed.utf8.count, 2_000)
        XCTAssertTrue(trimmed.hasPrefix("line "), "trim starts at a line boundary, not mid-line")
        XCTAssertTrue(trimmed.hasSuffix("line 199 " + String(repeating: "x", count: 100) + "\n"), "the newest lines are the ones kept")
    }

    func testExport_isAZipContainingTheDiagnosticsAndASummary() throws {
        AppLog.append("2026-09-12T00:00:00Z [test] something happened\n", to: directory.appendingPathComponent("app.log"))
        try Data(#"{"diagnosticMetaData":{"appVersion":"1.0"},"callStackTree":{}}"#.utf8)
            .write(to: directory.appendingPathComponent("diagnostic-2026-09-12T00-00-00Z-abcd1234.json"))

        let archive = try DiagnosticsExport.makeArchive(of: directory, summary: "MystNotes diagnostics\napp: test\n")
        defer { try? FileManager.default.removeItem(at: archive) }

        let bytes = try Data(contentsOf: archive)
        XCTAssertEqual(archive.pathExtension, "zip")
        XCTAssertEqual(Array(bytes.prefix(2)), [0x50, 0x4B], "a zip archive starts with PK")
        XCTAssertGreaterThan(bytes.count, 200)
        // Entry names are stored uncompressed in a zip's local headers, so
        // the files' presence is checkable without an unarchiver.
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.contains("app.log"))
        XCTAssertTrue(text.contains("diagnostic-2026-09-12T00-00-00Z-abcd1234.json"))
        XCTAssertTrue(text.contains("summary.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("summary.txt").path))
    }
}
