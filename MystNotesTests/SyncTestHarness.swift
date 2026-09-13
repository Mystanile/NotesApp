import Foundation
import SwiftData
import XCTest
@testable import Mystnotes

/// A clock the harness advances by hand. Every timestamp the engine or the
/// harness records comes from here, so two "devices" acting in the same
/// test run are spaced the way real devices are (minutes apart), not
/// microseconds apart, and a test's dates are exact whole seconds that
/// survive the snapshot's millisecond encoding unchanged.
///
/// It starts at the real wall clock, not an arbitrary date: the engine
/// compares file modification dates (which the OS stamps in real time)
/// against `now()` for the orphan grace period, so the two must live in
/// the same time domain.
final class SyncTestClock {
    private(set) var now: Date

    init(start: Date = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))) {
        now = start
    }

    @discardableResult
    func advance(seconds: TimeInterval = 60) -> Date {
        now = now.addingTimeInterval(seconds)
        return now
    }
}

/// In-memory stand-in for `UserDefaults`-backed sync bookkeeping. One per
/// simulated device.
final class InMemorySyncStateStore: SyncStateStore {
    var lastAppliedRemoteSignature: String?
    var lastPushSignature: String = ""
    var tombstonesData: Data?
}

/// The mirror's markers, sharing the device's tombstones - as
/// `MirrorSyncStateStore` does in the app.
final class InMemoryMirrorStateStore: SyncStateStore {
    private let device: InMemorySyncStateStore
    init(sharingTombstonesWith device: InMemorySyncStateStore) { self.device = device }
    var lastAppliedRemoteSignature: String?
    var lastPushSignature: String = ""
    var tombstonesData: Data? {
        get { device.tombstonesData }
        set { device.tombstonesData = newValue }
    }
}

/// One simulated device: its own SwiftData store, its own payload files
/// directory and its own sync bookkeeping, sharing a sync folder with the
/// other devices in the test. Drives `SyncRunner` exactly the way the app
/// does ("Sync Now" = pull then push).
@MainActor
final class SyncTestDevice {
    let name: String
    let container: ModelContainer
    let context: ModelContext
    let filesDirectory: URL
    let state = InMemorySyncStateStore()
    /// Planted "conflict versions": file URL -> other versions of it, as
    /// `NSFileVersion` would report. Resolved ones are recorded.
    var plantedConflicts: [URL: [URL]] = [:]
    private(set) var resolvedConflicts: [URL] = []
    var indexHistoryLimit = 50
    var orphanGracePeriod: TimeInterval = 7 * 24 * 60 * 60

    private let syncFolder: URL
    private let clock: SyncTestClock

    init(name: String, syncFolder: URL, clock: SyncTestClock, root: URL) throws {
        self.name = name
        self.syncFolder = syncFolder
        self.clock = clock

        let deviceRoot = root.appendingPathComponent(name, isDirectory: true)
        filesDirectory = deviceRoot.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)

        // On disk, not in memory: the closest thing to the real app's store,
        // and it leaves the door open to reopen it in a durability test.
        let schema = Schema([
            Folder.self, Notebook.self, Page.self, TypedTextBlock.self,
            ImportedDocument.self, Link.self, Sticker.self
        ])
        let configuration = ModelConfiguration(
            name,
            schema: schema,
            url: deviceRoot.appendingPathComponent("store.sqlite"),
            cloudKitDatabase: .none
        )
        container = try ModelContainer(for: schema, configurations: [configuration])
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    /// This device's local mirror (`Documents/Library/` in the app).
    lazy var mirrorState = InMemoryMirrorStateStore(sharingTombstonesWith: state)
    var mirrorDirectory: URL { filesDirectory.appendingPathComponent("Library", isDirectory: true) }

    var mirrorEnvironment: SyncEnvironment {
        SyncEnvironment(
            withFolder: { [mirrorDirectory] body in
                try FileManager.default.createDirectory(at: mirrorDirectory, withIntermediateDirectories: true)
                try body(mirrorDirectory)
            },
            localFilesDirectory: { [filesDirectory] in filesDirectory },
            state: mirrorState,
            deviceName: name,
            now: { [clock] in clock.now },
            indexHistoryLimit: 20,
            payloadsAreLocal: true
        )
    }

    /// What the app does after every debounced push, folder or not.
    func writeMirror() throws {
        try SyncRunner(container: container, environment: mirrorEnvironment).run(pull: false, push: true)
    }

    var environment: SyncEnvironment {
        SyncEnvironment(
            withFolder: { [syncFolder] body in try body(syncFolder) },
            localFilesDirectory: { [filesDirectory] in filesDirectory },
            state: state,
            deviceName: name,
            now: { [clock] in clock.now },
            indexHistoryLimit: indexHistoryLimit,
            orphanGracePeriod: orphanGracePeriod,
            conflictVersions: { [unowned self] url in self.plantedConflicts[url.standardizedFileURL] ?? [] },
            resolveConflicts: { [unowned self] url in
                if self.plantedConflicts.removeValue(forKey: url.standardizedFileURL) != nil { self.resolvedConflicts.append(url) }
            }
        )
    }

