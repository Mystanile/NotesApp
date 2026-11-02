import Foundation
import CryptoKit
#if canImport(UIKit)
import PencilKit
#endif

/// Reads and writes a page's ink. The one place ink bytes touch disk, and
/// the only code that knows what an ink file is.
///
/// Per page:
///
///     <id>.strokes        the record: the neutral format (`StrokeCodec`),
///                         which any reader can rebuild ink from and which
///                         carries the stable stroke ids. Synced.
///     <id>.drawing        a render cache: PencilKit's own `PKDrawing` bytes,
///                         used when it matches the record so this device
///                         never sees even the one-quantum drift a rebuild
///                         from the neutral format can carry (spec §5).
///                         Local only; regenerable.
///     <id>.drawing.key    the SHA-256 of the `.strokes` bytes the cache was
///                         made from. Mismatch means stale, and the cache is
///                         ignored.
///
/// Invariant 1 - never lose ink - for these files:
///
/// - **Saves are atomic**, strokes first, then cache, then key. A kill at
///   any point leaves the previous record intact and at worst a cache the
///   key no longer matches.
/// - **Unreadable files are quarantined, never overwritten.** A record that
///   doesn't decode is moved to `trash/` beside it; if the cache still
///   decodes, that's the ink, and the record is regenerated from it.
/// - **Older libraries just work.** A page from before the flip has only a
///   `.drawing`; it loads, and the record is written from it on the spot.
/// A page's ink record as it stands on disk - modification date and size -
/// to tell "the ink changed" from "something else on the page changed".
/// nil when there is no record.
nonisolated struct InkStamp: Equatable {
    var modified: Date
    var size: Int

    init?(of pageID: UUID, in store: DrawingStore) {
        let url = store.url(DrawingStore.fileName(for: pageID))
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? Int else { return nil }
        self.modified = modified
        self.size = size
    }
}

