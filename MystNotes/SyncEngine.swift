import Foundation
import Combine
import SwiftData

/// Folder-based library sync - the free-account alternative to CloudKit.
///
/// The library is written to `<sync folder>/Mystnotes/` as `index.json`
/// plus one `notebooks/<uuid>.json` per notebook (see `SyncModels`), and
/// every payload file (drawings, imported PDFs/images) is copied into
/// `files/`. iCloud Drive (or whatever service backs the chosen folder)
/// moves those between devices; this engine only reads and writes local
/// files.
///
/// Merge is per page, last-writer-wins on `Page.modifiedAt`, so two devices
/// that edit different pages of the same notebook while offline both keep
/// their edits. When both edit the *same* page the newer one shows and the
/// other device's ink goes to its `trash/`, never discarded. Notebook
/// settings (title, cover, folder) are last-writer-wins on
/// `Notebook.settingsModifiedAt`; folders are a flat upsert; deletions
/// travel as `Tombstone`s.
///
/// Triggers: pull when the app becomes active and push when it goes to the
/// background (wired in `ContentView`), a manual "Sync Now" in Settings,
/// a push about `debounceInterval` after the last save on the app's main
/// `ModelContext` - so a long session, or one that crashes before it
/// backgrounds, still reaches the folder - and a pull whenever
/// `SyncFolderWatcher` sees the folder change underneath the open app.
@MainActor
final class SyncEngine: ObservableObject {
    static let shared = SyncEngine()
    private init() {}

    /// How long after the last edit the automatic push goes out.
    static let debounceInterval: TimeInterval = 30

    enum Status: Equatable {
        case idle
        case syncing
        case succeeded(Date)
        /// Not an error: iCloud hasn't delivered something yet. The folder
        /// watcher will trigger the next attempt.
        case waiting(String)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle

    private var container: ModelContainer?
    private var isRunning = false
    private var currentRunID: UUID?
    /// How long a single sync run may take before the engine stops waiting
    /// for it. Generous: a first pull of a large library is legitimately slow.
    static let runWatchdogInterval: TimeInterval = 120
    /// A change arrived while a sync was running: run again when it ends.
    private var pushAgainWhenDone = false
    private var saveObserver: NSObjectProtocol?
    private var watcher: SyncFolderWatcher?
    private var isStartingWatcher = false
    private lazy var debouncer = SyncDebouncer(interval: Self.debounceInterval) { [weak self] in
        self?.pushAfterEdits()
    }

