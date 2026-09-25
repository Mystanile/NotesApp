import SwiftUI
import LocalAuthentication

/// Note lock: a locked notebook opens only after Face ID, Touch ID or the
/// device passcode, and stays open until the app goes to the background.
/// Search leaves locked notebooks out unless they're open - its results
/// would show their text.
///
/// A device with no passcode can't authenticate at all, so it can't lock
/// a notebook, and one locked elsewhere stays shut on it. Nobody gets in
/// without authenticating.
@Observable
final class NotebookLock {
    static let shared = NotebookLock()

    private(set) var unlocked: Set<UUID> = []
    /// Replaceable so tests can stand in for Face ID.
    @ObservationIgnored var authenticate: (String) async -> Bool = NotebookLock.deviceOwner
    @ObservationIgnored var canAuthenticate: () -> Bool = NotebookLock.deviceCanAuthenticate

    func isOpen(_ notebook: Notebook) -> Bool {
        notebook.isLocked != true || unlocked.contains(notebook.id)
    }

    /// Asks once; true if the notebook is open now.
    func unlock(_ notebook: Notebook) async -> Bool {
        if isOpen(notebook) { return true }
        guard await authenticate("Unlock “\(notebook.title)”") else { return false }
        unlocked.insert(notebook.id)
        return true
    }

    /// Locking needs a way to unlock again; unlocking for good needs the
    /// same proof opening does. Returns whether the change was made.
    func setLocked(_ locked: Bool, for notebook: Notebook) async -> Bool {
        if locked {
            guard canAuthenticate() else { return false }
            notebook.isLocked = true
            unlocked.remove(notebook.id)
        } else {
            guard await unlock(notebook) else { return false }
            notebook.isLocked = false
        }
        // A setting: the settings clock, not `modifiedAt` (see the star).
        notebook.settingsModifiedAt = Date()
        return true
    }

    func relockAll() {
        if !unlocked.isEmpty { unlocked = [] }
    }

    nonisolated static func deviceCanAuthenticate() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    nonisolated static func deviceOwner(_ reason: String) async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

/// Stands in front of a notebook: the notebook itself once it's open,
/// otherwise a lock screen that asks straight away.
struct LockedNotebookGate<Content: View>: View {
    let notebook: Notebook
    @ViewBuilder var content: () -> Content

    @State private var lock = NotebookLock.shared
    @State private var failed = false

    var body: some View {
        if lock.isOpen(notebook) {
            content()
        } else {
            ContentUnavailableView {
                Label("\(notebook.title) is locked", systemImage: "lock.fill")
            } description: {
                Text(lock.canAuthenticate()
                     ? (failed ? "Couldn't unlock it." : "Unlock it with Face ID, Touch ID or your passcode.")
                     : "Set a passcode on this device to open locked notebooks.")
            } actions: {
                if lock.canAuthenticate() {
                    Button("Unlock") { Task { failed = !(await lock.unlock(notebook)) } }
                        .buttonStyle(.borderedProminent)
                }
            }
            .task { failed = !(await lock.unlock(notebook)) }
        }
    }
}
