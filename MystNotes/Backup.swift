import Foundation
import SwiftData

/// Off-device backup: a daily zip of the library, in the sync folder's own
/// layout, into a folder you choose - Dropbox, Google Drive, OneDrive, a
/// USB drive, anything Files can reach.
///
/// The layout is written by the push path (`SyncRunner`, into an empty
/// staging folder), so it is exactly what a sync folder holds: unzip a
/// backup and choose it as the sync folder, and it restores like any other.
/// One file per weekday - "Mystnotes Backup Monday.zip" - so a week of
/// backups sits there and nothing is ever deleted, only replaced a week on.
nonisolated enum Backup {

    // MARK: Writing one

    /// Writes the library, in the sync folder layout, into `folder`.
    static func stage(container: ModelContainer, localFiles: URL, into folder: URL) throws {
        let environment = SyncEnvironment(
            withFolder: { body in
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try body(folder)
            },
            localFilesDirectory: { localFiles },
            state: StagingState(),
            deviceName: "Backup",
            now: { Date() },
            conflictVersions: { _ in [] },
            resolveConflicts: { _ in }
        )
        try SyncRunner(container: container, environment: environment).run(pull: false, push: true)
    }

    /// Stages the library and zips it to `destination`, replacing that
    /// weekday's file from a week ago. Returns the zip.
    @discardableResult
    static func archive(container: ModelContainer, localFiles: URL, to destination: URL,
                        now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("Backup-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        let staging = work.appendingPathComponent("Mystnotes Backup", isDirectory: true)
        try stage(container: container, localFiles: localFiles, into: staging)
        let zipped = work.appendingPathComponent("backup.zip")
        try LibraryExport.zipDirectory(staging, to: zipped)

        let target = destination.appendingPathComponent("Mystnotes Backup \(weekday(of: now)).zip")
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: zipped)
        } else {
            try fm.moveItem(at: zipped, to: target)
        }
        return target
    }

    private static func weekday(of date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }

    /// Push-only bookkeeping for a one-off staging run. Tombstones are the
    /// device's own, so the backup records what was deleted.
    private final class StagingState: SyncStateStore {
        var lastAppliedRemoteSignature: String?
        var lastPushSignature: String = ""
        var tombstonesData: Data? = LiveSyncStateStore.shared.tombstonesData
    }

    // MARK: The destination

    private static let bookmarkKey = "backupFolderBookmark"
    private static let nameKey = "backupFolderName"
    private static let lastRunKey = "backupLastRun"
    private static var defaults: UserDefaults { .standard }

    static var displayName: String? { defaults.string(forKey: nameKey) }
    static var lastRun: Date? { defaults.object(forKey: lastRunKey) as? Date }

    static func setFolder(_ url: URL) throws {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        #if targetEnvironment(macCatalyst)
        let options: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkCreationOptions = []
        #endif
        let bookmark: Data
        if let scoped = try? url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil) {
            bookmark = scoped
        } else {
            bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        defaults.set(bookmark, forKey: bookmarkKey)
        defaults.set(url.lastPathComponent, forKey: nameKey)
    }

    static func clear() {
        defaults.removeObject(forKey: bookmarkKey)
        defaults.removeObject(forKey: nameKey)
    }

    enum BackupError: LocalizedError {
        case notConfigured, unreachable
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "No backup folder has been chosen."
            case .unreachable: return "The backup folder can't be reached. Choose it again."
            }
        }
    }

    /// Backs up now, into the chosen folder.
    static func run(container: ModelContainer) throws {
        guard let bookmark = defaults.data(forKey: bookmarkKey) else { throw BackupError.notConfigured }
        var stale = false
        #if targetEnvironment(macCatalyst)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { throw BackupError.unreachable }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        try archive(container: container, localFiles: FileStore.baseDirectory(), to: url)
        defaults.set(Date(), forKey: lastRunKey)
    }

    /// Two minutes after launch: once a day at most, off the main thread (invariant 10),
    /// and quietly - a backup that can't run says so in Settings and the
    /// log, never in a dialog (invariant 8).
    static func runIfDue(container: ModelContainer) {
        guard defaults.data(forKey: bookmarkKey) != nil else { return }
        if let last = lastRun, Date().timeIntervalSince(last) < 20 * 3600 { return }
        Task.detached(priority: .background) {
            // Not in the launch rush: the first sync run holds the store
            // then, and a launch-time hang was traced to what it holds.
            try? await Task.sleep(for: .seconds(120))
            do {
                try run(container: container)
                AppLog.note("backup", "done")
            } catch {
                AppLog.note("backup", "failed: \(error)")
            }
        }
    }
}
