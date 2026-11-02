import Foundation
import SwiftData
import NaturalLanguage

// MARK: - Maths and text splitting

/// Pure helpers: vector maths, sentence-boundary chunking, the stable hash.
nonisolated enum SemanticMath {
    static func dot(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count else { return 0 }
        var sum: Double = 0
        for i in 0..<a.count { sum += Double(a[i]) * Double(b[i]) }
        return sum
    }

    static func norm(_ a: [Float]) -> Double { dot(a, a).squareRoot() }

    /// 0 for mismatched sizes or a zero vector.
    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let denominator = norm(a) * norm(b)
        return denominator > 0 ? dot(a, b) / denominator : 0
    }

    /// Unit length; a zero vector stays zero.
    static func normalized(_ a: [Float]) -> [Float] {
        let length = norm(a)
        guard length > 0 else { return a }
        return a.map { Float(Double($0) / length) }
    }

    /// The normalized mean of vectors of one size; nil for none (or mixed sizes).
    static func normalizedMean(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first, vectors.allSatisfy({ $0.count == first.count }) else { return nil }
        var sum = [Double](repeating: 0, count: first.count)
        for v in vectors { for i in 0..<v.count { sum[i] += Double(v[i]) } }
        return normalized(sum.map { Float($0 / Double(vectors.count)) })
    }

    /// FNV-1a over the UTF-8, 16 hex digits. Stable across launches
    /// (`Hashable` is not).
    static func textHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    /// Splits `text` into pieces of at most `maxLength` characters, cutting
    /// at sentence boundaries (. ! ? and line breaks) and packing whole
    /// sentences together. A single sentence longer than the limit is cut at
    /// a space (or hard, with none). Blank text gives no chunks.
    static func chunks(of text: String, maxLength: Int = 400) -> [String] {
        let limit = max(maxLength, 1)
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "." || character == "!" || character == "?" || character == "\n" {
                sentences.append(current)
                current = ""
            }
        }
        sentences.append(current)

        var result: [String] = []
        var buffer = ""
        func flush() {
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(trimmed) }
            buffer = ""
        }
        for raw in sentences {
            let sentence = raw.replacingOccurrences(of: "\n", with: " ")
            if sentence.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if sentence.count > limit {
                flush()
                var rest = Substring(sentence)
                while rest.count > limit {
                    let window = rest.prefix(limit)
                    let cut = window.lastIndex(of: " ").map { window.distance(from: window.startIndex, to: $0) } ?? 0
                    let end = cut > 0 ? rest.index(rest.startIndex, offsetBy: cut) : rest.index(rest.startIndex, offsetBy: limit)
                    let piece = rest[rest.startIndex..<end].trimmingCharacters(in: .whitespaces)
                    if !piece.isEmpty { result.append(piece) }
                    rest = rest[end...]
                }
                let tail = rest.trimmingCharacters(in: .whitespaces)
                if !tail.isEmpty { buffer = tail }
                continue
            }
            if buffer.count + sentence.count > limit { flush() }
            buffer += sentence
        }
        flush()
        return result
    }

    /// At most `count` items, evenly spread, order kept.
    static func spread<T>(_ items: [T], count: Int) -> [T] {
        guard count > 0 else { return [] }
        guard items.count > count else { return items }
        return (0..<count).map { items[$0 * items.count / count] }
    }
}

// MARK: - Embedding source

/// Turns text into a vector. The real one is `NLEmbedding`; tests inject a
/// stub. Nil means "no vector for this text".
nonisolated protocol SemanticEmbedder: Sendable {
    /// False when the model isn't available on this device: the feature is
    /// silently off.
    var isAvailable: Bool { get }
    func embed(_ text: String) -> [Float]?
}