    func configure(container: ModelContainer) {
        guard self.container == nil else { return }
        self.container = container
        startWatchingFolder()

        // Every user edit ends in a save on the main context (the views'
        // @Environment(\.modelContext)). The runner saves on a context of
        // its own, so a pull never schedules a push of itself.
        let mainContext = container.mainContext
        saveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: mainContext, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteLocalChange() }
        }
    }

    /// Something in the library changed on this device. Called for every
    /// main-context save. The mirror is written whether or not a sync
    /// folder is chosen.
    func noteLocalChange() {
        debouncer.noteChange()
    }

    private func pushAfterEdits() {
        writeMirror()
        guard SyncFolder.isConfigured else { return }
        start(pull: false, push: true)
    }

    /// Writes `Documents/Library/` - the local, metadata-only copy of the
    /// folder layout that a rebuild can use when no sync folder exists.
    /// Cheap, off main, and never contends with a folder sync: it has its
    /// own environment and state.
    private func writeMirror() {
        MainThreadWatchdog.checkpoint("SyncEngine.writeMirror")
        guard let container else { return }
        let work = Self.runDetached(container: container, environment: SyncEnvironment.mirror, pull: false, push: true)
        Task { @MainActor in
            if case .failure(let error) = await work.value { AppLog.note("mirror", "write failed: \(error)") }
        }
    }

    /// Records the user's chosen folder and kicks off the first sync. Any
    /// failure (typically the Mac sandbox refusing a persistent bookmark)
    /// lands in `status` so the Settings screen can show it.
    func chooseFolder(_ url: URL) {
        status = .syncing
        // Creating and test-resolving a security-scoped bookmark to an
        // iCloud folder goes through the file provider; not on main.
        let work = Self.detached(priority: .userInitiated) { try SyncFolder.setFolder(url) }
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch await work.value {
            case .success:
                self.objectWillChange.send()
                self.startWatchingFolder()
                self.syncNow()
            case .failure(let error):
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    /// "Turn Off Folder Sync" in Settings.
    func clearFolder() {
        stopWatchingFolder()
        debouncer.cancel()
        SyncFolder.clear()
        objectWillChange.send()
        status = .idle
    }

    /// Settings → "Rebuild Index". From the sync folder when one is chosen,
    /// otherwise from the local mirror. See `LibraryRebuild`.
    func rebuildIndex() {
        guard let container, !isRunning else { return }
        isRunning = true
        status = .syncing
        debouncer.cancel()
        let environment = SyncFolder.isConfigured ? SyncEnvironment.live : SyncEnvironment.mirror
        let work = Self.detached(priority: .userInitiated) {
            try LibraryRebuild.rebuild(container: container, environment: environment)
        }
        Task { @MainActor [weak self] in
            let outcome = await work.value
            guard let self else { return }
            self.isRunning = false
            switch outcome {
                case .success:
                    self.status = .succeeded(Date())
                    AppLog.note("rebuild", "index rebuilt from the folder")
                case .failure(let error as SyncRunner.Waiting):
                    self.status = .waiting(error.localizedDescription)
                case .failure(let error):
                    self.status = .failed(error.localizedDescription)
                    AppLog.note("rebuild", "failed: \(error)")
            }
        }
    }

    /// The only way a runner is started. Deliberately a nonisolated static
    /// whose detached closure captures nothing main-actor: under this
    /// module's default MainActor isolation, a closure that so much as
    /// references `self` is inferred main-actor and `Task.detached` runs
    /// it on the main thread - which is how the engine ended up there
    /// twice today (iPad watchdog log). The caller awaits the task from
    /// the main actor and touches state after.
    nonisolated static func runDetached(container: ModelContainer, environment: SyncEnvironment,
                                        pull: Bool, push: Bool) -> Task<Result<Void, Error>, Never> {
        detached(priority: .utility) {
            try SyncRunner(container: container, environment: environment).run(pull: pull, push: push)
        }
    }

    /// Runs `body` on a background thread, whatever context this is called
    /// from. Nonisolated, static, and capture-free by construction.
    nonisolated static func detached(priority: TaskPriority,
                                     _ body: @escaping @Sendable () throws -> Void) -> Task<Result<Void, Error>, Never> {
        Task.detached(priority: priority) {
            do { try body(); return .success(()) } catch { return .failure(error) }
        }
    }

    // MARK: Watching the folder

    /// Changes another device's sync lands in the folder while the app is
    /// open are pulled a couple of seconds after the last one arrives. Our
    /// own pushes trigger this too; that pull finds nothing newer than what
    /// it just wrote and stops at the index.
    ///
    /// Resolving the bookmark, creating the working directory and
    /// registering the presenter all talk to the iCloud file provider,
    /// which on the iPad took six seconds at launch (the in-app watchdog
    /// logged it). None of it happens on the main thread.
    private func startWatchingFolder() {
        MainThreadWatchdog.checkpoint("SyncEngine.startWatchingFolder")
        guard watcher == nil, !isStartingWatcher, SyncFolder.isConfigured else { return }
        isStartingWatcher = true
        let onChange: @MainActor @Sendable () -> Void = { [weak self] in self?.folderDidChange() }
        let work = Self.makeWatcher(onChange: onChange)
        Task { @MainActor [weak self] in
            let watcher = await work.value
            guard let self else { watcher?.stop(); return }
            self.isStartingWatcher = false
            guard let watcher, self.watcher == nil, SyncFolder.isConfigured else { watcher?.stop(); return }
            self.watcher = watcher
        }
    }

    /// Capture-free, like `runDetached`: the closure knows only the
    /// `onChange` value it is given.
    nonisolated static func makeWatcher(onChange: @escaping @MainActor @Sendable () -> Void) -> Task<SyncFolderWatcher?, Never> {
        Task.detached(priority: .utility) {
            guard let folder = try? SyncFolder.openFolder(),
                  let workingDir = try? SyncFolder.workingDirectory(in: folder.url) else { return nil }
            return SyncFolderWatcher(url: workingDir, stopAccess: folder.stop, onChange: onChange)
        }
    }

    private func stopWatchingFolder() {
        MainThreadWatchdog.checkpoint("SyncEngine.stopWatchingFolder")
        guard let watcher else { return }
        self.watcher = nil
        // removeFilePresenter waits for in-flight coordination; not on main.
        Task.detached(priority: .utility) { watcher.stop() }
    }

    private func folderDidChange() {
        MainThreadWatchdog.checkpoint("SyncEngine.folderDidChange")
        guard SyncFolder.isConfigured, !isRunning else { return }
        start(pull: true, push: false)
    }

    func syncNow() { start(pull: true, push: true) }

    func pullOnForeground() {
        guard SyncFolder.isConfigured else { return }
        start(pull: true, push: false)
    }

    /// Backgrounding doesn't wait for the debounce.
    func pushOnBackground() {
        debouncer.cancel()
        writeMirror()
        guard SyncFolder.isConfigured else { return }
        start(pull: false, push: true)
    }

    private func start(pull: Bool, push: Bool) {
        MainThreadWatchdog.checkpoint("SyncEngine.start pull=\(pull) push=\(push)")
        guard let container else { return }
        guard SyncFolder.isConfigured else {
            status = .failed(SyncFolder.SyncFolderError.notConfigured.localizedDescription)
            return
        }
        guard !isRunning else {
            // Don't lose the request: whatever changed will be in the
            // snapshot the follow-up run builds.
            if push { pushAgainWhenDone = true }
            return
        }
        isRunning = true
        status = .syncing

        let environment = SyncEnvironment.live
        let runID = UUID()
        currentRunID = runID
        // A coordinated read or write on an iCloud file can block for as
        // long as the file provider takes - which, the moment a device
        // goes offline, can be indefinitely. That run can't be cancelled,
        // but it must not hold every later sync hostage: after the
        // watchdog interval the engine stops waiting for it. If it ever
        // finishes it is discarded (its outcome no longer matches
        // currentRunID). Seen on the iPad on entering Airplane Mode.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.runWatchdogInterval * 1_000_000_000))
            guard let self, self.isRunning, self.currentRunID == runID else { return }
            AppLog.note("sync", "run did not finish within \(Int(Self.runWatchdogInterval)) s; no longer waiting for it")
            self.isRunning = false
            self.currentRunID = nil
            self.status = .waiting("Sync is taking longer than expected. It will retry.")
        }
        let work = Self.runDetached(container: container, environment: environment, pull: pull, push: push)
        Task { @MainActor [weak self] in
            let outcome = await work.value
            guard let self, self.currentRunID == runID else { return }   // the watchdog gave up on this run
            self.currentRunID = nil
            self.isRunning = false
            switch outcome {
            case .success:
                self.status = .succeeded(Date())
            case .failure(let error as SyncRunner.Waiting):
                self.status = .waiting(error.localizedDescription)
                AppLog.note("sync", "waiting (pull=\(pull) push=\(push)): \(error.localizedDescription)")
            case .failure(let error):
                self.status = .failed(error.localizedDescription)
                AppLog.note("sync", "failed (pull=\(pull) push=\(push)): \(error)")
            }
            if self.pushAgainWhenDone {
                self.pushAgainWhenDone = false
                self.start(pull: false, push: true)
            }
        }
    }
}

// MARK: - Runner (off the main actor)

