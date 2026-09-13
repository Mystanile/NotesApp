import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Everything `SyncRunner` touches that is process-wide in the app: the
/// chosen sync folder, the local payload directory, the per-device sync
/// bookkeeping, the device name and the clock.
///
/// The app uses `.live`, which forwards to exactly the globals the runner
/// used to reach directly (`SyncFolder`, `FileStore`, `AppSettings`,
/// `Date()`). Tests build one environment per simulated device so two
/// libraries can share one sync folder inside a single process - the
/// only way to drive a real two-device merge from a unit test.
nonisolated struct SyncEnvironment {
    /// Resolves the user's sync folder and runs `body` with access held.
    var withFolder: (_ body: (URL) throws -> Void) throws -> Void
    /// Where this device keeps its payload files (`<page-id>.drawing`,
    /// imported PDFs/images).
    var localFilesDirectory: () -> URL
    /// This device's "what have I already pulled / pushed" markers and
    /// its tombstone list.
    var state: SyncStateStore
    var deviceName: String
    var now: () -> Date
    /// How many past copies of `index.json` to keep in `index-history/`.
    var indexHistoryLimit: Int = 50
    /// A payload in the folder that nothing references is left alone
    /// this long before it's moved to `trash/` - a notebook file that
    /// hasn't arrived yet may still be about to reference it.
    var orphanGracePeriod: TimeInterval = 7 * 24 * 60 * 60
    /// True for the local mirror: the "folder" is on this device, the
    /// payloads it references are the local files themselves (nothing is
    /// copied in or out), and nothing else writes it (no pull before push).
    var payloadsAreLocal: Bool = false
    /// Other versions of a file that iCloud kept because two devices wrote
    /// it while offline (`NSFileVersion` unresolved conflicts). Each is
    /// merged like any other remote snapshot, then marked resolved.
    var conflictVersions: (URL) -> [URL] = { url in
        (NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).map(\.url)
    }
    var resolveConflicts: (URL) -> Void = { url in
        for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] {
            version.isResolved = true
        }
    }

    static var live: SyncEnvironment {
        SyncEnvironment(
            withFolder: { body in try SyncFolder.withFolder(body) },
            localFilesDirectory: { FileStore.baseDirectory() },
            state: LiveSyncStateStore.shared,
            deviceName: liveDeviceName,
            now: { Date() }
        )
    }

    /// `Documents/Library/`: a copy of the folder layout, metadata only,
    /// kept on this device so the index can be rebuilt even when no sync
    /// folder was ever chosen (invariant 4). Written by the same debounced
    /// push as the sync folder.
    static var mirror: SyncEnvironment {
        let directory = mirrorDirectory
        return SyncEnvironment(
            withFolder: { body in
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try body(directory)
            },
            localFilesDirectory: { FileStore.baseDirectory() },
            state: MirrorSyncStateStore.shared,
            deviceName: liveDeviceName,
            now: { Date() },
            indexHistoryLimit: 20,
            payloadsAreLocal: true,
            conflictVersions: { _ in [] },
            resolveConflicts: { _ in }
        )
    }

    static var mirrorDirectory: URL {
        FileStore.baseDirectory().appendingPathComponent("Library", isDirectory: true)
    }

    /// Platform plus a stable per-install id - "Mac-3F2A", "iPad-9C1B".
    /// `UIDevice.current.name` answers "iPad" on both iPad and Mac
    /// Catalyst (the real name is behind an entitlement), which made every
    /// index-history entry from either device indistinguishable.
    private static var liveDeviceName: String {
        #if targetEnvironment(macCatalyst)
        let platform = "Mac"
        #elseif canImport(UIKit)
        let platform = UIDevice.current.model.replacingOccurrences(of: " ", with: "")
        #else
        let platform = "Mac"
        #endif
        return "\(platform)-\(AppSettings.installID.prefix(4))"
    }
}

/// Per-device sync bookkeeping. Class-bound so a store can be shared by
/// value (inside `SyncEnvironment`) while its setters still take effect.
nonisolated protocol SyncStateStore: AnyObject {
    /// Signature of the last remote snapshot this device fully applied, or
    /// authored. A pull whose remote signature equals it has nothing new.
    /// Content, not time: two devices pushing every 30 s can each write an
    /// index the other would have skipped as "older than my last push".
    var lastAppliedRemoteSignature: String? { get set }
    /// `LibrarySnapshot.signature` of the last snapshot this device pushed.
    var lastPushSignature: String { get set }
    /// JSON-encoded `[Tombstone]`, see `SyncTombstones`.
    var tombstonesData: Data? { get set }
}

/// The local mirror's markers. Tombstones are shared with the live store:
/// a deletion recorded on this device must apply when the mirror is read
/// back, or a rebuild would resurrect it.
nonisolated final class MirrorSyncStateStore: SyncStateStore {
    static let shared = MirrorSyncStateStore()
    private init() {}
    private let defaults = UserDefaults.standard

    var lastAppliedRemoteSignature: String? {
        get { defaults.string(forKey: "mirror.lastAppliedRemoteSignature") }
        set { defaults.set(newValue, forKey: "mirror.lastAppliedRemoteSignature") }
    }
    var lastPushSignature: String {
        get { defaults.string(forKey: "mirror.lastPushSignature") ?? "" }
        set { defaults.set(newValue, forKey: "mirror.lastPushSignature") }
    }
    var tombstonesData: Data? {
        get { AppSettings.syncTombstonesData }
        set { AppSettings.syncTombstonesData = newValue }
    }
}

/// The app's real store: `UserDefaults` through `AppSettings`.
nonisolated final class LiveSyncStateStore: SyncStateStore {
    static let shared = LiveSyncStateStore()
    private init() {}

    var lastAppliedRemoteSignature: String? {
        get { AppSettings.lastAppliedRemoteSignature }
        set { AppSettings.lastAppliedRemoteSignature = newValue }
    }
    var lastPushSignature: String {
        get { AppSettings.lastPushSignature }
        set { AppSettings.lastPushSignature = newValue }
    }
    var tombstonesData: Data? {
        get { AppSettings.syncTombstonesData }
        set { AppSettings.syncTombstonesData = newValue }
    }
}
