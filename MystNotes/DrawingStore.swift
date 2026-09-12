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
struct DrawingStore {
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
        let record = fileURL(for: pageID)
        if let data = try? Data(contentsOf: record) {
            let hash = PayloadHash.sha256(of: data)
            if let cached = cachedDrawing(for: pageID, matching: hash) {
                if let map = try? StrokeCodec.decode(data).ids { ids.set(map, for: pageID) }
                return cached
            }
            if let (drawing, map) = try? StrokeCodec.decode(data) {
                ids.set(map, for: pageID)
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
        var map = StrokeIDMap()
        _ = try? save(drawing, pageID: pageID, ids: &map)
        ids.set(map, for: pageID)
        return drawing
    }

    /// Atomically writes the record, then the cache, and returns the file
    /// name to keep in `Page.drawingFileRef`.
    @discardableResult
    func save(_ drawing: PKDrawing, pageID: UUID) throws -> String {
        var map = ids.map(for: pageID)
        let name = try save(drawing, pageID: pageID, ids: &map)
        ids.set(map, for: pageID)
        return name
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
    private func writeAtomically(_ data: Data, to target: URL) throws {
        let staging = target.appendingPathExtension("tmp")
        let fm = FileManager.default
        try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try write(data, staging)
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: target)
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
    static func moveToTrash(_ file: URL, tag: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else { return }
        let trash = file.deletingLastPathComponent().appendingPathComponent("trash", isDirectory: true)
        try? fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let name = file.deletingPathExtension().lastPathComponent + "-\(stamp)-\(tag)." + file.pathExtension
        try? fm.moveItem(at: file, to: trash.appendingPathComponent(name))
    }
}

/// Stroke ids per page for the life of the process. A page's map is
/// restored from its record on load and consulted on save; the record
/// itself is the durable copy.
final class StrokeIDCache {
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
        maps[pageID] = map
    }

    func forget(_ pageID: UUID) {
        lock.lock(); defer { lock.unlock() }
        maps[pageID] = nil
    }
}
