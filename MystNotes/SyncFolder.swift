import Foundation

/// Persists and resolves the user-chosen sync folder.
///
/// This deliberately does NOT use the app's own iCloud container (that needs
/// a paid-account entitlement). Instead the user points `.fileImporter` at
/// any folder - typically one inside iCloud Drive - and we keep a
/// security-scoped bookmark to it. iCloud Drive then syncs that folder
/// between the user's devices on its own; we just do plain file I/O against
/// whatever the bookmark resolves to.
nonisolated enum SyncFolder {

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
        AppSettings.lastAppliedRemoteSignature = nil
        AppSettings.lastPushSignature = ""
    }

    static func clear() {
        AppSettings.syncFolderBookmark = nil
        AppSettings.syncFolderName = ""
        AppSettings.lastAppliedRemoteSignature = nil
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

    /// Resolves the bookmark and holds security-scoped access open until
    /// the returned `stop` is called. For the folder watcher, which needs
    /// the folder for as long as the app is open; everything else should
    /// use `withFolder`.
    static func openFolder() throws -> (url: URL, stop: @Sendable () -> Void) {
        guard let bookmark = AppSettings.syncFolderBookmark else {
            throw SyncFolderError.notConfigured
        }
        var isStale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: bookmark, options: bookmarkResolutionOptions,
                          relativeTo: nil, bookmarkDataIsStale: &isStale)
        } catch {
            throw SyncFolderError.bookmarkUnresolvable
        }
        guard url.startAccessingSecurityScopedResource() else {
            throw SyncFolderError.accessDenied
        }
        return (url, { @Sendable in url.stopAccessingSecurityScopedResource() })
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

    /// Whether a file in the folder can be read right now.
    enum Availability {
        /// The content is on disk.
        case available
        /// iCloud knows the file but hasn't downloaded it; a download has
        /// been requested. Come back when the folder watcher fires.
        case pending
        /// Nothing by that name, and no placeholder for it.
        case absent
    }

    /// Asks iCloud to materialize `url` if it's evicted, without waiting.
    /// The engine treats `.pending` the way it treats a file that hasn't
    /// arrived yet - it defers what depends on it and the next pull, which
    /// the folder watcher triggers when the download lands, finishes the
    /// job. Nothing here ever sleeps: a pull of two hundred evicted files
    /// used to block for as long as iCloud took to fetch every one.
    static func availability(of url: URL) -> Availability {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
            guard values?.isUbiquitousItem == true,
                  let status = values?.ubiquitousItemDownloadingStatus else {
                return .available   // not an iCloud item: it's just a file
            }
            if status == .current || status == .downloaded { return .available }
            try? fm.startDownloadingUbiquitousItem(at: url)
            return .pending
        }
        // An evicted file in a user-picked iCloud Drive folder shows up as
        // a dotted placeholder next to where the file would be.
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        if fm.fileExists(atPath: placeholder.path) {
            try? fm.startDownloadingUbiquitousItem(at: url)
            return .pending
        }
        return .absent
    }
}
