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
    /// The container's Documents directory — the folder iCloud Drive exposes.
    /// `forUbiquityContainerIdentifier:` returns nil until the container has
    /// actually mounted (asynchronously after launch, and only while the user
    /// is signed into iCloud), so callers must tolerate a local fallback.
    static func baseDirectory() -> URL {
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
    static func url(for filename: String) -> URL {
        baseDirectory().appendingPathComponent(filename)
    }

    /// Copies any payload files that were written to the old local Documents
    /// directory (pre-iCloud builds) up into the iCloud container, so existing
    /// notebooks' drawings/imports follow them to other devices. Idempotent —
    /// safe to call on every launch.
    static func migrateLegacyFilesIfNeeded() {
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