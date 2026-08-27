import Foundation

/// Central store for the app's on-disk payload files (PKDrawing data, imported
/// PDFs/images). These live OUTSIDE SwiftData — the models only hold a file
/// reference (e.g. `<uuid>.drawing`) — so for a notebook's drawing to appear
/// on another device, the files themselves have to reach that device.
///
/// This store writes into the iCloud Documents (ubiquity) container, whose
/// Documents folder iCloud Drive syncs across devices signed into the same
/// Apple ID. When iCloud isn't available or the container hasn't mounted yet,
/// it falls back to the local sandbox; `migrateLegacyFilesIfNeeded()` catches
/// up any files written before iCloud was in play.
enum FileStore {
    /// `url(forUbiquityContainerIdentifier:)` is documented to be slow (it can
    /// touch disk/do container setup work), so its result is cached rather
    /// than re-resolved on every call — this is invoked on essentially every
    /// autosave tick, page load, and thumbnail render, so re-resolving it
    /// every time was a steady source of main-thread stutter. The cache is
    /// invalidated on `NSUbiquityIdentityDidChange` (see `MystnotesApp`),
    /// the only time the answer can actually change.
    private static var cachedBaseDirectory: URL?

    /// The container's Documents directory — the folder iCloud Drive exposes.
    /// `forUbiquityContainerIdentifier:` returns nil until the container has
    /// actually mounted (asynchronously after launch, and only while the user
    /// is signed into iCloud), so callers must tolerate a local fallback.
    static func baseDirectory() -> URL {
        // Unlike SwiftData's CloudKit setting (fixed for the process's
        // lifetime once the ModelContainer is built), file storage checks
        // this on every call — so choosing "don't sync" is honored for
        // drawings/imports immediately, no relaunch needed.
        guard AppSettings.syncEnabled else {
            return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        }
        if let cached = cachedBaseDirectory { return cached }
        let resolved = resolveBaseDirectory()
        cachedBaseDirectory = resolved
        return resolved
    }

    /// Drops the cached directory so the next `baseDirectory()` call
    /// re-resolves it. Call this when the iCloud identity changes, since
    /// that's the only thing that can change the answer.
    static func invalidateCachedBaseDirectory() {
        cachedBaseDirectory = nil
        cachedResolvedDirectory = nil
    }

    /// Memoized separately from `cachedBaseDirectory` because the fallback
    /// in `url(for:)` needs the resolved iCloud location even when sync is
    /// switched off. `url(forUbiquityContainerIdentifier:)` blocks, so it
    /// must not be re-run on every file lookup.
    private static var cachedResolvedDirectory: URL?

    private static func resolveBaseDirectory() -> URL {
        if let cached = cachedResolvedDirectory { return cached }
        let resolved = computeBaseDirectory()
        cachedResolvedDirectory = resolved
        return resolved
    }

    private static func computeBaseDirectory() -> URL {
        if let container = FileManager.default
            .url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents", isDirectory: true) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: container.path, isDirectory: &isDir),
               isDir.boolValue {
                return container
            }
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// The on-disk URL for a payload file referenced by name.
    ///
    /// If the file isn't in the current base directory but does exist in the
    /// other one, that location is returned instead. Without this, turning
    /// the iCloud sync toggle off swings `baseDirectory()` over to local
    /// storage and every drawing and imported image written while sync was
    /// on becomes invisible - pages render blank, which reads as total data
    /// loss even though nothing was actually deleted. Falling back also
    /// means saving an existing file keeps updating it where it already
    /// lives, rather than silently forking a second copy; genuinely new
    /// files exist in neither place and so still land in the current base.
    static func url(for filename: String) -> URL {
        let primary = baseDirectory().appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: primary.path) { return primary }

        let local = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // resolveBaseDirectory() is memoized, so this doesn't repeat the
        // blocking iCloud container lookup on every file access.
        let alternate = (primary.deletingLastPathComponent() == local)
            ? resolveBaseDirectory().appendingPathComponent(filename)
            : local.appendingPathComponent(filename)
        if alternate != primary, FileManager.default.fileExists(atPath: alternate.path) {
            return alternate
        }
        return primary
    }

    /// Copies any payload files that were written to the old local Documents
    /// directory (pre-iCloud builds) up into the iCloud container, so existing
    /// notebooks' drawings/imports follow them to other devices. Idempotent —
    /// safe to call on every launch.
    static func migrateLegacyFilesIfNeeded() {
        guard AppSettings.syncEnabled else { return }
        let local = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let cloud = baseDirectory()
        guard local != cloud else { return }

        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: local, includingPropertiesForKeys: nil)
        else { return }

        for item in items {
            let ext = item.pathExtension.lowercased()
            guard ["drawing", "pdf", "jpg"].contains(ext) else { continue }
            let dest = cloud.appendingPathComponent(item.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) {
                try? fm.copyItem(at: item, to: dest)
            }
        }
    }
}