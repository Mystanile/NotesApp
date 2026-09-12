import Foundation
import Combine
import SwiftData

/// Folder-based library sync - the free-account alternative to CloudKit.
///
/// The whole library is serialized to `<sync folder>/Mystnotes/library.json`
/// and every payload file (drawings, imported PDFs/images) is copied into
/// `<sync folder>/Mystnotes/files/`. iCloud Drive (or whatever service backs
/// the chosen folder) moves those between devices; this engine only reads and
/// writes local files.
///
/// Merge is per-notebook last-writer-wins on `Notebook.modifiedAt`; folders
/// are a flat upsert; deletions travel as `Tombstone`s. Two devices that both
/// edit the *same* notebook while offline will keep only the newer edit.
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
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
    private var jsonDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func run(pull: Bool, push: Bool) throws {
        let context = ModelContext(container)
        try environment.withFolder { folder in
            let workingDir = try SyncFolder.workingDirectory(in: folder)
            // A push always pulls first: it folds in whatever another device
            // wrote so the snapshot we're about to overwrite isn't stale.
            if pull || push { try performPull(context: context, workingDir: workingDir) }
            if push { try performPush(context: context, workingDir: workingDir) }
        }
    }

    // MARK: Pull

    private func performPull(context: ModelContext, workingDir: URL) throws {
        guard let remote = try readSnapshot(workingDir: workingDir) else { return }

        if let lastPulled = environment.state.lastPulledExportDate, remote.exportedAt <= lastPulled {
            return  // already applied this snapshot
        }

        copyFiles(remote.referencedFileNames,
                  from: workingDir.appendingPathComponent("files", isDirectory: true),
                  to: environment.localFilesDirectory(),
                  downloadFirst: true)

        try apply(remote, context: context)

        SyncTombstones.merge(remote.tombstones, into: environment.state)
        environment.state.lastPulledExportDate = remote.exportedAt
        // Our library now matches this snapshot; only push again if something
        // actually diverges from it (e.g. a local tombstone not in `remote`).
        if SyncTombstones.load(from: environment.state).allSatisfy({ stone in remote.tombstones.contains(stone) }) {
            environment.state.lastPushSignature = remote.signature
        }
    }

    // MARK: Push

    private func performPush(context: ModelContext, workingDir: URL) throws {
        let snapshot = try buildSnapshot(context: context)
        guard snapshot.signature != environment.state.lastPushSignature else { return }

        copyFiles(snapshot.referencedFileNames,
                  from: environment.localFilesDirectory(),
                  to: workingDir.appendingPathComponent("files", isDirectory: true),
                  downloadFirst: false)

        try writeSnapshot(snapshot, workingDir: workingDir)

        environment.state.lastPushSignature = snapshot.signature
        // We authored this snapshot - don't turn around and re-apply it.
        environment.state.lastPulledExportDate = snapshot.exportedAt
    }

    // MARK: Snapshot <-> file

    private func readSnapshot(workingDir: URL) throws -> LibrarySnapshot? {
        let url = workingDir.appendingPathComponent("library.json")
        SyncFolder.ensureDownloaded(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        var coordinationError: NSError?
        var decoded: LibrarySnapshot?
        var thrown: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            do {
                let data = try Data(contentsOf: readURL)
                decoded = try jsonDecoder.decode(LibrarySnapshot.self, from: data)
            } catch {
                thrown = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let thrown { throw thrown }
        return decoded
    }

    private func writeSnapshot(_ snapshot: LibrarySnapshot, workingDir: URL) throws {
        let url = workingDir.appendingPathComponent("library.json")
        let data = try jsonEncoder.encode(snapshot)

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

    // MARK: Payload files

    /// Copies each named file from `source` to `destination` when the
    /// destination is missing or older. Best-effort - a file that isn't
    /// present on the source side yet is just skipped this round.
    private func copyFiles(_ names: Set<String>, from source: URL, to destination: URL, downloadFirst: Bool) {
        let fm = FileManager.default
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)

        for name in names {
            let src = source.appendingPathComponent(name)
            if downloadFirst { SyncFolder.ensureDownloaded(src) }
            guard fm.fileExists(atPath: src.path) else { continue }

            let dst = destination.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) {
                let srcDate = (try? src.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let dstDate = (try? dst.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                guard srcDate > dstDate else { continue }
                try? fm.removeItem(at: dst)
            }
            try? fm.copyItem(at: src, to: dst)
        }
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
                folderID: notebook.folder?.id, pages: pageDTOs, links: links
            )
        }

        return LibrarySnapshot(
            exportedAt: environment.now(),
            deviceName: environment.deviceName,
            folders: folderDTOs,
            notebooks: notebookDTOs,
            tombstones: SyncTombstones.load(from: environment.state)
        )
    }

    // MARK: Apply snapshot into the model graph

    private func apply(_ remote: LibrarySnapshot, context: ModelContext) throws {
        var folderByID = Dictionary(
            (try context.fetch(FetchDescriptor<Folder>())).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var notebookByID = Dictionary(
            (try context.fetch(FetchDescriptor<Notebook>())).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // 1. Deletions.
        for stone in remote.tombstones {
            switch stone.kind {
            case .notebook:
                if let notebook = notebookByID[stone.id], notebook.modifiedAt <= stone.deletedAt {
                    deleteFiles(for: notebook)
                    context.delete(notebook)
                    notebookByID[stone.id] = nil
                }
            case .folder:
                if let folder = folderByID[stone.id] {
                    context.delete(folder)   // cascades to subfolders / notebooks
                    folderByID[stone.id] = nil
                }
            }
        }
        let tombstonedIDs = Set(remote.tombstones.map(\.id))

        // 2. Folders: upsert, then wire up parents once all exist.
        for dto in remote.folders where !tombstonedIDs.contains(dto.id) {
            if let folder = folderByID[dto.id] {
                folder.name = dto.name
            } else {
                let folder = Folder(name: dto.name)
                folder.id = dto.id
                context.insert(folder)
                folderByID[dto.id] = folder
            }
        }
        for dto in remote.folders where !tombstonedIDs.contains(dto.id) {
            folderByID[dto.id]?.parentFolder = dto.parentID.flatMap { folderByID[$0] }
        }

        // 3. Notebooks: last-writer-wins by modifiedAt.
        let links = try context.fetch(FetchDescriptor<Link>())
        let docs = try context.fetch(FetchDescriptor<ImportedDocument>())
        for dto in remote.notebooks where !tombstonedIDs.contains(dto.id) {
            if let existing = notebookByID[dto.id] {
                guard dto.modifiedAt > existing.modifiedAt else { continue }
                rebuild(existing, from: dto, folderByID: folderByID,
                        existingLinks: links, existingDocs: docs, context: context)
            } else {
                let notebook = Notebook(title: dto.title)
                notebook.id = dto.id
                context.insert(notebook)
                notebookByID[dto.id] = notebook
                rebuild(notebook, from: dto, folderByID: folderByID,
                        existingLinks: links, existingDocs: docs, context: context)
            }
        }

        try context.save()
    }

    /// Replaces a notebook's scalar fields and its entire page tree from the
    /// DTO. Page ids are stable, so a page's `<id>.drawing` file still lines
    /// up after the rebuild.
    private func rebuild(_ notebook: Notebook,
                         from dto: NotebookDTO,
                         folderByID: [UUID: Folder],
                         existingLinks: [Link],
                         existingDocs: [ImportedDocument],
                         context: ModelContext) {
        notebook.title = dto.title
        notebook.coverStyle = dto.coverStyle
        notebook.createdAt = dto.createdAt
        notebook.modifiedAt = dto.modifiedAt
        notebook.folder = dto.folderID.flatMap { folderByID[$0] }

        let oldPages = notebook.pages ?? []
        let oldPageIDs = Set(oldPages.map(\.id))
        for link in existingLinks where oldPageIDs.contains(link.sourcePageID) || oldPageIDs.contains(link.destinationPageID) {
            context.delete(link)
        }
        for doc in existingDocs where doc.page.map({ oldPageIDs.contains($0.id) }) ?? false {
            context.delete(doc)
        }
        for page in oldPages { context.delete(page) }
        notebook.pages = []

        for pageDTO in dto.pages.sorted(by: { $0.index < $1.index }) {
            let page = Page(index: pageDTO.index, type: pageDTO.type, template: pageDTO.template, notebook: notebook)
            page.id = pageDTO.id
            page.drawingFileRef = pageDTO.drawingFileRef
            page.backgroundRef = pageDTO.backgroundRef
            page.recognizedTextCache = pageDTO.recognizedTextCache
            page.ocrUpdatedAt = pageDTO.ocrUpdatedAt
            page.modifiedAt = pageDTO.modifiedAt
            context.insert(page)
            notebook.pages?.append(page)

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
        }

        for linkDTO in dto.links {
            let link = Link(sourcePageID: linkDTO.sourcePageID, destinationPageID: linkDTO.destinationPageID)
            link.id = linkDTO.id
            link.anchorX = linkDTO.anchorX
            link.anchorY = linkDTO.anchorY
            link.anchorWidth = linkDTO.anchorWidth
            link.anchorHeight = linkDTO.anchorHeight
            context.insert(link)
        }
    }

    private func deleteFiles(for notebook: Notebook) {
        let fm = FileManager.default
        let base = environment.localFilesDirectory()
        for page in notebook.pages ?? [] {
            try? fm.removeItem(at: base.appendingPathComponent("\(page.id.uuidString).drawing"))
        }
    }
}
