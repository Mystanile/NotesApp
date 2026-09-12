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
/// Triggers (wired in `ContentView`): pull when the app becomes active, push
/// when it goes to the background, plus a manual "Sync Now" in Settings.
@MainActor
final class SyncEngine: ObservableObject {
    static let shared = SyncEngine()
    private init() {}

    enum Status: Equatable {
        case idle
        case syncing
        case succeeded(Date)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle

    private var container: ModelContainer?
    private var isRunning = false

    func configure(container: ModelContainer) {
        if self.container == nil { self.container = container }
    }

    /// Records the user's chosen folder and kicks off the first sync. Any
    /// failure (typically the Mac sandbox refusing a persistent bookmark)
    /// lands in `status` so the Settings screen can show it.
    func chooseFolder(_ url: URL) {
        do {
            try SyncFolder.setFolder(url)
            objectWillChange.send()
            syncNow()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func syncNow() { start(pull: true, push: true) }

    func pullOnForeground() {
        guard SyncFolder.isConfigured else { return }
        start(pull: true, push: false)
    }

    func pushOnBackground() {
        guard SyncFolder.isConfigured else { return }
        start(pull: false, push: true)
    }

    private func start(pull: Bool, push: Bool) {
        guard let container else { return }
        guard SyncFolder.isConfigured else {
            status = .failed(SyncFolder.SyncFolderError.notConfigured.localizedDescription)
            return
        }
        guard !isRunning else { return }
        isRunning = true
        status = .syncing

        let environment = SyncEnvironment.live
        Task.detached(priority: .utility) {
            let outcome: Result<Void, Error>
            do {
                try SyncRunner(container: container, environment: environment).run(pull: pull, push: push)
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run {
                self.isRunning = false
                switch outcome {
                case .success:
                    self.status = .succeeded(Date())
                case .failure(let error):
                    self.status = .failed(error.localizedDescription)
                }
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
struct SyncRunner {
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
        try environment.withFolder { folder in
            let workingDir = try SyncFolder.workingDirectory(in: folder)
            // A push always pulls first: it folds in whatever another device
            // wrote so what we're about to write isn't stale.
            let remote = try readRemote(workingDir: workingDir, context: context)
            if pull || push { try performPull(remote, context: context, workingDir: workingDir) }
            if push { try performPush(against: remote, context: context, workingDir: workingDir) }
        }
    }

    // MARK: Pull

    /// Order matters for a kill in the middle: decide, copy payloads, then
    /// change the model. Killed after the copy, the next pull reaches the
    /// same decisions and copies the same bytes again. Killed after the
    /// model save but before the "pulled" marker, the next pull finds every
    /// page tied and changes nothing.
    private func performPull(_ remote: RemoteLibrary?, context: ModelContext, workingDir: URL) throws {
        guard let remote else { return }

        if let lastPulled = environment.state.lastPulledExportDate, remote.snapshot.exportedAt <= lastPulled {
            return  // already applied this snapshot
        }

        let plan = try planMerge(of: remote.snapshot, context: context)

        pullPayloads(for: remote.snapshot, plan: plan,
                     from: workingDir.appendingPathComponent("files", isDirectory: true),
                     to: environment.localFilesDirectory())

        try apply(remote.snapshot, plan: plan, context: context)

        SyncTombstones.merge(remote.snapshot.tombstones, into: environment.state)
        // A notebook file the index promised but that hasn't arrived yet
        // (iCloud delivers files in no particular order) means this
        // snapshot isn't fully applied: leave the marker so the next pull
        // tries again. Nothing that did arrive is undone - the merge is
        // safe to repeat.
        if remote.isComplete {
            environment.state.lastPulledExportDate = remote.snapshot.exportedAt
        }

        // If the merge left this library identical to the snapshot, there's
        // nothing to push. If it didn't - a local page won, a local
        // tombstone isn't in the folder yet - the next push must go out, so
        // the marker is left alone. (It used to be set unconditionally,
        // which is how a device's own edits went unpushed.)
        if remote.isComplete, try buildSnapshot(context: context).signature == remote.snapshot.signature {
            environment.state.lastPushSignature = remote.snapshot.signature
        }
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
    private func performPush(against remote: RemoteLibrary?, context: ModelContext, workingDir: URL) throws {
        let snapshot = try buildSnapshot(context: context)
        let remoteIndex = remote?.index
        // A folder without index.json yet (empty, or format 1) always gets
        // one, even when nothing else changed - that's the migration.
        guard snapshot.signature != environment.state.lastPushSignature || remoteIndex == nil else { return }
        let pending = remote?.pending ?? []

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

        var index = snapshot.makeIndex()
        index.notebooks = index.notebooks.map { entry in
            pending.contains(entry.id) ? (remoteEntries[entry.id] ?? entry) : entry
        }
        try writeJSON(index, to: Self.indexURL(in: workingDir))

        environment.state.lastPushSignature = snapshot.signature
        // We authored this snapshot - don't turn around and re-apply it.
        // Unless something is still pending: then the next pull must look
        // again, and re-reading our own index is cheap and harmless.
        environment.state.lastPulledExportDate = pending.isEmpty ? snapshot.exportedAt : nil
    }

    // MARK: Reading the folder

    /// What a pull found in the folder.
    struct RemoteLibrary {
        /// Every folder, tombstone and notebook index entry, plus the
        /// `NotebookDTO`s that needed reading (new here, or changed).
        var snapshot: LibrarySnapshot
        /// Notebooks whose file the index promised but which was missing,
        /// unreadable, or didn't match its entry. Empty means complete.
        var pending: Set<UUID>
        /// nil for a format-1 `library.json`.
        var index: LibraryIndex?

        var isComplete: Bool { pending.isEmpty }
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

    static func notebookFileURL(for id: UUID, in workingDir: URL) -> URL {
        workingDir.appendingPathComponent("notebooks", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).json")
    }

    private func readRemote(workingDir: URL, context: ModelContext) throws -> RemoteLibrary? {
        let indexURL = Self.indexURL(in: workingDir)
        SyncFolder.ensureDownloaded(indexURL)
        if FileManager.default.fileExists(atPath: indexURL.path) {
            return try readIndexedLibrary(indexURL: indexURL, workingDir: workingDir, context: context)
        }

        // Format 1: the whole library in one file, from before the split.
        let legacyURL = Self.legacyLibraryURL(in: workingDir)
        SyncFolder.ensureDownloaded(legacyURL)
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return nil }
        let legacy: LibrarySnapshot = try readJSON(from: legacyURL)
        guard legacy.formatVersion <= librarySnapshotFormatVersion else {
            throw SyncFormatError.newerThanThisBuild(legacy.formatVersion)
        }
        return RemoteLibrary(snapshot: legacy, pending: [], index: nil)
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
        var pending: Set<UUID> = []
        for entry in index.notebooks where localSignatures[entry.id] != entry.contentSignature {
            let url = Self.notebookFileURL(for: entry.id, in: workingDir)
            SyncFolder.ensureDownloaded(url)
            guard FileManager.default.fileExists(atPath: url.path),
                  let notebook: NotebookDTO = try? readJSON(from: url) else {
                pending.insert(entry.id)   // not here yet, or not all here yet
                continue
            }
            // A file that doesn't match its entry is from another push -
            // older or newer. Either is safe to merge by page date; it just
            // means this snapshot isn't the one on disk, so come back.
            if notebook.contentSignature != entry.contentSignature { pending.insert(entry.id) }
            notebooks.append(notebook)
        }

        let snapshot = LibrarySnapshot(
            formatVersion: index.formatVersion,
            exportedAt: index.exportedAt,
            deviceName: index.deviceName,
            folders: index.folders,
            notebooks: notebooks,
            notebookIndex: index.notebooks,
            tombstones: index.tombstones
        )
        return RemoteLibrary(snapshot: snapshot, pending: pending, index: index)
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

    /// Brings in the files the merge is going to need. Imported PDFs and
    /// images are immutable and uniquely named, so "copy if missing" is
    /// exact. Drawing files change in place, so one is copied only when the
    /// merge decided its page comes from the folder - and if the local copy
    /// differs, that's the same-page conflict: the local ink goes to
    /// `trash/` first, never overwritten.
    private func pullPayloads(for remote: LibrarySnapshot, plan: MergePlan, from source: URL, to destination: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)

        for notebookDTO in remote.notebooks {
            for pageDTO in notebookDTO.pages {
                for name in Self.immutableFileNames(of: pageDTO) {
                    copyIfMissing(name, from: source, to: destination, downloadFirst: true)
                }
                guard let name = pageDTO.drawingFileRef, !name.isEmpty else { continue }
                switch plan.pages[pageDTO.id] {
                case .insert?, .remoteWins?:
                    let src = source.appendingPathComponent(name)
                    SyncFolder.ensureDownloaded(src)
                    guard fm.fileExists(atPath: src.path) else { continue }
                    let dst = destination.appendingPathComponent(name)
                    if fm.fileExists(atPath: dst.path) {
                        guard Self.filesDiffer(src, dst) else { continue }
                        DrawingStore.moveToTrash(dst, tag: "conflict")
                    }
                    try? fm.copyItem(at: src, to: dst)
                case .localWins?, .skip?, nil:
                    continue
                }
            }
        }
    }

    /// Puts this library's files in the folder. Immutable payloads are
    /// copied if missing; a drawing file replaces the folder's copy when it
    /// differs. Because a push always pulls first, a differing folder copy
    /// is one this device's page has already won against.
    private func pushPayloads(for snapshot: LibrarySnapshot, from source: URL, to destination: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)

        for notebookDTO in snapshot.notebooks {
            for pageDTO in notebookDTO.pages {
                for name in Self.immutableFileNames(of: pageDTO) {
                    copyIfMissing(name, from: source, to: destination, downloadFirst: false)
                }
                guard let name = pageDTO.drawingFileRef, !name.isEmpty else { continue }
                let src = source.appendingPathComponent(name)
                guard fm.fileExists(atPath: src.path) else { continue }
                let dst = destination.appendingPathComponent(name)
                if fm.fileExists(atPath: dst.path) {
                    guard Self.filesDiffer(src, dst) else { continue }
                    // Same discipline as DrawingStore.save: never leave the
                    // folder's copy half-written.
                    let staging = dst.appendingPathExtension("tmp")
                    try? fm.removeItem(at: staging)
                    guard (try? fm.copyItem(at: src, to: staging)) != nil else { continue }
                    _ = try? fm.replaceItemAt(dst, withItemAt: staging)
                } else {
                    try? fm.copyItem(at: src, to: dst)
                }
            }
        }
    }

    private func copyIfMissing(_ name: String, from source: URL, to destination: URL, downloadFirst: Bool) {
        let fm = FileManager.default
        let dst = destination.appendingPathComponent(name)
        guard !fm.fileExists(atPath: dst.path) else { return }
        let src = source.appendingPathComponent(name)
        if downloadFirst { SyncFolder.ensureDownloaded(src) }
        guard fm.fileExists(atPath: src.path) else { return }
        try? fm.copyItem(at: src, to: dst)
    }

    private static func immutableFileNames(of page: PageDTO) -> [String] {
        var names: [String] = []
        if let ref = page.backgroundRef, !ref.isEmpty { names.append(ref) }
        for doc in page.importedDocuments where !doc.fileRef.isEmpty { names.append(doc.fileRef) }
        return names
    }

    private static func filesDiffer(_ a: URL, _ b: URL) -> Bool {
        guard let dataA = try? Data(contentsOf: a), let dataB = try? Data(contentsOf: b) else { return true }
        return dataA != dataB
    }

    // MARK: Build snapshot from the model graph

    private func buildSnapshot(context: ModelContext) throws -> LibrarySnapshot {
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
                context.delete(page)   // the ink file stays on disk; orphan pruning is task 11
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

                case .skip?, nil:
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
        let base = environment.localFilesDirectory()
        for page in notebook.pages ?? [] {
            DrawingStore.moveToTrash(base.appendingPathComponent(DrawingStore.fileName(for: page.id)), tag: "deleted")
        }
    }
}