/// Apple's on-device English sentence embedding. Loaded on first use (off the
/// main thread by callers) and serialized: one `NLEmbedding` is not promised
/// to be thread-safe.
nonisolated final class NLSentenceEmbedder: SemanticEmbedder, @unchecked Sendable {
    private let lock = NSLock()
    private var loaded = false
    private var embedding: NLEmbedding?

    private func model() -> NLEmbedding? {
        if !loaded {
            embedding = NLEmbedding.sentenceEmbedding(for: .english)
            loaded = true
        }
        return embedding
    }

    var isAvailable: Bool {
        lock.lock(); defer { lock.unlock() }
        return model() != nil
    }

    func embed(_ text: String) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        guard let model = model(), let vector = model.vector(for: text) else { return nil }
        return vector.map { Float($0) }
    }
}

// MARK: - One page's stored vectors

nonisolated struct SemanticEntry: Codable, Equatable, Sendable {
    var textHash: String
    var dims: Int
    var mean: [Float]
    var chunks: [[Float]]
}

nonisolated struct SemanticHit: Equatable, Sendable {
    let pageID: UUID
    let score: Double
}

// MARK: - The index

/// Per-page embeddings for semantic search. Derived, local-only data in
/// `Library/Caches/Semantic/<pageID>.json`: never syncs, rebuildable by
/// `SearchIndexer`, written by overwrite (atomic) and never removed. An entry
/// is valid only for the text hash it was computed from, so unchanged text is
/// never embedded twice. Safe from any thread.
nonisolated final class SemanticIndex: @unchecked Sendable {
    static let shared = SemanticIndex(directory: SemanticIndex.defaultDirectory, embedder: NLSentenceEmbedder())

    /// Minimum cosine for a hit. Tunable.
    static let threshold = 0.35
    static let maxChunkLength = 400
    /// Chunk vectors kept per page for recall.
    static let storedChunkLimit = 8
    /// Chunks embedded per page, a ceiling on the cost of a very long page.
    static let embeddedChunkLimit = 48

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Semantic", isDirectory: true)
    }

    let directory: URL
    private let embedder: SemanticEmbedder
    private let lock = NSLock()
    private var memo: [UUID: SemanticEntry] = [:]
    private var loadedAll = false

    init(directory: URL, embedder: SemanticEmbedder) {
        self.directory = directory
        self.embedder = embedder
    }

    var isAvailable: Bool { embedder.isAvailable }

    func fileURL(forPageID id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString + ".json")
    }

    // MARK: Storage

    func entry(forPageID id: UUID) -> SemanticEntry? {
        lock.lock()
        if let hit = memo[id] { lock.unlock(); return hit }
        lock.unlock()
        guard let data = try? Data(contentsOf: fileURL(forPageID: id)),
              let decoded = try? JSONDecoder().decode(SemanticEntry.self, from: data) else { return nil }
        lock.lock(); memo[id] = decoded; lock.unlock()
        return decoded
    }

    @discardableResult
    func store(_ entry: SemanticEntry, forPageID id: UUID) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(entry).write(to: fileURL(forPageID: id), options: .atomic)
        } catch {
            return false
        }
        lock.lock(); memo[id] = entry; lock.unlock()
        return true
    }

    /// Every stored entry, read from disk once and then from memory.
    func allEntries() -> [UUID: SemanticEntry] {
        lock.lock()
        let done = loadedAll
        lock.unlock()
        if !done {
            let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for url in urls where url.pathExtension == "json" {
                if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) { _ = entry(forPageID: id) }
            }
            lock.lock(); loadedAll = true; lock.unlock()
        }
        lock.lock(); defer { lock.unlock() }
        return memo
    }

    // MARK: Indexing

    /// Builds the vectors for `text` (nil when it is blank or unembeddable).
    func makeEntry(for text: String) -> SemanticEntry? {
        let pieces = Array(SemanticMath.chunks(of: text, maxLength: Self.maxChunkLength).prefix(Self.embeddedChunkLimit))
        let vectors = pieces.compactMap { embedder.embed($0) }.map(SemanticMath.normalized)
        guard let mean = SemanticMath.normalizedMean(vectors) else { return nil }
        return SemanticEntry(textHash: SemanticMath.textHash(text), dims: mean.count, mean: mean,
                             chunks: SemanticMath.spread(vectors, count: Self.storedChunkLimit))
    }

    /// Embeds a page's text unless the stored vectors already match its hash.
    /// True when something was computed and written.
    @discardableResult
    func index(pageID: UUID, text: String) -> Bool {
        guard !text.isEmpty, embedder.isAvailable else { return false }
        if entry(forPageID: pageID)?.textHash == SemanticMath.textHash(text) { return false }
        guard let made = makeEntry(for: text) else { return false }
        return store(made, forPageID: pageID)
    }

    // MARK: Queries

    /// Pages whose best chunk (or mean) is at least `threshold` close to the
    /// query, best first. Empty when the embedding is unavailable.
    func search(query: String, limit: Int, excluding: Set<UUID> = [],
                threshold: Double = SemanticIndex.threshold) -> [SemanticHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, embedder.isAvailable, let raw = embedder.embed(trimmed) else { return [] }
        let q = SemanticMath.normalized(raw)
        var hits: [SemanticHit] = []
        for (id, entry) in allEntries() where !excluding.contains(id) && entry.dims == q.count {
            let best = max(entry.chunks.map { SemanticMath.cosine(q, $0) }.max() ?? 0,
                           SemanticMath.cosine(q, entry.mean))
            if best >= threshold { hits.append(SemanticHit(pageID: id, score: best)) }
        }
        return Self.ranked(hits, limit: limit)
    }

    /// The pages whose mean vector is closest to `pageID`'s own.
    func similar(to pageID: UUID, limit: Int, excluding: Set<UUID> = [],
                 threshold: Double = SemanticIndex.threshold) -> [SemanticHit] {
        guard embedder.isAvailable, let own = entry(forPageID: pageID) else { return [] }
        var hits: [SemanticHit] = []
        for (id, entry) in allEntries() where id != pageID && !excluding.contains(id) && entry.dims == own.dims {
            let score = SemanticMath.cosine(own.mean, entry.mean)
            if score >= threshold { hits.append(SemanticHit(pageID: id, score: score)) }
        }
        return Self.ranked(hits, limit: limit)
    }

    /// Best first; ties broken by id so the order is stable.
    static func ranked(_ hits: [SemanticHit], limit: Int) -> [SemanticHit] {
        let sorted = hits.sorted { $0.score != $1.score ? $0.score > $1.score : $0.pageID.uuidString < $1.pageID.uuidString }
        return Array(sorted.prefix(max(limit, 0)))
    }
}