    // MARK: Acting like the app

    /// Equivalent of "Sync Now" in Settings.
    func sync() throws {
        try SyncRunner(container: container, environment: environment).run(pull: true, push: true)
    }

    /// Creates a notebook with `pageCount` pages, each with its own ink
    /// file, the way `LibraryView` + `MystNotesDetailView` would.
    func createNotebook(title: String, pageCount: Int) throws -> Notebook {
        let notebook = Notebook(title: title)
        notebook.createdAt = clock.now
        context.insert(notebook)
        for index in 0..<pageCount {
            let page = Page(index: index, notebook: notebook)
            context.insert(page)
            notebook.pages?.append(page)
            try writeInk(Data("\(title) page \(index + 1) original".utf8), to: page)
            page.modifiedAt = clock.now
        }
        notebook.modifiedAt = clock.now
        try context.save()
        return notebook
    }

    /// Mirrors `MystNotesDetailView.save(_:to:)`: write the drawing file,
    /// point the page at it, mark the page modified, save.
    func edit(page: Page, ink: Data) throws {
        try writeInk(ink, to: page)
        page.markModified(at: clock.now)
        try context.save()
    }

    func createFolder(name: String, parent: Folder? = nil) throws -> Folder {
        let folder = Folder(name: name, parentFolder: parent)
        context.insert(folder)
        try context.save()
        return folder
    }

    func addTextBlock(to page: Page, content: String) throws {
        let block = TypedTextBlock(content: content, page: page)
        context.insert(block)
        page.textBlocks?.append(block)
        page.markModified(at: clock.now)
        try context.save()
    }

    func addLink(from source: Page, to destination: Page) throws -> Link {
        let link = Link(sourcePageID: source.id, destinationPageID: destination.id)
        context.insert(link)
        source.markModified(at: clock.now)
        try context.save()
        return link
    }

    /// Everything the index says, as plain values, for comparing a library
    /// before and after a rebuild.
    struct Shape: Equatable {
        var folders: [String]           // "name<parent name or ->"
        var notebooks: [String]         // "title@folder:<page ids in index order>"
        var textBlocks: [String]        // "pageID:content"
        var links: [String]             // "source->destination"
    }

    func shape() throws -> Shape {
        let folders = try context.fetch(FetchDescriptor<Folder>())
            .map { "\($0.name)<\($0.parentFolder?.name ?? "-")" }.sorted()
        let notebooks = try context.fetch(FetchDescriptor<Notebook>()).map { notebook in
            let pages = (notebook.pages ?? []).sorted { $0.index < $1.index }.map(\.id.uuidString)
            return "\(notebook.title)@\(notebook.folder?.name ?? "-"):\(pages.joined(separator: ","))"
        }.sorted()
        let blocks = try context.fetch(FetchDescriptor<TypedTextBlock>())
            .map { "\($0.page?.id.uuidString ?? "-"):\($0.content)" }.sorted()
        let links = try context.fetch(FetchDescriptor<Link>())
            .map { "\($0.sourcePageID)->\($0.destinationPageID)" }.sorted()
        return Shape(folders: folders, notebooks: notebooks, textBlocks: blocks, links: links)
    }

    /// Mirrors `LibraryView.deleteNotebook`.
    func deleteNotebook(_ notebook: Notebook) throws {
        SyncTombstones.merge([Tombstone(kind: .notebook, id: notebook.id, deletedAt: clock.now)], into: state)
        context.delete(notebook)
        try context.save()
    }

    /// Mirrors `LibraryView.applyRename`.
    func rename(_ notebook: Notebook, to title: String) throws {
        notebook.title = title
        notebook.markSettingsModified(at: clock.now)
        try context.save()
    }

    /// Mirrors `MystNotesDetailView.deletePage`: trash the ink, drop the
    /// page, re-index the rest, record a page tombstone.
    func deletePage(_ page: Page) throws {
        guard let notebook = page.notebook else { return }
        DrawingStore.inDirectory(filesDirectory).trashDrawing(forPageID: page.id)
        notebook.pages?.removeAll { $0.id == page.id }
        context.delete(page)
        SyncTombstones.merge([Tombstone(kind: .page, id: page.id, deletedAt: clock.now)], into: state)
        let remaining = (notebook.pages ?? []).sorted { $0.index < $1.index }
        for (newIndex, remainingPage) in remaining.enumerated() where remainingPage.index != newIndex {
            remainingPage.index = newIndex
            remainingPage.markModified(at: clock.now)
        }
        notebook.modifiedAt = clock.now
        try context.save()
    }

