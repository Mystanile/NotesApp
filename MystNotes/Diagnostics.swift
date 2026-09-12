import Foundation
import os
#if canImport(MetricKit)
import MetricKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// M0 task 21: crash reporting without a backend.
///
/// Three pieces, all local:
///
/// - `AppLog` — a small persisted log the durability-critical code writes
///   to (sync outcomes, quarantines, conflicts, rebuilds). Mirrors to
///   `os.Logger` for Console, and keeps the last ~512 KB on disk.
/// - `CrashReporter` — a MetricKit subscriber. The OS hands the app its own
///   crash, hang and disk-write diagnostics, with symbolicated stacks, on
///   the launch after they happen. Each payload is written as JSON. No
///   entitlement, no network. Payloads never arrive on the simulator or
///   under the debugger, so this is verified on device only.
/// - `DiagnosticsExport` — Settings → "Export Diagnostics…": a zip of the
///   above plus a summary, handed to the share sheet. Also the "diagnostics
///   export" M6 asks for.
///
/// Everything lives in `Documents/diagnostics/`.
enum Diagnostics {
    static var directory: URL {
        FileStore.baseDirectory().appendingPathComponent("diagnostics", isDirectory: true)
    }
}

// MARK: - Log

enum AppLog {
    static let maximumBytes = 512 * 1024
    private static let queue = DispatchQueue(label: "MystNotes.AppLog")
    private static let logger = Logger(subsystem: "com.mozynas.Mystnotes", category: "app")
    private static var fileURL: URL { Diagnostics.directory.appendingPathComponent("app.log") }

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Records a line. Cheap to call from anywhere; the write happens on
    /// a serial queue off the caller's thread.
    static func note(_ category: String, _ message: String) {
        logger.notice("[\(category, privacy: .public)] \(message, privacy: .public)")
        let line = "\(stamp.string(from: Date())) [\(category)] \(message)\n"
        queue.async { append(line, to: fileURL) }
    }

    /// Keeps the file from growing forever: on launch, keep the tail.
    static func trimOnLaunch() {
        queue.async { trim(fileURL, to: maximumBytes) }
    }

    static func append(_ line: String, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    static func trim(_ url: URL, to limit: Int) {
        guard let data = try? Data(contentsOf: url), data.count > limit else { return }
        var tail = data.suffix(limit)
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail = tail[tail.index(after: newline)...]
        }
        try? Data(tail).write(to: url, options: .atomic)
    }
}

// MARK: - Crash reports

#if canImport(MetricKit)
final class CrashReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReporter()
    private override init() { super.init() }

    /// Call once at launch.
    func start() {
        MXMetricManager.shared.add(self)
        AppLog.trimOnLaunch()
        AppLog.note("launch", "MystNotes \(DiagnosticsExport.appVersion) started")
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            Self.write(payload.jsonRepresentation(), kind: "diagnostic", timestamp: payload.timeStampEnd)
        }
        AppLog.note("crash", "received \(payloads.count) diagnostic payload(s) from MetricKit")
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        // Daily metrics are large and not what a crash investigation needs;
        // note that they came and move on.
        AppLog.note("metrics", "received \(payloads.count) metric payload(s)")
    }

    /// Writes one payload where the export will find it.
    static func write(_ json: Data, kind: String, timestamp: Date) {
        let fm = FileManager.default
        try? fm.createDirectory(at: Diagnostics.directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: timestamp).replacingOccurrences(of: ":", with: "-")
        let url = Diagnostics.directory.appendingPathComponent("\(kind)-\(stamp)-\(UUID().uuidString.prefix(8)).json")
        try? json.write(to: url, options: .atomic)
    }
}
#endif

// MARK: - Export

enum DiagnosticsExport {
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// Zips `directory` (the diagnostics folder plus a fresh summary) into
    /// a file the share sheet can hand on. Uses NSFileCoordinator's
    /// upload-reading mode, which produces a zip of a directory without
    /// any archive library.
    static func makeArchive(of directory: URL = Diagnostics.directory, summary: String? = nil) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try (summary ?? defaultSummary()).write(to: directory.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let archive = fm.temporaryDirectory.appendingPathComponent("MystNotes-diagnostics-\(stamp).zip")
        try? fm.removeItem(at: archive)

        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: directory, options: .forUploading, error: &coordinationError) { zipped in
            do { try fm.copyItem(at: zipped, to: archive) } catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        return archive
    }

    static func defaultSummary() -> String {
        var lines: [String] = []
        lines.append("MystNotes diagnostics")
        lines.append("app: \(appVersion)")
        #if canImport(UIKit)
        lines.append("device: \(UIDevice.current.model), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
        #endif
        lines.append("exported: \(Date())")
        lines.append("sync folder: \(SyncFolder.displayName ?? "not chosen")")
        lines.append("payload files: \((try? FileManager.default.contentsOfDirectory(atPath: FileStore.baseDirectory().path))?.count ?? -1)")
        return lines.joined(separator: "\n") + "\n"
    }
}
