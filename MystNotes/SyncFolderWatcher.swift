import Foundation

/// Tells `SyncEngine` when something in the sync folder changes while the
/// app is open, so edits from another device land without waiting for the
/// next foreground or "Sync Now". On a Mac that stays open for days this
/// is the common case.
///
/// An `NSFilePresenter` on the `Mystnotes/` working directory. Verified on
/// Sept 12, 2026 (see the task-13 note in `SyncEngine`): for a folder
/// inside iCloud Drive it fires for writes from other processes,
/// coordinated or not, at any depth, within about a second - and several
/// times per write, hence the coalescing window.
nonisolated final class SyncFolderWatcher: @unchecked Sendable {
    /// How long to wait after the last event before reacting. A single
    /// iCloud delivery is a burst: the index, a few notebook files, some
    /// payloads, each announced more than once.
    nonisolated static let coalescingInterval: TimeInterval = 2

    private let presenter: Presenter
    private let debouncer: SyncDebouncer
    private let stopAccess: @Sendable () -> Void

    /// Starts watching `url`. `stopAccess` is called on `stop()` so a
    /// security-scoped folder can be held open for the watcher's lifetime.
    /// May be called from any thread; the debouncer it drives lives on
    /// the main actor and is only ever touched there.
    init(url: URL, coalescingInterval: TimeInterval = SyncFolderWatcher.coalescingInterval,
         stopAccess: @escaping @Sendable () -> Void = {}, onChange: @escaping @MainActor () -> Void) {
        self.stopAccess = stopAccess
        let debouncer = SyncDebouncer(interval: coalescingInterval, action: onChange)
        self.debouncer = debouncer
        presenter = Presenter(url: url)
        presenter.onEvent = {
            Task { @MainActor in
                MainThreadWatchdog.checkpoint("SyncFolderWatcher.event")
                debouncer.noteChange()
            }
        }
        NSFileCoordinator.addFilePresenter(presenter)
    }

    /// May be called from any thread. `removeFilePresenter` waits for
    /// in-flight coordination to finish, so callers on the main thread
    /// should hop off first.
    func stop() {
        NSFileCoordinator.removeFilePresenter(presenter)
        let debouncer = self.debouncer
        Task { @MainActor in debouncer.cancel() }
        stopAccess()
    }

    /// The `NSFilePresenter` itself. Kept separate from the watcher so the
    /// callbacks - which arrive on `presentedItemOperationQueue` - never
    /// touch main-actor state directly.
    private final class Presenter: NSObject, NSFilePresenter {
        let presentedItemURL: URL?
        let presentedItemOperationQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.name = "MystNotes.SyncFolderWatcher"
            queue.maxConcurrentOperationCount = 1
            return queue
        }()
        nonisolated(unsafe) var onEvent: () -> Void = {}

        init(url: URL) {
            presentedItemURL = url
        }

        func presentedItemDidChange() { onEvent() }
        func presentedSubitemDidChange(at url: URL) { onEvent() }
        func presentedSubitemDidAppear(at url: URL) { onEvent() }
        func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { onEvent() }
    }
}
