import Foundation
import SwiftData
import XCTest
@testable import Mystnotes

/// A clock the harness advances by hand. Every timestamp the engine or the
/// harness records comes from here, so two "devices" acting in the same
/// test run are spaced the way real devices are (minutes apart), not
/// microseconds apart. That matters because `library.json` stores dates as
/// ISO-8601 whole seconds: actions inside one wall-clock second would
/// compare truncated against untruncated values and make results depend on
/// test timing.
final class SyncTestClock {
    private(set) var now: Date

    init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
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
    var lastPulledExportDate: Date?
    var lastPushSignature: String = ""
    var tombstonesData: Data?
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

    var environment: SyncEnvironment {
        SyncEnvironment(
            withFolder: { [syncFolder] body in try body(syncFolder) },
            localFilesDirectory: { [filesDirectory] in filesDirectory },
            state: state,
            deviceName: name,
            now: { [clock] in clock.now }
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
        }
        notebook.modifiedAt = clock.now
        try context.save()
        return notebook
    }

    /// Mirrors `MystNotesDetailView.save(_:to:)`: write the drawing file,
    /// point the page at it, bump the notebook's `modifiedAt`, save.
    func edit(page: Page, ink: Data) throws {
        try writeInk(ink, to: page)
        page.notebook?.modifiedAt = clock.now
        try context.save()
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

    func makeDevice(_ name: String) throws -> SyncTestDevice {
        try SyncTestDevice(name: name, syncFolder: syncFolder, clock: clock, root: root)
    }

    /// Ink bytes for a page as they sit in the shared folder's `files/`.
    func inkInFolder(forPageID pageID: UUID) -> Data? {
        let url = syncFolder
            .appendingPathComponent("Mystnotes", isDirectory: true)
            .appendingPathComponent("files", isDirectory: true)
            .appendingPathComponent("\(pageID.uuidString).drawing")
        return try? Data(contentsOf: url)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }
}