/// Does the actual work on a background task with its own `ModelContext`.
/// Saving here propagates to the app's `@Query`-backed views through the
/// shared `ModelContainer`.
///
/// Every process-wide dependency (sync folder, local files directory, the
/// pulled/pushed markers, tombstones, clock) comes through `environment` so
/// the sync tests can run two independent libraries against one folder.
nonisolated struct SyncRunner {
    let container: ModelContainer
    let environment: SyncEnvironment

    private var jsonEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = SnapshotDates.encoding
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
    private var jsonDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = SnapshotDates.decoding
        return decoder
    }

    func run(pull: Bool, push: Bool) throws {
        let context = ModelContext(container)
        let started = Date()
        var phases: [String] = []
        func mark(_ name: String, since: Date) { phases.append("\(name) \(String(format: "%.2f", Date().timeIntervalSince(since)))s") }
        defer {
            if !environment.payloadsAreLocal {
                AppLog.note("sync", "run pull=\(pull) push=\(push) on \(Thread.isMainThread ? "MAIN" : "bg") thread: \(phases.joined(separator: ", ")) total \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            }
        }
        try environment.withFolder { folder in
            let t0 = Date()
            let workingDir = try SyncFolder.workingDirectory(in: folder)
            mark("open", since: t0)
            // A push always pulls first: it folds in whatever another device
            // wrote so what we're about to write isn't stale.
            let hashes = PayloadHashCache(directory: environment.localFilesDirectory())
            defer { hashes.persist() }
            // A push always pulls first, folding in what another device
            // wrote - except into the mirror, which only this device writes.
            // The folder's current index first, then any conflict versions
            // iCloud kept - each applied as its own snapshot so every page
            // is compared against what's local *now*, not what was local
            // before the previous version was merged.
            let t1 = Date()
            let versions = try readRemoteVersions(workingDir: workingDir, context: context)
            mark("read \(versions.count) version(s)", since: t1)
            let remote = versions.first
            var pending = remote?.pending ?? []
            if pull || (push && !environment.payloadsAreLocal) {
                let t2 = Date()
                defer { mark("pull", since: t2) }
                var allComplete = true
                for version in versions {
                    let deferred = try performPull(version, context: context, workingDir: workingDir, hashes: hashes)
                    pending.formUnion(deferred)
                    if !version.isComplete || !deferred.isEmpty { allComplete = false }
                }
                if versions.count > 1, allComplete {
                    // Everything every version said is in the library; the
                    // conflict has been reconciled, and the next push writes
                    // the union. Until then the versions stay, so a kill
                    // here loses nothing.
                    for name in ["index.json", "tombstones.json"] {
                        environment.resolveConflicts(workingDir.appendingPathComponent(name))
                    }
                    for version in versions.dropFirst() {
                        for notebook in version.snapshot.notebooks {
                            environment.resolveConflicts(Self.notebookFileURL(for: notebook.id, in: workingDir))
                        }
                    }
                    AppLog.note("sync", "merged \(versions.count - 1) conflict version(s) of the index")
                }
            }
            if push {
                let t3 = Date()
                try performPush(against: remote, pending: pending, context: context, workingDir: workingDir, hashes: hashes)
                mark("push", since: t3)
            }
        }
    }

    // MARK: Pull

    /// Order matters for a kill in the middle: decide, copy payloads, then
    /// change the model. Killed after the copy, the next pull reaches the
    /// same decisions and copies the same bytes again. Killed after the
    /// model save but before the "pulled" marker, the next pull finds every
    /// page tied and changes nothing.
    ///
    /// Returns the notebooks that could not be fully applied because a
    /// page's payload hasn't arrived (or arrived damaged). Those pages keep
    /// their local state and the notebook is treated as pending.
    @discardableResult
    private func performPull(_ remote: RemoteLibrary?, context: ModelContext, workingDir: URL,
                             hashes: PayloadHashCache) throws -> Set<UUID> {
        guard let remote else { return [] }

        if !remote.isConflictVersion, remote.snapshot.signature == environment.state.lastAppliedRemoteSignature {
            return []  // already applied exactly this
        }

        var plan = try planMerge(of: remote.snapshot, context: context)

        let deferredPages = pullPayloads(for: remote.snapshot, plan: plan,
                                         from: workingDir.appendingPathComponent("files", isDirectory: true),
                                         to: environment.localFilesDirectory())
        var deferredNotebooks: Set<UUID> = []
        for notebook in remote.snapshot.notebooks {
            for page in notebook.pages where deferredPages.contains(page.id) {
                plan.pages[page.id] = .deferred
                deferredNotebooks.insert(notebook.id)
            }
        }

        try apply(remote.snapshot, plan: plan, context: context)

        SyncTombstones.merge(remote.snapshot.tombstones, into: environment.state)
        // A notebook file or payload the index promised but that hasn't
        // arrived yet (iCloud delivers files in no particular order) means
        // this snapshot isn't fully applied: leave the marker so the next
        // pull tries again. Nothing that did arrive is undone - the merge
        // is safe to repeat.
        let isComplete = remote.isComplete && deferredNotebooks.isEmpty
        if isComplete, !remote.isConflictVersion {
            environment.state.lastAppliedRemoteSignature = remote.snapshot.signature
        }

        // If the merge left this library identical to the snapshot, there's
        // nothing to push. If it didn't - a local page won, a local
        // tombstone isn't in the folder yet - the next push must go out, so
        // the marker is left alone. (It used to be set unconditionally,
        // which is how a device's own edits went unpushed.)
        if isComplete, !remote.isConflictVersion,
           try buildSnapshot(context: context, hashes: hashes).signature == remote.snapshot.signature {
            environment.state.lastPushSignature = remote.snapshot.signature
        }
        return deferredNotebooks
    }

    // MARK: Push

    /// Notebook files first, each atomically, then the index last, so a
    /// reader never sees an index pointing at content older than what's
    /// on disk - only newer, which the completeness rule in `readRemote`
    /// handles.
    ///
    /// A notebook whose file is still on its way (see `RemoteLibrary.pending`)
    /// is not written - this library only has its settings, and publishing
    /// it with no pages would overwrite the real content when it lands.
    /// The index keeps the folder's own entry for it.
    private func performPush(against remote: RemoteLibrary?, pending: Set<UUID>, context: ModelContext,
                             workingDir: URL, hashes: PayloadHashCache) throws {
        let snapshot = try buildSnapshot(context: context, hashes: hashes)
        let remoteIndex = remote?.index
        // Push unless the folder already holds exactly this library. That
        // is judged against the index just read, never against a stored
        // "last pushed" marker: a marker can be stale (it was, on a real
        // device, after a push that had to keep the folder's entry for a
        // pending notebook), and a stale marker means an edit that never
        // leaves the device. A folder without index.json yet (empty, or
        // format 1) always gets one - that's the migration.
        if let remote, remote.index != nil, !remote.isConflictVersion, remote.snapshot.signature == snapshot.signature { return }

        pushPayloads(for: snapshot,
                     from: environment.localFilesDirectory(),
                     to: workingDir.appendingPathComponent("files", isDirectory: true))

        let notebooksDir = workingDir.appendingPathComponent("notebooks", isDirectory: true)
        try FileManager.default.createDirectory(at: notebooksDir, withIntermediateDirectories: true)
        let remoteEntries = Dictionary((remoteIndex?.notebooks ?? []).map { ($0.id, $0) },
                                       uniquingKeysWith: { first, _ in first })
        for notebook in snapshot.notebooks where !pending.contains(notebook.id) {
            let url = Self.notebookFileURL(for: notebook.id, in: workingDir)
            if let entry = remoteEntries[notebook.id],
               entry.contentSignature == notebook.contentSignature,
               entry.settingsModifiedAt == notebook.settingsModifiedAt,
               FileManager.default.fileExists(atPath: url.path) {
                continue  // the folder already has this exact notebook
            }
            try writeJSON(notebook, to: url)
        }

        // Tombstones before the index: a reader that sees the new index
        // but the old tombstone file only lacks deletions it will get next
        // time, whereas the reverse could let a deleted notebook's entry
        // linger with no tombstone to explain it.
        try writeJSON(TombstoneFile(tombstones: snapshot.tombstones), to: Self.tombstonesURL(in: workingDir))

        var index = snapshot.makeIndex()
        index.notebooks = index.notebooks.map { entry in
            pending.contains(entry.id) ? (remoteEntries[entry.id] ?? entry) : entry
        }
        try writeJSON(index, to: Self.indexURL(in: workingDir))
        keepHistory(of: index, workingDir: workingDir)
        pruneFolder(workingDir: workingDir, tombstones: snapshot.tombstones, pending: pending)

        // What was actually written - with the folder's own entries kept
        // for anything pending - not what this library holds. Recording the
        // local signature here meant a device whose notebook was pending
        // believed it had published it and, with nothing changing locally,
        // never tried again.
        let written = LibraryIndex.signature(folders: index.folders, notebooks: index.notebooks, tombstones: snapshot.tombstones)
        environment.state.lastPushSignature = written
        // We authored this snapshot - don't turn around and re-apply it.
        // Unless something is still pending: then the next pull must look
        // again, and re-reading our own index is cheap and harmless.
        environment.state.lastAppliedRemoteSignature = pending.isEmpty ? written : nil
    }

    // MARK: Reading the folder

    /// What a pull found in the folder.
    struct RemoteLibrary {
        /// Every folder, tombstone and notebook index entry, plus the
        /// `NotebookDTO`s that needed reading (new here, or changed).
        var snapshot: LibrarySnapshot
        /// Notebooks whose file the index promised but which was missing
        /// or unreadable. This library has only their settings, so they
        /// must not be republished from here.
        var pending: Set<UUID>
        /// Notebooks whose file was read but doesn't match its index entry
        /// - an older or newer push than the index came from, or an entry
        /// written by a build that hashed differently. Applied (the merge
        /// is safe either way) but the pull isn't marked done, so the next
        /// one looks again. Unlike `pending`, these *are* republished: the
        /// only way a stale entry gets replaced is for someone to write a
        /// current one.
        var mismatched: Set<UUID>
        /// nil for a format-1 `library.json`.
        var index: LibraryIndex?
        /// True for a version iCloud kept aside after concurrent writes;
        /// it is merged but never counts as "the" folder state.
        var isConflictVersion = false
        /// Conflict versions of individual notebook files, found while
        /// reading this index. Each is merged as a version of its own -
        /// never alongside the current file in one snapshot, because the
        /// merge plan is keyed by page and the last DTO seen would decide.
        var notebookConflictVersions: [NotebookDTO] = []

        /// A conflict version's entries describe files that have since been
        /// replaced, so "doesn't match its entry" is its normal condition,
        /// not a reason to wait.
        var isComplete: Bool { pending.isEmpty && (mismatched.isEmpty || isConflictVersion) }
    }

    /// The folder's index exists but iCloud hasn't downloaded it. Nothing
    /// can be merged or safely written until it has - pushing now would
    /// put this library's index over one we never read.
    struct Waiting: LocalizedError {
        var errorDescription: String? { "Waiting for iCloud to download the library…" }
    }

    enum SyncFormatError: LocalizedError {
        case newerThanThisBuild(Int)

        var errorDescription: String? {
            switch self {
            case .newerThanThisBuild:
                return "This sync folder was written by a newer version of MystNotes. Update the app to keep syncing."
            }
        }
    }

    private static func indexURL(in workingDir: URL) -> URL {
        workingDir.appendingPathComponent("index.json")
    }

    private static func legacyLibraryURL(in workingDir: URL) -> URL {
        workingDir.appendingPathComponent("library.json")
    }

    private static func tombstonesURL(in workingDir: URL) -> URL {
        workingDir.appendingPathComponent("tombstones.json")
    }

    private static func historyDirectory(in workingDir: URL) -> URL {
        workingDir.appendingPathComponent("index-history", isDirectory: true)
    }

    static func notebookFileURL(for id: UUID, in workingDir: URL) -> URL {
        workingDir.appendingPathComponent("notebooks", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).json")
    }

    /// The folder's current library, followed by one entry per unresolved
    /// conflict version of `index.json`. Empty when there is no library.
    private func readRemoteVersions(workingDir: URL, context: ModelContext) throws -> [RemoteLibrary] {
        guard let current = try readRemote(workingDir: workingDir, context: context) else { return [] }
        var versions = [current]
        for url in environment.conflictVersions(Self.indexURL(in: workingDir)) {
            guard var version = try? readIndexedLibrary(indexURL: url, workingDir: workingDir, context: context) else { continue }
            version.isConflictVersion = true
            versions.append(version)
        }
        // Every notebook-file conflict becomes a version of its own, after
        // the index versions, so its pages are compared against a library
        // that has already taken in everything the current files said.
        var seen = Set<String>()
        for version in versions {
            for dto in version.notebookConflictVersions {
                let key = "\(dto.id):\(dto.contentSignature)"
                guard seen.insert(key).inserted else { continue }
                var single = version
                single.snapshot.notebooks = [dto]
                single.isConflictVersion = true
                single.notebookConflictVersions = []
                versions.append(single)
            }
        }
        return versions
    }

    private func readRemote(workingDir: URL, context: ModelContext) throws -> RemoteLibrary? {
        let indexURL = Self.indexURL(in: workingDir)
        switch SyncFolder.availability(of: indexURL) {
        case .available: return try readIndexedLibrary(indexURL: indexURL, workingDir: workingDir, context: context)
        case .pending: throw Waiting()
        case .absent: break
        }

        // Format 1: the whole library in one file, from before the split.
        let legacyURL = Self.legacyLibraryURL(in: workingDir)
        switch SyncFolder.availability(of: legacyURL) {
        case .available: break
        case .pending: throw Waiting()
        case .absent: return nil
        }
        let legacy: LibrarySnapshot = try readJSON(from: legacyURL)
        guard legacy.formatVersion <= librarySnapshotFormatVersion else {
            throw SyncFormatError.newerThanThisBuild(legacy.formatVersion)
        }
        return RemoteLibrary(snapshot: legacy, pending: [], mismatched: [], index: nil)
    }

    private func readIndexedLibrary(indexURL: URL, workingDir: URL, context: ModelContext) throws -> RemoteLibrary {
        let index: LibraryIndex = try readJSON(from: indexURL)
        guard index.formatVersion <= librarySnapshotFormatVersion else {
            throw SyncFormatError.newerThanThisBuild(index.formatVersion)
        }

        // Only open the notebook files whose page set differs from ours.
        let localSignatures = Dictionary(
            (try context.fetch(FetchDescriptor<Notebook>())).map { notebook in
                (notebook.id, NotebookDTO.contentSignature(of: (notebook.pages ?? []).map { ($0.id, $0.modifiedAt) }))
            },
            uniquingKeysWith: { first, _ in first }
        )

        var notebooks: [NotebookDTO] = []
        var notebookConflicts: [NotebookDTO] = []
        var pending: Set<UUID> = []
        var mismatched: Set<UUID> = []
        for entry in index.notebooks where localSignatures[entry.id] != entry.contentSignature {
            let url = Self.notebookFileURL(for: entry.id, in: workingDir)
            guard SyncFolder.availability(of: url) == .available,
                  let notebook: NotebookDTO = try? readJSON(from: url) else {
                pending.insert(entry.id)   // not here yet, or not all here yet
                continue
            }
            if notebook.contentSignature != entry.contentSignature { mismatched.insert(entry.id) }
            notebooks.append(notebook)
            // A notebook file both devices wrote offline: iCloud kept the
            // other write. Same pages, merged by date - as its own version.
            for versionURL in environment.conflictVersions(url) {
                if let other: NotebookDTO = try? readJSON(from: versionURL) { notebookConflicts.append(other) }
            }
        }

        let snapshot = LibrarySnapshot(
            formatVersion: index.formatVersion,
            exportedAt: index.exportedAt,
            deviceName: index.deviceName,
            folders: index.folders,
            notebooks: notebooks,
            notebookIndex: index.notebooks,
            tombstones: try readTombstones(workingDir: workingDir) + (index.tombstones ?? [])
        )
        return RemoteLibrary(snapshot: snapshot, pending: pending, mismatched: mismatched, index: index,
                             notebookConflictVersions: notebookConflicts)
    }

    /// `tombstones.json`, or nothing if it isn't there yet. An unreadable
    /// file is treated the same way - a deletion that can't be read this
    /// round is applied next round; nothing is resurrected in between
    /// because the local list still has everything this device knew.
    private func readTombstones(workingDir: URL) throws -> [Tombstone] {
        let url = Self.tombstonesURL(in: workingDir)
        guard SyncFolder.availability(of: url) == .available else { return [] }
        let file: TombstoneFile? = try? readJSON(from: url)
        var stones = file?.tombstones ?? []
        // Tombstones merge by union, so a conflict version just adds.
        for versionURL in environment.conflictVersions(url) {
            if let other: TombstoneFile = try? readJSON(from: versionURL) { stones += other.tombstones }
        }
        return stones
    }

    // MARK: Pruning

    /// Moves what nothing references any more out of the way - never
    /// deletes it (invariant 3). Runs after every index write, while the
    /// folder is held.
    ///
    /// - A tombstoned notebook's `notebooks/<id>.json` goes to
    ///   `notebooks/trash/`.
    /// - A payload in `files/` that no notebook file in the folder
    ///   references goes to `files/trash/` - but only once it is older
    ///   than `orphanGracePeriod`, because the notebook file that
    ///   references it may simply not have arrived yet (iCloud delivers
    ///   files in no particular order, and a device can be offline for
    ///   days between uploading its payloads and its notebook file).
    private func pruneFolder(workingDir: URL, tombstones: [Tombstone], pending: Set<UUID>) {
        let fm = FileManager.default
        let notebooksDir = workingDir.appendingPathComponent("notebooks", isDirectory: true)
        let filesDir = workingDir.appendingPathComponent("files", isDirectory: true)

        for stone in tombstones where stone.kind == .notebook {
            DrawingStore.moveToTrash(Self.notebookFileURL(for: stone.id, in: workingDir), tag: "deleted")
        }

        // Known to be missing notebook files this round: their payloads
        // would all look unreferenced. Don't prune until the folder is
        // whole. The mirror has no payloads of its own to prune.
        guard pending.isEmpty, !environment.payloadsAreLocal else { return }

        // Everything any notebook file still points at, under the name it
        // has in the folder. An unreadable notebook file (still
        // downloading) keeps everything: we can't know what it references,
        // so nothing is pruned this round.
        var referenced: Set<String> = []
        guard let notebookNames = try? fm.contentsOfDirectory(atPath: notebooksDir.path) else { return }
        for name in notebookNames where name.hasSuffix(".json") {
            guard let notebook: NotebookDTO = try? readJSON(from: notebooksDir.appendingPathComponent(name)) else { return }
            for page in notebook.pages {
                for ref in Self.payloads(of: page) { referenced.insert(ref.folderName) }
            }
        }

        let cutoff = environment.now().addingTimeInterval(-environment.orphanGracePeriod)
        guard let payloadNames = try? fm.contentsOfDirectory(atPath: filesDir.path) else { return }
        for name in payloadNames where !name.hasPrefix(".") && !referenced.contains(name) {
            let url = filesDir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  modified < cutoff else { continue }
            DrawingStore.moveToTrash(url, tag: "orphan")
        }
    }

    // MARK: Index history

    /// Keeps the last `indexHistoryLimit` copies of `index.json` so a bad
    /// write - ours or another device's - is never the only copy. Names
    /// sort by time, so pruning is "drop the oldest by name". These are
    /// this engine's own snapshots, not user payloads, so removing them
    /// is fine.
    private func keepHistory(of index: LibraryIndex, workingDir: URL) {
        let fm = FileManager.default
        let dir = Self.historyDirectory(in: workingDir)
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return }

        let stamp = String(format: "%.3f", index.exportedAt.timeIntervalSince1970)
        let device = index.deviceName.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
        let name = "\(stamp)-\(String(device)).json"
        try? writeJSON(index, to: dir.appendingPathComponent(name))

        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let sorted = names.filter { $0.hasSuffix(".json") }.sorted()
        for stale in sorted.dropLast(max(environment.indexHistoryLimit, 1)) {
            try? fm.removeItem(at: dir.appendingPathComponent(stale))
        }
    }

    // MARK: Coordinated JSON I/O

    private func readJSON<T: Decodable>(from url: URL) throws -> T {
        var coordinationError: NSError?
        var decoded: T?
        var thrown: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            do {
                decoded = try jsonDecoder.decode(T.self, from: Data(contentsOf: readURL))
            } catch {
                thrown = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let thrown { throw thrown }
        return decoded!
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try jsonEncoder.encode(value)
        var coordinationError: NSError?
        var thrown: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { writeURL in
            do {
                try data.write(to: writeURL, options: .atomic)
            } catch {
                thrown = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let thrown { throw thrown }
    }

    // MARK: Planning the merge

    /// What the merge will do to each page, decided before anything is
    /// touched so payload copies and model changes agree.
    struct MergePlan {
        enum PageOutcome {
            /// The page is new here.
            case insert
            /// Both sides have it and the remote copy is newer.
            case remoteWins
            /// Both sides have it and the local copy is newer or the same.
            case localWins
            /// A tombstone covers it; it must not come (back) in.
            case skip
            /// The remote copy would win, but its payload hasn't arrived.
            /// Nothing changes this round; the notebook is pending.
            case deferred
        }
        var pages: [UUID: PageOutcome] = [:]
        /// Local pages a page tombstone removes.
        var deletedLocalPages: Set<UUID> = []
        /// The newest tombstone per id, local and remote combined.
        var tombstones: [UUID: Tombstone] = [:]
    }

    private func planMerge(of remote: LibrarySnapshot, context: ModelContext) throws -> MergePlan {
        var plan = MergePlan()

        for stone in SyncTombstones.load(from: environment.state) + remote.tombstones {
            if let existing = plan.tombstones[stone.id], existing.deletedAt >= stone.deletedAt { continue }
            plan.tombstones[stone.id] = stone
        }

        let localPages = Dictionary(
            (try context.fetch(FetchDescriptor<Page>())).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for (id, stone) in plan.tombstones where stone.kind == .page {
            if let page = localPages[id], Self.date(page.modifiedAt) <= stone.deletedAt {
                plan.deletedLocalPages.insert(id)
            }
        }

        for notebookDTO in remote.notebooks where plan.tombstones[notebookDTO.id] == nil {
            for pageDTO in notebookDTO.pages {
                if let stone = plan.tombstones[pageDTO.id], stone.kind == .page,
                   Self.date(pageDTO.modifiedAt) <= stone.deletedAt {
                    plan.pages[pageDTO.id] = .skip
                } else if let local = localPages[pageDTO.id] {
                    plan.pages[pageDTO.id] = Self.date(pageDTO.modifiedAt) > Self.date(local.modifiedAt)
                        ? .remoteWins : .localWins
                } else {
                    plan.pages[pageDTO.id] = .insert
                }
            }
        }
        return plan
    }

    /// `nil` predates the field and loses to any real date.
    private static func date(_ optional: Date?) -> Date {
        optional ?? .distantPast
    }

    // MARK: Payload files

    /// One payload a page needs: its local name, and its content hash when
    /// the snapshot knows it (snapshots from before content addressing
    /// don't; their files sit in the folder under the local name).
    private struct PayloadRef {
        var localName: String
        var hash: String?
        /// Whether a local copy may legitimately differ from the folder's
        /// (ink is rewritten in place; imports never change).
        var isMutable: Bool

        var folderName: String {
            hash.map { PayloadHash.folderName(hash: $0, localName: localName) } ?? localName
        }
    }

    private static func payloads(of page: PageDTO) -> [PayloadRef] {
        var refs: [PayloadRef] = []
        if let name = page.drawingFileRef, !name.isEmpty {
            refs.append(PayloadRef(localName: name, hash: page.drawingHash, isMutable: true))
        }
        if let name = page.backgroundRef, !name.isEmpty {
            refs.append(PayloadRef(localName: name, hash: page.backgroundHash, isMutable: false))
        }
        for doc in page.importedDocuments where !doc.fileRef.isEmpty {
            refs.append(PayloadRef(localName: doc.fileRef, hash: doc.fileHash, isMutable: false))
        }
        return refs
    }

    /// Brings in the payloads the merge is going to need, for the pages
    /// the plan says come from the folder. A payload is copied only once
    /// it rehashes to its own name - a file still downloading, or damaged,
    /// doesn't match and the page is deferred. If the local copy of a
    /// drawing differs from what's coming, that's the same-page conflict:
    /// the local ink goes to `trash/` first, never overwritten.
    ///
    /// Returns the pages whose payloads are not all here yet.
    private func pullPayloads(for remote: LibrarySnapshot, plan: MergePlan, from source: URL, to destination: URL) -> Set<UUID> {
        // The mirror references the local files themselves; there is
        // nothing to bring in.
        guard !environment.payloadsAreLocal else { return [] }
        let fm = FileManager.default
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var deferred: Set<UUID> = []

        for notebookDTO in remote.notebooks {
            for pageDTO in notebookDTO.pages {
                switch plan.pages[pageDTO.id] {
                case .insert?, .remoteWins?: break
                default: continue
                }
                for ref in Self.payloads(of: pageDTO) where !fetch(ref, from: source, to: destination) {
                    deferred.insert(pageDTO.id)
                }
            }
        }
        return deferred
    }

    /// Copies one payload from the folder to the local directory. False if
    /// it isn't there yet or doesn't match its hash.
    private func fetch(_ ref: PayloadRef, from source: URL, to destination: URL) -> Bool {
        let fm = FileManager.default
        let dst = destination.appendingPathComponent(ref.localName)

        // Already have exactly this content? Nothing to do.
        if fm.fileExists(atPath: dst.path) {
            if let hash = ref.hash {
                if PayloadHash.sha256(of: dst) == hash { return true }
            } else if !ref.isMutable {
                return true   // immutable and unversioned: whatever is here is it
            }
        }

        let src = source.appendingPathComponent(ref.folderName)
        guard SyncFolder.availability(of: src) == .available else { return false }
        if let hash = ref.hash, PayloadHash.sha256(of: src) != hash {
            return false   // partial download or damaged: not this content
        }

        if fm.fileExists(atPath: dst.path) {
            if ref.hash == nil, !Self.filesDiffer(src, dst) { return true }
            DrawingStore.moveToTrash(dst, tag: ref.isMutable ? "conflict" : "replaced")
        }
        return (try? fm.copyItem(at: src, to: dst)) != nil
    }

    /// Puts this library's payloads in the folder under their content
    /// names. A file that already exists there is by definition identical,
    /// so nothing in `files/` is ever overwritten.
    private func pushPayloads(for snapshot: LibrarySnapshot, from source: URL, to destination: URL) {
        guard !environment.payloadsAreLocal else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)

        for notebookDTO in snapshot.notebooks {
            for pageDTO in notebookDTO.pages {
                for ref in Self.payloads(of: pageDTO) where ref.hash != nil {
                    let dst = destination.appendingPathComponent(ref.folderName)
                    guard !fm.fileExists(atPath: dst.path) else { continue }
                    let src = source.appendingPathComponent(ref.localName)
                    guard fm.fileExists(atPath: src.path) else { continue }
                    // Stage then rename, so a reader never sees a partial
                    // file under a name that promises complete content.
                    let staging = destination.appendingPathComponent(".\(ref.folderName).tmp")
                    try? fm.removeItem(at: staging)
                    guard (try? fm.copyItem(at: src, to: staging)) != nil else { continue }
                    if (try? fm.moveItem(at: staging, to: dst)) == nil { try? fm.removeItem(at: staging) }
                }
            }
        }
    }

    private static func filesDiffer(_ a: URL, _ b: URL) -> Bool {
        guard let dataA = try? Data(contentsOf: a), let dataB = try? Data(contentsOf: b) else { return true }
        return dataA != dataB
    }

    /// Content hashes of local payloads, so a push doesn't reread every
    /// file in the library. Persisted as `.payload-hashes.json` beside the
    /// payloads; each entry is validated against the file's current size
    /// and modification date - the same stat-cache rule git's index uses.
    /// This is a device checking its own files on its own filesystem, not
    /// the cross-device mtime comparison the old `copyFiles` did.
    ///
    /// Without it a sync with nothing to do cost 0.45 s at 2,000 tiny
    /// pages and grows with total payload bytes (PERFORMANCE_BASELINE).
    final class PayloadHashCache {
        struct Entry: Codable, Equatable {
            var size: Int
            var modified: Date
            var hash: String
        }

        static let fileName = ".payload-hashes.json"

        private var entries: [String: Entry] = [:]
        private var dirty = false
        private var directory: URL?

        init() {}

        /// Loads the persisted cache for `directory`, if any.
        init(directory: URL) {
            self.directory = directory
            let url = directory.appendingPathComponent(Self.fileName)
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
                entries = decoded
            }
        }

        var count: Int { entries.count }

        func hash(of name: String, in directory: URL) -> String? {
            let url = directory.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
            if let entry = entries[name], entry.size == size, entry.modified == modified { return entry.hash }
            guard let hash = PayloadHash.sha256(of: url) else { return nil }
            entries[name] = Entry(size: size, modified: modified, hash: hash)
            dirty = true
            return hash
        }

        /// Drops entries for files that no longer exist and writes the
        /// cache if anything changed this run.
        func persist() {
            guard let directory else { return }
            let fm = FileManager.default
            let live = entries.filter { fm.fileExists(atPath: directory.appendingPathComponent($0.key).path) }
            guard dirty || live.count != entries.count else { return }
            entries = live
            if let data = try? JSONEncoder().encode(entries) {
                try? data.write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
            }
            dirty = false
        }
    }

    // MARK: Build snapshot from the model graph

    private func buildSnapshot(context: ModelContext, hashes: PayloadHashCache) throws -> LibrarySnapshot {
        let local = environment.localFilesDirectory()
        let folders = try context.fetch(FetchDescriptor<Folder>())
        let notebooks = try context.fetch(FetchDescriptor<Notebook>())
        let allLinks = try context.fetch(FetchDescriptor<Link>())
        let allDocs = try context.fetch(FetchDescriptor<ImportedDocument>())

        let docsByPage = Dictionary(grouping: allDocs, by: { $0.page?.id })

        let folderDTOs = folders.map {
            FolderDTO(id: $0.id, name: $0.name, parentID: $0.parentFolder?.id)
        }

        let notebookDTOs = notebooks.map { notebook -> NotebookDTO in
            let pages = (notebook.pages ?? []).sorted { $0.index < $1.index }
            let pageIDs = Set(pages.map(\.id))
            let pageDTOs = pages.map { page -> PageDTO in
                PageDTO(
                    id: page.id,
                    index: page.index,
                    type: page.type,
                    template: page.template,
                    drawingFileRef: page.drawingFileRef,
                    backgroundRef: page.backgroundRef,
                    recognizedTextCache: page.recognizedTextCache,
                    ocrUpdatedAt: page.ocrUpdatedAt,
                    modifiedAt: page.modifiedAt,
                    aspectRatio: page.aspectRatio,
                    drawingHash: page.drawingFileRef.flatMap { hashes.hash(of: $0, in: local) },
                    backgroundHash: page.backgroundRef.flatMap { hashes.hash(of: $0, in: local) },
                    textBlocks: (page.textBlocks ?? []).map {
                        TextBlockDTO(id: $0.id, content: $0.content,
                                     frameX: $0.frameX, frameY: $0.frameY,
                                     frameWidth: $0.frameWidth, frameHeight: $0.frameHeight,
                                     textColorHex: $0.textColorHex)
                    },
                    stickers: (page.stickers ?? []).map {
                        StickerDTO(id: $0.id, assetRef: $0.assetRef,
                                   frameX: $0.frameX, frameY: $0.frameY,
                                   frameWidth: $0.frameWidth, frameHeight: $0.frameHeight)
                    },
                    importedDocuments: (docsByPage[page.id] ?? []).map {
                        ImportedDocumentDTO(id: $0.id, sourceType: $0.sourceType, fileRef: $0.fileRef,
                                            fileHash: hashes.hash(of: $0.fileRef, in: local),
                                            pdfPageIndex: $0.pdfPageIndex,
                                            frameX: $0.frameX, frameY: $0.frameY,
                                            frameWidth: $0.frameWidth, frameHeight: $0.frameHeight,
                                            rotationDegrees: $0.rotationDegrees,
                                            cropX: $0.cropX, cropY: $0.cropY,
                                            cropWidth: $0.cropWidth, cropHeight: $0.cropHeight)
                    }
                )
            }
            let links = allLinks
                .filter { pageIDs.contains($0.sourcePageID) }
                .map {
                    LinkDTO(id: $0.id, sourcePageID: $0.sourcePageID, destinationPageID: $0.destinationPageID,
                            anchorX: $0.anchorX, anchorY: $0.anchorY,
                            anchorWidth: $0.anchorWidth, anchorHeight: $0.anchorHeight)
                }
            return NotebookDTO(
                id: notebook.id, title: notebook.title, coverStyle: notebook.coverStyle,
                createdAt: notebook.createdAt, modifiedAt: notebook.modifiedAt,
                settingsModifiedAt: notebook.settingsModifiedAt,
                folderID: notebook.folder?.id, pages: pageDTOs, links: links
            )
        }

        return LibrarySnapshot(
            exportedAt: environment.now(),
            deviceName: environment.deviceName,
            folders: folderDTOs,
            notebooks: notebookDTOs,
            notebookIndex: nil,
            tombstones: SyncTombstones.load(from: environment.state)
        )
    }

    // MARK: Apply snapshot into the model graph

    private func apply(_ remote: LibrarySnapshot, plan: MergePlan, context: ModelContext) throws {
        var folderByID = Dictionary(
            (try context.fetch(FetchDescriptor<Folder>())).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var notebookByID = Dictionary(
            (try context.fetch(FetchDescriptor<Notebook>())).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var pageByID = Dictionary(
            (try context.fetch(FetchDescriptor<Page>())).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var links = try context.fetch(FetchDescriptor<Link>())
        var docs = try context.fetch(FetchDescriptor<ImportedDocument>())

        // 1. Deletions.
        for stone in plan.tombstones.values {
            switch stone.kind {
            case .notebook:
                if let notebook = notebookByID[stone.id], notebook.modifiedAt <= stone.deletedAt {
                    trashFiles(for: notebook)
                    context.delete(notebook)
                    notebookByID[stone.id] = nil
                    for page in notebook.pages ?? [] { pageByID[page.id] = nil }
                }
            case .folder:
                if let folder = folderByID[stone.id] {
                    context.delete(folder)   // cascades to subfolders / notebooks
                    folderByID[stone.id] = nil
                }
            case .page:
                guard plan.deletedLocalPages.contains(stone.id), let page = pageByID[stone.id] else { continue }
                removeChildren(of: page, links: &links, docs: &docs, context: context)
                page.notebook?.pages?.removeAll { $0.id == page.id }
                context.delete(page)
                DrawingStore.inDirectory(environment.localFilesDirectory()).trashDrawing(forPageID: page.id)
                pageByID[stone.id] = nil
            }
        }

        // 2. Folders: upsert, then wire up parents once all exist.
        for dto in remote.folders where plan.tombstones[dto.id] == nil {
            if let folder = folderByID[dto.id] {
                folder.name = dto.name
            } else {
                let folder = Folder(name: dto.name)
                folder.id = dto.id
                context.insert(folder)
                folderByID[dto.id] = folder
            }
        }
        for dto in remote.folders where plan.tombstones[dto.id] == nil {
            folderByID[dto.id]?.parentFolder = dto.parentID.flatMap { folderByID[$0] }
        }

        // 3. Notebook settings, from the index: last-writer-wins on their
        //    own clock, so a rename can't lose to a later page edit.
        for entry in remote.index where plan.tombstones[entry.id] == nil {
            if let existing = notebookByID[entry.id] {
                if Self.date(entry.settingsModifiedAt) > Self.date(existing.settingsModifiedAt) {
                    existing.title = entry.title
                    existing.coverStyle = entry.coverStyle
                    existing.folder = entry.folderID.flatMap { folderByID[$0] }
                    existing.settingsModifiedAt = entry.settingsModifiedAt
                }
                lift(existing, to: entry.modifiedAt)
            } else {
                let notebook = Notebook(title: entry.title)
                notebook.id = entry.id
                notebook.coverStyle = entry.coverStyle
                notebook.createdAt = entry.createdAt
                notebook.modifiedAt = entry.modifiedAt
                notebook.settingsModifiedAt = entry.settingsModifiedAt
                notebook.folder = entry.folderID.flatMap { folderByID[$0] }
                context.insert(notebook)
                notebookByID[entry.id] = notebook
            }
        }

        // 4. Pages, from the notebook files that needed reading.
        for dto in remote.notebooks where plan.tombstones[dto.id] == nil {
            guard let notebook = notebookByID[dto.id] else { continue }

            for pageDTO in dto.pages.sorted(by: { $0.index < $1.index }) {
                switch plan.pages[pageDTO.id] {
                case .insert?:
                    let page = Page(index: pageDTO.index, type: pageDTO.type, template: pageDTO.template, notebook: notebook)
                    page.id = pageDTO.id
                    context.insert(page)
                    notebook.pages?.append(page)
                    pageByID[page.id] = page
                    setFields(of: page, from: pageDTO)
                    page.recognizedTextCache = pageDTO.recognizedTextCache
                    page.ocrUpdatedAt = pageDTO.ocrUpdatedAt
                    addChildren(to: page, from: pageDTO, links: dto.links, context: context)
                    lift(notebook, to: page.modifiedAt)

                case .remoteWins?:
                    guard let page = pageByID[pageDTO.id] else { continue }
                    removeChildren(of: page, links: &links, docs: &docs, context: context)
                    setFields(of: page, from: pageDTO)
                    addChildren(to: page, from: pageDTO, links: dto.links, context: context)
                    mergeRecognizedText(into: page, from: pageDTO)
                    lift(notebook, to: page.modifiedAt)

                case .localWins?:
                    guard let page = pageByID[pageDTO.id] else { continue }
                    mergeRecognizedText(into: page, from: pageDTO)

                case .skip?, .deferred?, nil:
                    continue
                }
            }
        }

        try context.save()
    }

    /// The user-edited fields. Never the OCR fields - see
    /// `mergeRecognizedText`.
    private func setFields(of page: Page, from dto: PageDTO) {
        page.index = dto.index
        page.type = dto.type
        page.template = dto.template
        page.drawingFileRef = dto.drawingFileRef
        page.backgroundRef = dto.backgroundRef
        page.modifiedAt = dto.modifiedAt
        if let aspectRatio = dto.aspectRatio { page.aspectRatio = aspectRatio }
    }

    /// Derived data merges on its own clock, whichever side won the page:
    /// a background recognition pass must never out-rank a stroke, and a
    /// stroke must never throw away a newer recognition result.
    private func mergeRecognizedText(into page: Page, from dto: PageDTO) {
        guard Self.date(dto.ocrUpdatedAt) > Self.date(page.ocrUpdatedAt) else { return }
        page.recognizedTextCache = dto.recognizedTextCache
        page.ocrUpdatedAt = dto.ocrUpdatedAt
    }

    private func lift(_ notebook: Notebook, to date: Date?) {
        if let date, date > notebook.modifiedAt { notebook.modifiedAt = date }
    }

    private func removeChildren(of page: Page, links: inout [Link], docs: inout [ImportedDocument], context: ModelContext) {
        for block in page.textBlocks ?? [] { context.delete(block) }
        page.textBlocks = []
        for sticker in page.stickers ?? [] { context.delete(sticker) }
        page.stickers = []
        for doc in docs where doc.page?.id == page.id { context.delete(doc) }
        docs.removeAll { $0.page?.id == page.id }
        for link in links where link.sourcePageID == page.id { context.delete(link) }
        links.removeAll { $0.sourcePageID == page.id }
    }

    private func addChildren(to page: Page, from pageDTO: PageDTO, links: [LinkDTO], context: ModelContext) {
        var textBlocks: [TypedTextBlock] = []
        for blockDTO in pageDTO.textBlocks {
            let block = TypedTextBlock(content: blockDTO.content, page: page)
            block.id = blockDTO.id
            block.frameX = blockDTO.frameX
            block.frameY = blockDTO.frameY
            block.frameWidth = blockDTO.frameWidth
            block.frameHeight = blockDTO.frameHeight
            block.textColorHex = blockDTO.textColorHex
            context.insert(block)
            textBlocks.append(block)
        }
        page.textBlocks = textBlocks

        var stickers: [Sticker] = []
        for stickerDTO in pageDTO.stickers {
            let sticker = Sticker(assetRef: stickerDTO.assetRef, page: page)
            sticker.id = stickerDTO.id
            sticker.frameX = stickerDTO.frameX
            sticker.frameY = stickerDTO.frameY
            sticker.frameWidth = stickerDTO.frameWidth
            sticker.frameHeight = stickerDTO.frameHeight
            context.insert(sticker)
            stickers.append(sticker)
        }
        page.stickers = stickers

        for docDTO in pageDTO.importedDocuments {
            let doc = ImportedDocument(sourceType: docDTO.sourceType, fileRef: docDTO.fileRef,
                                      pdfPageIndex: docDTO.pdfPageIndex, page: page)
            doc.id = docDTO.id
            doc.frameX = docDTO.frameX
            doc.frameY = docDTO.frameY
            doc.frameWidth = docDTO.frameWidth
            doc.frameHeight = docDTO.frameHeight
            doc.rotationDegrees = docDTO.rotationDegrees
            doc.cropX = docDTO.cropX
            doc.cropY = docDTO.cropY
            doc.cropWidth = docDTO.cropWidth
            doc.cropHeight = docDTO.cropHeight
            context.insert(doc)
        }

        for linkDTO in links where linkDTO.sourcePageID == page.id {
            let link = Link(sourcePageID: linkDTO.sourcePageID, destinationPageID: linkDTO.destinationPageID)
            link.id = linkDTO.id
            link.anchorX = linkDTO.anchorX
            link.anchorY = linkDTO.anchorY
            link.anchorWidth = linkDTO.anchorWidth
            link.anchorHeight = linkDTO.anchorHeight
            context.insert(link)
        }
    }

    /// A tombstoned notebook's ink goes to `trash/`, not away (invariant 3).
    private func trashFiles(for notebook: Notebook) {
        let store = DrawingStore.inDirectory(environment.localFilesDirectory())
        for page in notebook.pages ?? [] {
            store.trashDrawing(forPageID: page.id)
        }
    }
}
