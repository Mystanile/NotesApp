import Foundation

/// Where the app's payload files live: `PKDrawing` data, imported PDFs and
/// images. These sit OUTSIDE SwiftData - the models only hold a file name
/// like `<uuid>.drawing` - in the app's own Documents directory. Getting
/// them to another device is `SyncEngine`'s job, through the user-chosen
/// sync folder.
///
/// One storage root (invariant 7). Earlier builds also wrote into the
/// iCloud ubiquity container, and switched between the two locations on a
/// preference, which is how "every drawing disappeared" shipped once. That
/// path is gone; `adoptLegacyCloudFilesOnce` brings anything left there
/// home, one time, and nothing looks there again.
enum FileStore {
    /// The one place payload files live.
    static func baseDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// The on-disk URL for a payload file referenced by name.
    static func url(for filename: String) -> URL {
        baseDirectory().appendingPathComponent(filename)
    }

    // MARK: Legacy iCloud container

    private static let adoptedLegacyCloudFilesKey = "didAdoptLegacyCloudFiles"

    /// If a previous build ever managed to write payloads into the iCloud
    /// ubiquity container, copy them into `baseDirectory()` - once, ever -
    /// so they aren't stranded now that nothing reads that container.
    /// `url(forUbiquityContainerIdentifier:)` blocks, so this runs off the
    /// main thread and never again after the first successful pass.
    static func adoptLegacyCloudFilesOnce() {
        guard !UserDefaults.standard.bool(forKey: adoptedLegacyCloudFilesKey) else { return }
        let destination = baseDirectory()
        Task.detached(priority: .utility) {
            if let container = FileManager.default.url(forUbiquityContainerIdentifier: nil)?
                .appendingPathComponent("Documents", isDirectory: true) {
                adoptFiles(from: container, into: destination)
            }
            UserDefaults.standard.set(true, forKey: adoptedLegacyCloudFilesKey)
        }
    }

    /// Copies payload files (`.drawing`, `.pdf`, `.jpg`) from `source` into
    /// `destination` when `destination` doesn't already have a file of that
    /// name. Never overwrites - a local file is the one the app has been
    /// using - and never removes anything from `source`.
    static func adoptFiles(from source: URL, into destination: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else { return }
        for item in items where ["drawing", "pdf", "jpg"].contains(item.pathExtension.lowercased()) {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            guard !fm.fileExists(atPath: target.path) else { continue }
            try? fm.copyItem(at: item, to: target)
        }
    }
}
