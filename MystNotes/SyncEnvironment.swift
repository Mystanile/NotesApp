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
struct SyncEnvironment {
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

    static var live: SyncEnvironment {
        SyncEnvironment(
            withFolder: { body in try SyncFolder.withFolder(body) },
            localFilesDirectory: { FileStore.localBaseDirectory() },
            state: LiveSyncStateStore.shared,
            deviceName: liveDeviceName,
            now: { Date() }
        )
    }

    private static var liveDeviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "Mac"
        #endif
    }
}

/// Per-device sync bookkeeping. Class-bound so a store can be shared by
/// value (inside `SyncEnvironment`) while its setters still take effect.
protocol SyncStateStore: AnyObject {
    /// `exportedAt` of the last remote snapshot this device applied.
    var lastPulledExportDate: Date? { get set }
    /// `LibrarySnapshot.signature` of the last snapshot this device pushed.
    var lastPushSignature: String { get set }
    /// JSON-encoded `[Tombstone]`, see `SyncTombstones`.
    var tombstonesData: Data? { get set }
}

/// The app's real store: `UserDefaults` through `AppSettings`.
final class LiveSyncStateStore: SyncStateStore {
    static let shared = LiveSyncStateStore()
    private init() {}

    var lastPulledExportDate: Date? {
        get { AppSettings.lastPulledExportDate }
        set { AppSettings.lastPulledExportDate = newValue }
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