nonisolated struct DrawingStore {
    /// Resolves a payload file name to its on-disk URL.
    var url: (String) -> URL

    /// Writes bytes to a URL. Replaceable so a test can stop a write
    /// partway through and observe what is left on disk.
    var write: (Data, URL) throws -> Void = { try $0.write(to: $1) }

    /// Stroke ids per page, restored on load and consulted on save so a
    /// stroke keeps its id for as long as it exists.
    var ids: StrokeIDCache = .shared

    static var live: DrawingStore { DrawingStore(url: FileStore.url(for:)) }

    static func inDirectory(_ directory: URL, ids: StrokeIDCache = StrokeIDCache()) -> DrawingStore {
        DrawingStore(url: { directory.appendingPathComponent($0) }, ids: ids)
    }

    /// The record's file name - what `Page.drawingFileRef` holds after a
    /// save on this build.
    static func fileName(for pageID: UUID) -> String {
        "\(pageID.uuidString).strokes"
    }

    static func legacyFileName(for pageID: UUID) -> String {
        "\(pageID.uuidString).drawing"
    }

    func fileURL(for pageID: UUID) -> URL {
        url(Self.fileName(for: pageID))
    }

    private func cacheURL(for pageID: UUID) -> URL {
        url(Self.legacyFileName(for: pageID))
    }

    private func keyURL(for pageID: UUID) -> URL {
        url(Self.legacyFileName(for: pageID) + ".key")
    }

    /// When the page's ink last changed on disk, for "has it changed since
    /// I last looked" checks such as OCR staleness.
    func inkModifiedDate(forPageID pageID: UUID) -> Date? {
        for candidate in [fileURL(for: pageID), cacheURL(for: pageID)] {
            if let date = (try? candidate.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                return date
            }
        }
        return nil
    }

#if canImport(UIKit)
    /// The page's saved ink, or `nil` if there is none.
    func load(pageID: UUID) -> PKDrawing? {
        // A save can land between reading the record and storing its ids.
        // Everything below that writes acts only if none did.
        let landed = ids.savesLanded(for: pageID)
        let record = fileURL(for: pageID)
        if let data = try? Data(contentsOf: record) {
            let hash = PayloadHash.sha256(of: data)
            if let cached = cachedDrawing(for: pageID, matching: hash) {
                if let map = try? StrokeCodec.decode(data).ids { ids.ifNoSave(since: landed, for: pageID) { ids.set(map, for: pageID) } }
                return cached
            }
            if let (drawing, map) = try? StrokeCodec.decode(data) {
                ids.ifNoSave(since: landed, for: pageID) { ids.set(map, for: pageID) }
                try? writeCache(drawing, for: pageID, key: hash)
                return drawing
            }
            // The record is damaged. Keep it, and fall through to the cache,
            // which may well be the ink.
            Self.moveToTrash(record, tag: "unreadable")
        }

        // No readable record: a page from before the neutral format, or a
        // damaged one. The cache (or legacy file) is all there is.
        guard let drawing = legacyDrawing(for: pageID) else { return nil }
        ids.ifNoSave(since: landed, for: pageID) {
            var map = StrokeIDMap()
            _ = try? save(drawing, pageID: pageID, ids: &map)
            ids.set(map, for: pageID)
        }
        return drawing
    }

    /// The ink of the strokes carrying `ids` on `pageID`, read from the
    /// record alone, with their union bounds. For anything that only
    /// looks at another page's ink (graph greying, transclusion, export).
    ///
    /// Side-effect free: never touches `StrokeIDCache`, never writes the
    /// `.drawing` cache or its key, never migrates a legacy page, never
    /// moves a damaged record to `trash/`. A missing, legacy-only or
    /// damaged record, or ids that are all gone, return nil.
    nonisolated static func regionInk(pageID: UUID, ids: Set<UUID>) -> (strokes: [PKStroke], bounds: CGRect)? {
        DrawingStore.live.readRegionInk(pageID: pageID, ids: ids)
    }

    /// `regionInk(pageID:ids:)` against this store's directory.
    func readRegionInk(pageID: UUID, ids wanted: Set<UUID>) -> (strokes: [PKStroke], bounds: CGRect)? {
        guard !wanted.isEmpty,
              let data = try? Data(contentsOf: fileURL(for: pageID)),
              let (drawing, map) = try? StrokeCodec.decode(data) else { return nil }
        let indices = map.indices(of: wanted, in: drawing)
        guard !indices.isEmpty,
              let bounds = StrokeIDMap.bounds(of: wanted, in: drawing, map: map) else { return nil }
        return (indices.map { drawing.strokes[$0] }, bounds)
    }

    /// The same save, off the caller's thread.
    ///
    /// `nonisolated static` and capture-free by construction, exactly like
    /// `SyncEngine.runDetached` and for the same reason: this project
    /// builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so a
    /// `Task.detached` formed inside a main-actor type is inferred
    /// main-actor and runs on the main thread anyway.
    ///
    /// Encoding a page's strokes, compressing them and writing three files
    /// is tens of milliseconds on a real page. It ran on the main thread a
    /// second after every stroke and again on every page turn - invariant
    /// 10, and the reason the app stuttered while drawing.
    ///
    /// The caller is expected to stamp `Page.modifiedAt` only once this
    /// returns, so nothing reads the page's ink back before the bytes are
    /// there.
    nonisolated static func saveDetached(_ store: DrawingStore, _ drawing: PKDrawing,
                                         pageID: UUID) -> Task<Result<String, Error>, Never> {
        // The ticket is taken here, at the call, not when the task runs:
        // detached tasks start in any order.
        let ticket = store.ids.ticket(for: pageID)
        return Task.detached(priority: .userInitiated) {
            Result { try store.save(drawing, pageID: pageID, ticket: ticket) }
        }
    }

    /// Copies one page's ink to another page, off the caller's thread, and
    /// returns the copy's file name (nil when the source has no ink). The
    /// copy is saved under an empty id map, so its strokes get their own
    /// ids: an id names one stroke, never one in each of two pages
    /// (invariant 6).
    nonisolated static func copyDetached(_ store: DrawingStore, from source: UUID,
                                         to destination: UUID) -> Task<Result<String?, Error>, Never> {
        Task.detached(priority: .userInitiated) {
            Result { try store.load(pageID: source).map { try store.save($0, pageID: destination) } }
        }
    }

    /// Atomically writes the record, then the cache, and returns the file
    /// name to keep in `Page.drawingFileRef`.
    @discardableResult
    func save(_ drawing: PKDrawing, pageID: UUID) throws -> String {
        try save(drawing, pageID: pageID, ticket: ids.ticket(for: pageID))
    }

    /// A save that loses to any save of the same page asked for after it,
    /// whichever runs first. Two background saves of one page used to land
    /// in whatever order their threads finished, so an older autosave
    /// could overwrite newer ink. A skipped save still reports the record's
    /// name: the newer save already put the newer ink there.
    func save(_ drawing: PKDrawing, pageID: UUID, ticket: Int) throws -> String {
        try ids.inOrder(ticket, for: pageID) {
            var map = ids.map(for: pageID)
            _ = try save(drawing, pageID: pageID, ids: &map)
            ids.set(map, for: pageID)
        }
        return Self.fileName(for: pageID)
    }

    private func save(_ drawing: PKDrawing, pageID: UUID, ids map: inout StrokeIDMap) throws -> String {
        let data = StrokeCodec.encode(drawing, ids: &map)
        let record = fileURL(for: pageID)
        try writeAtomically(data, to: record)
        try? writeCache(drawing, for: pageID, key: PayloadHash.sha256(of: data))
        return record.lastPathComponent
    }

    private func writeCache(_ drawing: PKDrawing, for pageID: UUID, key: String) throws {
        try writeAtomically(drawing.dataRepresentation(), to: cacheURL(for: pageID))
        try writeAtomically(Data(key.utf8), to: keyURL(for: pageID))
    }

    /// The cache, if it was made from the record whose hash is `hash`.
    private func cachedDrawing(for pageID: UUID, matching hash: String) -> PKDrawing? {
        guard let key = try? String(contentsOf: keyURL(for: pageID), encoding: .utf8), key == hash,
              let data = try? Data(contentsOf: cacheURL(for: pageID)),
              let drawing = try? PKDrawing(data: data),
              !drawing.strokes.isEmpty || data.starts(with: Self.archiveHeader) else { return nil }
        return drawing
    }

    /// A `.drawing` file trusted on its own: what a page had before the
    /// neutral format, or the cache after a damaged record.
    ///
    /// `PKDrawing(data:)` throws on truncation and most garbage, but a short
    /// run of arbitrary bytes can parse as a drawing with zero strokes, so a
    /// zero-stroke result is trusted only if the bytes start the way
    /// PencilKit's own archives do. Anything else is quarantined.
    private func legacyDrawing(for pageID: UUID) -> PKDrawing? {
        let file = cacheURL(for: pageID)
        guard let data = try? Data(contentsOf: file) else { return nil }
        if let drawing = try? PKDrawing(data: data),
           !drawing.strokes.isEmpty || data.starts(with: Self.archiveHeader) {
            return drawing
        }
        Self.moveToTrash(file, tag: "unreadable")
        try? FileManager.default.removeItem(at: keyURL(for: pageID))
        return nil
    }

    /// The leading bytes of a PencilKit archive, taken from the framework
    /// itself so the check tracks whatever version is running.
    private static let archiveHeader: Data = PKDrawing().dataRepresentation().prefix(4)
#endif

    /// Stage then rename, so the target is never partially written.
    ///
    /// The staging name is unique per write. Saves now happen off the main
    /// thread, so two of them for the same page (an autosave landing as a
    /// page turn saves) can be in flight at once, and a shared staging path
    /// would let one write's fragment be renamed into place by the other.
    private func writeAtomically(_ data: Data, to target: URL) throws {
        let staging = target.appendingPathExtension("\(UUID().uuidString).tmp")
        let fm = FileManager.default
        try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try write(data, staging)
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: staging)
            } else {
                do {
                    try fm.moveItem(at: staging, to: target)
                } catch CocoaError.fileWriteFileExists {
                    // Another save of the same page landed between the
                    // check and the move: replace its file with ours.
                    _ = try fm.replaceItemAt(target, withItemAt: staging)
                }
            }
        } catch {
            // Only the never-committed fragment is discarded; the target
            // was not touched.
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    // MARK: Trash

    /// What deleting a page does to its ink: the record and the cache go
    /// to `trash/`; the key is just a cache key and is dropped.
    func trashDrawing(forPageID pageID: UUID) {
        Self.moveToTrash(fileURL(for: pageID), tag: "deleted")
        Self.moveToTrash(cacheURL(for: pageID), tag: "deleted")
        try? FileManager.default.removeItem(at: keyURL(for: pageID))
        ids.forget(pageID)
    }

    /// Same for any other payload this page owned (an imported PDF or
    /// image no remaining page uses).
    func trashPayload(named name: String) {
        Self.moveToTrash(url(name), tag: "deleted")
    }

    /// Moves a payload into `trash/` beside it instead of deleting it
    /// (invariant 3), under a name that can't collide with a later copy of
    /// the same page. `tag` says why it went there - "unreadable",
    /// "conflict", "deleted" - so the user can tell the entries apart.
    /// Returns whether the file is out of the way: true if moved or already
    /// gone. A failure is logged with its error and the file is left alone.
    @discardableResult
    static func moveToTrash(_ file: URL, tag: String) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else { return true }
        if tag != "deleted" { AppLog.note("trash", "\(tag): \(file.lastPathComponent)") }
        let trash = file.deletingLastPathComponent().appendingPathComponent("trash", isDirectory: true)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let name = file.deletingPathExtension().lastPathComponent + "-\(stamp)-\(tag)." + file.pathExtension
        do {
            try fm.createDirectory(at: trash, withIntermediateDirectories: true)
            try fm.moveItem(at: file, to: trash.appendingPathComponent(name))
            return true
        } catch {
            AppLog.note("trash", "move failed: \(file.lastPathComponent): \(error)")
            return false
        }
    }
}