    /// Every file under this device's `files/trash/`, for asserting that
    /// losing ink was kept rather than destroyed.
    func trashedInk() -> [Data] {
        let trash = filesDirectory.appendingPathComponent("trash", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: trash.path) else { return [] }
        return names.compactMap { try? Data(contentsOf: trash.appendingPathComponent($0)) }
    }

    private func writeInk(_ data: Data, to page: Page) throws {
        let url = filesDirectory.appendingPathComponent("\(page.id.uuidString).drawing")
        try data.write(to: url)
        page.drawingFileRef = url.lastPathComponent
    }

    // MARK: Inspecting the result

    func notebook(id: UUID) throws -> Notebook? {
        let descriptor = FetchDescriptor<Notebook>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }

    /// Pages sorted by `index`, or `nil` if the notebook is missing.
    func pages(ofNotebook id: UUID) throws -> [Page]? {
        guard let notebook = try notebook(id: id) else { return nil }
        return (notebook.pages ?? []).sorted { $0.index < $1.index }
    }

    /// The ink bytes this device holds for the page whose *identity* is
    /// `pageID` - looked up by id, not by model object, because a rebuild
    /// replaces the objects.
    func ink(forPageID pageID: UUID) -> Data? {
        try? Data(contentsOf: filesDirectory.appendingPathComponent("\(pageID.uuidString).drawing"))
    }
}

/// Shared temp sync folder plus the devices attached to it.
@MainActor
final class SyncTestHarness {
    let root: URL
    let syncFolder: URL
    let clock = SyncTestClock()

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncTests-\(UUID().uuidString)", isDirectory: true)
        syncFolder = root.appendingPathComponent("SyncFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: syncFolder, withIntermediateDirectories: true)
    }

    func makeDevice(_ name: String, indexHistoryLimit: Int = 50) throws -> SyncTestDevice {
        let device = try SyncTestDevice(name: name, syncFolder: syncFolder, clock: clock, root: root)
        device.indexHistoryLimit = indexHistoryLimit
        return device
    }

    /// `<sync folder>/Mystnotes/`, where the engine writes.
    var workingDirectory: URL {
        syncFolder.appendingPathComponent("Mystnotes", isDirectory: true)
    }

    func folderFile(_ relativePath: String) -> URL {
        workingDirectory.appendingPathComponent(relativePath)
    }

    func folderFileExists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: folderFile(relativePath).path)
    }

    /// Names of the files in `index-history/`, oldest first.
    func historyFileNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folderFile("index-history").path)) ?? []).sorted()
    }

    func readTombstoneFile() throws -> TombstoneFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = SnapshotDates.decoding
        return try decoder.decode(TombstoneFile.self, from: Data(contentsOf: folderFile("tombstones.json")))
    }

    func readIndex() throws -> LibraryIndex {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = SnapshotDates.decoding
        return try decoder.decode(LibraryIndex.self, from: Data(contentsOf: folderFile("index.json")))
    }

    /// Encodes the way the engine does, for planting files in the folder.
    func writeJSON<T: Encodable>(_ value: T, to relativePath: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = SnapshotDates.encoding
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = folderFile(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url)
    }

    /// The page as the folder currently describes it, from whichever
    /// `notebooks/*.json` contains it.
    func pageInFolder(_ pageID: UUID) -> PageDTO? {
        let dir = folderFile("notebooks")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = SnapshotDates.decoding
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".json") {
            if let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
               let notebook = try? decoder.decode(NotebookDTO.self, from: data),
               let page = notebook.pages.first(where: { $0.id == pageID }) {
                return page
            }
        }
        return nil
    }

    /// Ink bytes for a page as the folder's notebook file points at them
    /// (`files/<hash>.drawing`), falling back to the pre-content-addressing
    /// name.
    func inkInFolder(forPageID pageID: UUID) -> Data? {
        if let page = pageInFolder(pageID), let hash = page.drawingHash, let ref = page.drawingFileRef {
            return try? Data(contentsOf: folderFile("files/\(PayloadHash.folderName(hash: hash, localName: ref))"))
        }
        return try? Data(contentsOf: folderFile("files/\(pageID.uuidString).drawing"))
    }

    /// Names in the folder's `files/trash/` and `notebooks/trash/`.
    func folderTrashNames() -> [String] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: folderFile("files/trash").path)) ?? []
        let notebooks = (try? fm.contentsOfDirectory(atPath: folderFile("notebooks/trash").path)) ?? []
        return (files + notebooks).sorted()
    }

    func folderPayloadNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folderFile("files").path)) ?? [])
            .filter { !$0.hasPrefix(".") && $0 != "trash" }.sorted()
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }
}
