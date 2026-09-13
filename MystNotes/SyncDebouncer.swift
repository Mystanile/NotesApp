import Foundation

/// Turns a stream of "something changed" into one action a fixed interval
/// after the last change. `SyncEngine` uses it to push about 30 seconds
/// after the user stops editing, so a session that never backgrounds -
/// or crashes before it does - still reaches the folder.
///
/// Every change restarts the wait; `flush()` runs the action now and
/// cancels the wait; `cancel()` drops it.
@MainActor
final class SyncDebouncer {
    let interval: TimeInterval
    private let action: @MainActor () -> Void
    private var pending: Task<Void, Never>?

    nonisolated init(interval: TimeInterval, action: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.action = action
    }

    /// True while a change is waiting to be acted on.
    var isPending: Bool { pending != nil }

    func noteChange() {
        pending?.cancel()
        pending = Task { [interval] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.pending = nil
            self.action()
        }
    }

    func flush() {
        let hadPending = pending != nil
        pending?.cancel()
        pending = nil
        if hadPending { action() }
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}
