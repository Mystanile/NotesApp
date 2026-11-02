import Foundation

/// One line of text Vision read in an imported photo. `x`/`y`/`width`/`height`
/// are normalized to the image, origin top-left (already flipped from
/// Vision's bottom-left).
nonisolated struct ImageTextLine: Codable, Hashable, Sendable {
    var text: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

/// The text recognized in one imported image file.
nonisolated struct ImageTextEntry: Codable, Hashable, Sendable {
    var fileRef: String
    var text: String
    var lines: [ImageTextLine]
}

/// Text read from imported photos, for search. Derived, local-only data: it
/// lives in `Library/Caches/ImageText/<hash of the file name>.json`, never
/// syncs, and can be deleted by the system and rebuilt by `SearchIndexer`.
///
/// Keyed by the imported file's name. Imported files are content-addressed
/// (an edit writes a new file), so a name's text can never go stale. Writes
/// overwrite atomically; nothing here ever removes a file. An entry with
/// empty text is meaningful: "looked, found nothing", so the indexer does
/// not retry a photo of a landscape forever.
///
/// Safe from any thread. Lookups are memoized, because search asks for every
/// page's photos on every keystroke.
nonisolated final class ImageTextCache: @unchecked Sendable {
    static let shared = ImageTextCache(directory: ImageTextCache.defaultDirectory)

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ImageText", isDirectory: true)
    }

    let directory: URL
    private let lock = NSLock()
    private var memo: [String: ImageTextEntry] = [:]
    private var knownMissing: Set<String> = []

    init(directory: URL) {
        self.directory = directory
    }

    /// FNV-1a over the name's UTF-8, as 16 hex digits. Stable across
    /// launches (`Hashable` is not).
    static func key(forFileRef fileRef: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in fileRef.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    func fileURL(forFileRef fileRef: String) -> URL {
        directory.appendingPathComponent(Self.key(forFileRef: fileRef) + ".json")
    }

    /// The stored entry, or nil if the photo was never read.
    func entry(forFileRef fileRef: String) -> ImageTextEntry? {
        lock.lock()
        if let hit = memo[fileRef] { lock.unlock(); return hit }
        if knownMissing.contains(fileRef) { lock.unlock(); return nil }
        lock.unlock()

        var found: ImageTextEntry?
        if let data = try? Data(contentsOf: fileURL(forFileRef: fileRef)),
           let decoded = try? JSONDecoder().decode(ImageTextEntry.self, from: data),
           decoded.fileRef == fileRef {   // a hash collision reads as a miss
            found = decoded
        }
        lock.lock()
        if let found { memo[fileRef] = found } else { knownMissing.insert(fileRef) }
        lock.unlock()
        return found
    }

    func hasEntry(forFileRef fileRef: String) -> Bool {
        entry(forFileRef: fileRef) != nil
    }

    func text(forFileRef fileRef: String) -> String? {
        entry(forFileRef: fileRef)?.text
    }

    /// Writes (or overwrites) the entry. Returns false if the write failed;
    /// the memo is then left alone so the next pass retries.
    @discardableResult
    func store(_ entry: ImageTextEntry) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entry)
            try data.write(to: fileURL(forFileRef: entry.fileRef), options: .atomic)
        } catch {
            return false
        }
        lock.lock()
        memo[entry.fileRef] = entry
        knownMissing.remove(entry.fileRef)
        lock.unlock()
        return true
    }
}