// MARK: - Off-main entry points

/// What the views and the indexer call. Every function is capture-free and
/// wraps `Task.detached`, so the work never lands on the main actor (a plain
/// `Task { }` in a view would run there).
nonisolated enum SemanticSearch {
    static func searchDetached(query: String, limit: Int) -> Task<[SemanticHit], Never> {
        Task.detached(priority: .userInitiated) { SemanticIndex.shared.search(query: query, limit: limit) }
    }

    static func similarDetached(to pageID: UUID, limit: Int, excluding: Set<UUID>) -> Task<[SemanticHit], Never> {
        Task.detached(priority: .userInitiated) {
            SemanticIndex.shared.similar(to: pageID, limit: limit, excluding: excluding)
        }
    }

    /// Embeds one page's text; true when something was written.
    static func indexDetached(pageID: UUID, text: String) -> Task<Bool, Never> {
        Task.detached(priority: .utility) { SemanticIndex.shared.index(pageID: pageID, text: text) }
    }

    static func availabilityDetached() -> Task<Bool, Never> {
        Task.detached(priority: .utility) { SemanticIndex.shared.isAvailable }
    }
}

// MARK: - Resolving hits to pages (main actor)

@MainActor
enum SemanticResolver {
    /// The pages for `hits`, best first, dropping pages that no longer exist
    /// and pages in a locked notebook.
    static func pages(for hits: [SemanticHit], in context: ModelContext) -> [Page] {
        let ids = hits.map(\.pageID)
        guard !ids.isEmpty else { return [] }
        let fetched = (try? context.fetch(FetchDescriptor<Page>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        let byID = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }.filter { page in
            guard let notebook = page.notebook else { return false }
            return NotebookLock.shared.isOpen(notebook)
        }
    }
}
