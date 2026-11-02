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
nonisolated enum Diagnostics {
    static var directory: URL {
        FileStore.baseDirectory().appendingPathComponent("diagnostics", isDirectory: true)
    }
}

// MARK: - Log

nonisolated enum AppLog {
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

// MARK: - Main-thread watchdog

/// Notices when the main thread stops responding and writes what it was
/// doing. A background thread pings the main queue every half second;
/// if a ping goes unanswered for `threshold` it logs the last checkpoint
/// (suspect entry points call `checkpoint(_:)`) and then takes the main
/// thread's actual stack: it sends the main thread SIGUSR2, whose handler
/// runs *on* the main thread even while it is blocked in a system call
/// and records `backtrace()`; the watchdog symbolicates that off-thread
/// and writes it to the log. The same technique crash reporters use.
///
/// Built after the iPad froze on entering Airplane Mode with no
/// diagnostic to show for it; the stack capture was added when a
/// launch hang came back with checkpoint "(none)".
nonisolated enum MainThreadWatchdog {
    /// Long enough to be a hang worth a stack capture.
    static let threshold: TimeInterval = 3
    /// Long enough to be *felt* - a stutter while drawing or switching
    /// tools. Logged with the last checkpoint and the main thread's stack,
    /// once per stall, so it's cheap enough to leave on: this is how a
    /// "it freezes sometimes" report turns into a line naming what was
    /// running.
    static let stallThreshold: TimeInterval = 0.4
    /// How often the watchdog thread looks. The main thread is only
    /// pinged when there's no outstanding ping, so this is what bounds
    /// the resolution, not how often main is woken.
    static let pollInterval: TimeInterval = 0.25
    private static let lock = NSLock()
    private static var lastCheckpoint = "(none)"
    private static var lastCheckpointAt = Date()
    private static var pingSent: Date?
    private static var reportedThisHang = false
    private static var reportedStallThisHang = false
    private static var mainThread: pthread_t?
    /// A run loop that answers pings but never goes idle never commits a
    /// frame either: the screen freezes with the main thread "free"
    /// (field report, Oct 4, 2026: frozen until the Pencil touched the
    /// page, no stall in the log). Stamped each time it's about to sleep.
    static let spinThreshold: TimeInterval = 1.5
    /// A mode held this long while idle means UIKit thinks a touch is
    /// still down - tracking mode with nothing touching.
    static let modeThreshold: TimeInterval = 5
    private static var lastIdle = Date()
    private static var idleMode = ""
    private static var idleModeSince = Date()
    private static var reportedSpin = false
    private static var reportedMode = false

    static func checkpoint(_ label: String) {
        lock.lock(); defer { lock.unlock() }
        lastCheckpoint = label
        lastCheckpointAt = Date()
    }

    private static var started = false

    // MARK: Pausing (background)

    nonisolated(unsafe) private static let pauseCondition = NSCondition()
    private static var paused = false
    private static var pingCount = 0

    /// Pings sent to the main thread so far (for tests).
    static var pingsSent: Int {
        lock.lock(); defer { lock.unlock() }
        return pingCount
    }

    /// Parks the watchdog thread (zero wakeups) while the app is in the
    /// background. Any outstanding ping is forgotten, so the pause itself
    /// never reads as a hang. Takes effect within one `pollInterval`.
    static func pause() {
        pauseCondition.lock()
        paused = true
        pauseCondition.unlock()
        clearState()
    }

    static func resume() {
        clearState()
        pauseCondition.lock()
        paused = false
        pauseCondition.broadcast()
        pauseCondition.unlock()
    }

    private static func clearState() {
        lock.lock()
        let now = Date()
        pingSent = nil
        reportedThisHang = false
        reportedStallThisHang = false
        reportedSpin = false
        reportedMode = false
        lastIdle = now
        idleModeSince = now
        lock.unlock()
    }

    /// Blocks while paused. True if it actually waited.
    private static func waitWhilePaused() -> Bool {
        pauseCondition.lock(); defer { pauseCondition.unlock() }
        guard paused else { return false }
        while paused { pauseCondition.wait() }
        return true
    }

    static func start() {
        lock.lock(); let alreadyStarted = started; started = true; lock.unlock()
        guard !alreadyStarted else { return }
        mainThread = pthread_self()   // called on the main thread at launch
        installStackCapture()
        installIdleObserver()
        let thread = Thread {
            while true {
                Thread.sleep(forTimeInterval: pollInterval)
                // Checked after the sleep so a pause that arrived during it
                // sends no further ping; state is reset on the way out.
                if waitWhilePaused() { clearState(); continue }
                lock.lock()
                if pingSent == nil {
                    let busy = Date().timeIntervalSince(lastIdle)
                    if busy >= spinThreshold, !reportedSpin {
                        reportedSpin = true
                        let note = "main run loop answering but not idle for \(Int(busy * 1000)) ms (no frames drawn); last checkpoint '\(lastCheckpoint)'"
                        lock.unlock()
                        AppLog.note("spin", note)
                        if let stack = captureMainThreadStack() { AppLog.note("spin", "main thread stack:\n" + stack) }
                        continue
                    }
                    let held = Date().timeIntervalSince(idleModeSince)
                    if held >= modeThreshold, !reportedMode, idleMode != "kCFRunLoopDefaultMode" {
                        reportedMode = true
                        let note = "main run loop idle in \(idleMode) for \(Int(held)) s; last checkpoint '\(lastCheckpoint)'"
                        lock.unlock()
                        AppLog.note("mode", note)
                        continue
                    }
                }
                if let sent = pingSent {
                    let stalled = Date().timeIntervalSince(sent)
                    if stalled >= threshold, !reportedThisHang {
                        reportedThisHang = true
                        let note = "main thread unresponsive for \(Int(stalled)) s; last checkpoint '\(lastCheckpoint)' \(Int(Date().timeIntervalSince(lastCheckpointAt))) s ago"
                        lock.unlock()
                        AppLog.note("hang", note)
                        if let stack = captureMainThreadStack() {
                            AppLog.note("hang", "main thread stack:\n" + stack)
                        }
                        continue
                    }
                    if stalled >= stallThreshold, !reportedStallThisHang {
                        reportedStallThisHang = true
                        let note = "main thread stalled past \(Int(stallThreshold * 1000)) ms; last checkpoint '\(lastCheckpoint)'"
                        lock.unlock()
                        AppLog.note("stall", note)
                        // The checkpoint says where the stall started, not
                        // where it is; the stack does (Sept 21, 2026: two
                        // 1 s stalls under 'saveCurrentPage', no stack).
                        if let stack = captureMainThreadStack() {
                            AppLog.note("stall", "main thread stack:\n" + stack)
                        }
                        continue
                    }
                    lock.unlock()
                    continue   // still waiting for the last ping
                }
                pingSent = Date()
                pingCount += 1
                lock.unlock()
                DispatchQueue.main.async {
                    lock.lock()
                    let blocked = pingSent.map { Date().timeIntervalSince($0) } ?? 0
                    let wasHang = reportedThisHang, wasStall = reportedStallThisHang
                    pingSent = nil
                    reportedThisHang = false
                    reportedStallThisHang = false
                    lock.unlock()
                    if wasHang {
                        AppLog.note("hang", "main thread responsive again after \(Int(blocked)) s")
                    } else if wasStall {
                        AppLog.note("stall", "main thread free again after \(Int(blocked * 1000)) ms")
                    }
                }
            }
        }
        thread.name = "MystNotes.MainThreadWatchdog"
        thread.qualityOfService = .utility
        thread.start()
    }

    private static func installIdleObserver() {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) { _, _ in
            let mode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain()).map { $0.rawValue as String } ?? "?"
            let now = Date()
            lock.lock()
            let spun = reportedSpin ? now.timeIntervalSince(lastIdle) : nil
            let heldMode = reportedMode ? idleMode : nil
            lastIdle = now
            reportedSpin = false
            if mode != idleMode { idleMode = mode; idleModeSince = now; reportedMode = false }
            lock.unlock()
            if let spun { AppLog.note("spin", "main run loop idle again after \(Int(spun * 1000)) ms") }
            if let heldMode, heldMode != mode { AppLog.note("mode", "left \(heldMode) for \(mode)") }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    // MARK: Stack capture

    private static func installStackCapture() {
        // A Swift global array is built on first touch, and building it
        // takes the Objective-C runtime's lock. First touched inside the
        // handler, while the interrupted main thread held that lock, it
        // aborted the app (`_os_unfair_lock_recursive_abort`, Oct 4, 2026 -
        // the test host, mid class enumeration). Built here, before any
        // signal can arrive.
        _ = hangStackBuffer.count
        var action = sigaction()
        action.__sigaction_u.__sa_handler = { _ in
            hangStackBuffer.withUnsafeMutableBufferPointer { buffer in
                hangStackCount = backtrace(buffer.baseAddress, Int32(buffer.count))
            }
            hangStackReady = 1
        }
        sigemptyset(&action.sa_mask)
        action.sa_flags = 0
        sigaction(SIGUSR2, &action, nil)
    }

    /// Signals the main thread and waits briefly for the handler to fill
    /// the buffer. Returns symbolicated frames, one per line.
    static func captureMainThreadStack() -> String? {
        guard let mainThread else { return nil }
        hangStackCount = 0
        hangStackReady = 0
        guard pthread_kill(mainThread, SIGUSR2) == 0 else { return nil }
        let deadline = Date().addingTimeInterval(0.5)
        while hangStackReady == 0, Date() < deadline { usleep(5_000) }
        guard hangStackReady != 0, hangStackCount > 0 else { return nil }
        let count = Int(hangStackCount)
        let addresses = Array(hangStackBuffer.prefix(count))
        guard let symbols = backtrace_symbols(addresses, Int32(count)) else { return nil }
        defer { free(symbols) }
        return (0..<count).compactMap { symbols[$0].map { String(cString: $0) } }.joined(separator: "\n")
    }
}

// Signal-handler state: plain globals, no locks, no allocation in the handler.
nonisolated(unsafe) private var hangStackBuffer = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
nonisolated(unsafe) private var hangStackCount: Int32 = 0
nonisolated(unsafe) private var hangStackReady: Int32 = 0


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
        MainThreadWatchdog.start()
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

nonisolated enum DiagnosticsExport {
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