/// Stroke ids per page for the life of the process. A page's map is
/// restored from its record on load and consulted on save; the record
/// itself is the durable copy.
nonisolated final class StrokeIDCache {
    static let shared = StrokeIDCache()
    private let lock = NSLock()
    private var maps: [UUID: StrokeIDMap] = [:]

    init() {}

    func map(for pageID: UUID) -> StrokeIDMap {
        lock.lock(); defer { lock.unlock() }
        return maps[pageID] ?? StrokeIDMap()
    }

    func set(_ map: StrokeIDMap, for pageID: UUID) {
        lock.lock(); defer { lock.unlock() }
        var map = map
        if let previous = maps[pageID] { map.inheritDeparted(from: previous) }
        maps[pageID] = map
    }

    func forget(_ pageID: UUID) {
        lock.lock(); defer { lock.unlock() }
        maps[pageID] = nil
    }

    // Save order: `issued` under `lock`, `written` under `writeLock`.
    private var issued: [UUID: Int] = [:]
    private var written: [UUID: Int] = [:]
    // ponytail: one write lock for every page, so saves of two pages wait
    // on each other (tens of ms each). Per-page locks if that ever shows
    // up in the stall log.
    private let writeLock = NSLock()

    /// Numbers a save of `pageID` when it is asked for.
    func ticket(for pageID: UUID) -> Int {
        lock.lock(); defer { lock.unlock() }
        let next = (issued[pageID] ?? 0) + 1
        issued[pageID] = next
        return next
    }

    /// Runs `write` unless a save of the same page with a later ticket
    /// already landed. Holding the lock for the whole write also keeps two
    /// saves from reading the same id map and dropping each other's ids
    /// (invariant 6).
    func inOrder(_ ticket: Int, for pageID: UUID, _ write: () throws -> Void) rethrows {
        writeLock.lock(); defer { writeLock.unlock() }
        guard ticket > (written[pageID] ?? 0) else { return }
        try write()
        written[pageID] = ticket
    }

    /// Where the page's saves stand now, for `ifNoSave(since:)`.
    func savesLanded(for pageID: UUID) -> Int {
        writeLock.lock(); defer { writeLock.unlock() }
        return written[pageID] ?? 0
    }

    /// Runs `update` only if no save of the page landed since `landed`.
    /// A load that read an older record must not put its ids or its
    /// migrated record over what a newer save wrote.
    func ifNoSave(since landed: Int, for pageID: UUID, _ update: () throws -> Void) rethrows {
        writeLock.lock(); defer { writeLock.unlock() }
        guard (written[pageID] ?? 0) == landed else { return }
        try update()
    }
}
