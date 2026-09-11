import Foundation

/// Persists and resolves the user-chosen sync folder.
///
/// This deliberately does NOT use the app's own iCloud container (that needs
/// a paid-account entitlement). Instead the user points `.fileImporter` at
/// any folder - typically one inside iCloud Drive - and we keep a
/// security-scoped bookmark to it. iCloud Drive then syncs that folder
/// between the user's devices on its own; we just do plain file I/O against
/// whatever the bookmark resolves to.
enum SyncFolder {

    enum SyncFolderError: LocalizedError {
        case notConfigured
        case bookmarkUnresolvable
        case accessDenied

        var errorDescription: String? {
            switch self {
            case .notConfigured:      return "No sync folder has been chosen yet."
            case .bookmarkUnresolvable: return "The sync folder can't be found any more. Choose it again."
            case .accessDenied:       return "Mystnotes was denied access to the sync folder."
            }
        }
    }

    #if targetEnvironment(macCatalyst)
    private static let bookmarkCreationOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    private static let bookmarkCreationOptions: URL.BookmarkCreationOptions = []
    private static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = []
    #endif

    static var isConfigured: Bool { AppSettings.syncFolderBookmark != nil }

    /// Human-readable name of the chosen folder, for Settings.
    static var displayName: String? { AppSettings.syncFolderName.isEmpty ? nil : AppSettings.syncFolderName }

    /// Stores a bookmark to `url` (the security-scoped URL handed back by the
    /// folder picker). The caller is responsible for having started/stopped
    /// security-scoped access around the pick if needed.
    static func setFolder(_ url: URL) throws {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        // Prefer a security-scoped bookmark (required to keep access across
        // launches inside the Mac Catalyst sandbox); fall back to a plain
        // bookmark if the sandbox won't grant the scoped one.
        let bookmark: Data
        do {
            bookmark = try url.bookmarkData(options: bookmarkCreationOptions,
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
        } catch {
            bookmark = try url.bookmarkData(options: [],
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
        }

        // Confirm it actually resolves and is a reachable directory before
        // committing - a bookmark we can't use later is worse than none.
        var isStale = false
        let resolved = try URL(resolvingBookmarkData: bookmark,
                               options: bookmarkResolutionOptions,
                               relativeTo: nil,
                               bookmarkDataIsStale: &isStale)
        let scoped = resolved.startAccessingSecurityScopedResource()
        defer { if scoped { resolved.stopAccessingSecurityScopedResource() } }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue else {
            throw SyncFolderError.bookmarkUnresolvable
        }

        AppSettings.syncFolderBookmark = bookmark
        AppSettings.syncFolderName = url.lastPathComponent
        // A fresh folder choice invalidates the "already pulled / pushed"
        // markers - the new location's state is unknown.
        AppSettings.lastPulledExportDate = nil
        AppSettings.lastPushSignature = ""
    }

    static func clear() {
        AppSettings.syncFolderBookmark = nil
        AppSettings.syncFolderName = ""
        AppSettings.lastPulledExportDate = nil
        AppSettings.lastPushSignature = ""
    }

    /// Resolves the bookmark and runs `body` with security-scoped access held
    /// for the duration. Refreshes the stored bookmark if the system reports
    /// it stale.
    static func withFolder<T>(_ body: (URL) throws -> T) throws -> T {
        guard let bookmark = AppSettings.syncFolderBookmark else {
            throw SyncFolderError.notConfigured
        }

        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: bookmark,
                options: bookmarkResolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw SyncFolderError.bookmarkUnresolvable
        }

        guard url.startAccessingSecurityScopedResource() else {
            throw SyncFolderError.accessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }

        if isStale,
           let refreshed = try? url.bookmarkData(options: bookmarkCreationOptions,
                                                 includingResourceValuesForKeys: nil,
                                                 relativeTo: nil) {
            AppSettings.syncFolderBookmark = refreshed
        }

        return try body(url)
    }

    /// The `Mystnotes/` working directory inside the chosen folder, created if
    /// needed. `files/` beneath it holds the payload copies.
    static func workingDirectory(in folder: URL) throws -> URL {
        let dir = folder.appendingPathComponent("Mystnotes", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = dir.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        return dir
    }

    /// Best-effort: ask iCloud to materialize a placeholder file and wait
    /// briefly for it. A no-op (throws, ignored) for a plain non-iCloud
    /// folder, where the file is already local.
    static func ensureDownloaded(_ url: URL, timeout: TimeInterval = 15) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) || (try? url.checkResourceIsReachable()) == true else {
            // Might be an `.icloud` placeholder with a dotted name; still try.
            try? fm.startDownloadingUbiquitousItem(at: url)
            return
        }
        try? fm.startDownloadingUbiquitousItem(at: url)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if let status = values?.ubiquitousItemDownloadingStatus {
                if status == .current || status == .downloaded { return }
            } else {
                // Not an iCloud item - nothing to wait for.
                return
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
    }
}
