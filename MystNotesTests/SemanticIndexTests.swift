import XCTest
@testable import Mystnotes

/// Semantic search without NaturalLanguage: the maths, the chunking, the
/// ranking and the cache's keying, driven by a stub embedder.
final class SemanticIndexTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SemanticIndexTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Maps a few keywords to axes: "cat" -> x, "dog" -> y, "tax" -> z.
    private final class StubEmbedder: SemanticEmbedder, @unchecked Sendable {
        let available: Bool
        private let lock = NSLock()
        private var calls = 0
        init(available: Bool = true) { self.available = available }
        var isAvailable: Bool { available }
        var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
        func embed(_ text: String) -> [Float]? {
            lock.lock(); calls += 1; lock.unlock()
            let t = text.lowercased()
            let v: [Float] = [t.contains("cat") ? 1 : 0, t.contains("dog") ? 1 : 0, t.contains("tax") ? 1 : 0]
            return v == [0, 0, 0] ? nil : v
        }
    }

    // MARK: - Maths

    func testCosine() {
        XCTAssertEqual(SemanticMath.cosine([1, 0], [1, 0]), 1, accuracy: 1e-9)
        XCTAssertEqual(SemanticMath.cosine([1, 0], [0, 1]), 0, accuracy: 1e-9)
        XCTAssertEqual(SemanticMath.cosine([1, 0], [-1, 0]), -1, accuracy: 1e-9)
        XCTAssertEqual(SemanticMath.cosine([1, 1], [2, 2]), 1, accuracy: 1e-6)
        XCTAssertEqual(SemanticMath.cosine([0, 0], [1, 0]), 0)
        XCTAssertEqual(SemanticMath.cosine([1], [1, 0]), 0)
    }

    func testNormalizedMean_isUnitLength() throws {
        let mean = try XCTUnwrap(SemanticMath.normalizedMean([[1, 0], [0, 1]]))
        XCTAssertEqual(SemanticMath.norm(mean), 1, accuracy: 1e-6)
        XCTAssertEqual(mean[0], mean[1], accuracy: 1e-6)
        XCTAssertNil(SemanticMath.normalizedMean([]))
        XCTAssertNil(SemanticMath.normalizedMean([[1], [1, 2]]))
    }

    func testTextHash_isStableAndSensitive() {
        XCTAssertEqual(SemanticMath.textHash("abc"), SemanticMath.textHash("abc"))
        XCTAssertNotEqual(SemanticMath.textHash("abc"), SemanticMath.textHash("abd"))
        XCTAssertEqual(SemanticMath.textHash("").count, 16)
    }

    // MARK: - Chunking

    func testChunks_splitAtSentenceBoundaries() {
        let text = "First sentence here. Second one follows! Third asks why? Fourth ends."
        let chunks = SemanticMath.chunks(of: text, maxLength: 45)
        XCTAssertEqual(chunks, ["First sentence here. Second one follows!", "Third asks why? Fourth ends."])
        for chunk in chunks { XCTAssertLessThanOrEqual(chunk.count, 45) }
    }

    func testChunks_shortTextIsOneChunk_blankIsNone() {
        XCTAssertEqual(SemanticMath.chunks(of: "Just one line"), ["Just one line"])
        XCTAssertTrue(SemanticMath.chunks(of: "  \n \n").isEmpty)
    }

    func testChunks_longSentenceIsCutAtSpaces() {
        let text = Array(repeating: "word", count: 30).joined(separator: " ")
        let chunks = SemanticMath.chunks(of: text, maxLength: 40)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, 40)
            XCTAssertFalse(chunk.hasPrefix(" ") || chunk.hasSuffix(" "))
        }
        XCTAssertEqual(chunks.joined(separator: " "), text)
    }

    func testSpread_keepsOrderAndCap() {
        XCTAssertEqual(SemanticMath.spread([1, 2, 3], count: 8), [1, 2, 3])
        let picked = SemanticMath.spread(Array(0..<100), count: 8)
        XCTAssertEqual(picked.count, 8)
        XCTAssertEqual(picked, picked.sorted())
    }

    // MARK: - Index

    private func makeIndex(_ embedder: StubEmbedder = StubEmbedder()) -> SemanticIndex {
        SemanticIndex(directory: directory, embedder: embedder)
    }

    func testEmptyText_makesNoVector() {
        let index = makeIndex()
        let id = UUID()
        XCTAssertFalse(index.index(pageID: id, text: ""))
        XCTAssertFalse(index.index(pageID: id, text: "nothing the stub knows"))
        XCTAssertNil(index.entry(forPageID: id))
    }

    func testIndex_unchangedTextIsNotRecomputed() {
        let embedder = StubEmbedder()
        let index = makeIndex(embedder)
        let id = UUID()
        XCTAssertTrue(index.index(pageID: id, text: "my cat sleeps."))
        let calls = embedder.callCount
        XCTAssertFalse(index.index(pageID: id, text: "my cat sleeps."))
        XCTAssertEqual(embedder.callCount, calls)
        // A cold instance reads the file and skips as well.
        let cold = makeIndex(embedder)
        XCTAssertFalse(cold.index(pageID: id, text: "my cat sleeps."))
        XCTAssertEqual(embedder.callCount, calls)
        // Changed text recomputes.
        XCTAssertTrue(cold.index(pageID: id, text: "my dog sleeps."))
        XCTAssertGreaterThan(embedder.callCount, calls)
        XCTAssertEqual(cold.entry(forPageID: id)?.textHash, SemanticMath.textHash("my dog sleeps."))
    }

    func testEntry_roundTripsThroughDisk() throws {
        let index = makeIndex()
        let id = UUID()
        index.index(pageID: id, text: "cat. dog.")
        let entry = try XCTUnwrap(makeIndex().entry(forPageID: id))
        XCTAssertEqual(entry.dims, 3)
        XCTAssertEqual(entry.mean.count, 3)
        XCTAssertEqual(entry.chunks.count, 1)   // one chunk: short text
    }

    func testSearch_ranksAndAppliesThreshold() {
        let index = makeIndex()
        let cat = UUID(), dog = UUID(), both = UUID(), tax = UUID()
        index.index(pageID: cat, text: "the cat.")
        index.index(pageID: dog, text: "the dog.")
        index.index(pageID: both, text: "the cat.\nthe dog.")
        index.index(pageID: tax, text: "the tax.")
        let hits = index.search(query: "cat", limit: 10)
        // Exact chunk match first (cat page and the page with a cat chunk tie at 1), dog and tax fall below.
        XCTAssertEqual(Set(hits.map(\.pageID)), [cat, both])
        XCTAssertTrue(hits.allSatisfy { $0.score >= SemanticIndex.threshold })
        XCTAssertEqual(index.search(query: "cat", limit: 1).count, 1)
        XCTAssertEqual(index.search(query: "cat", limit: 10, excluding: [cat]).map(\.pageID), [both])
        XCTAssertTrue(index.search(query: "   ", limit: 5).isEmpty)
        XCTAssertTrue(index.search(query: "unknown words", limit: 5).isEmpty)
    }

    func testSimilar_excludesSelfAndExcluded() {
        let index = makeIndex()
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        index.index(pageID: a, text: "cat")
        index.index(pageID: b, text: "cat cat")
        index.index(pageID: c, text: "cat")
        index.index(pageID: d, text: "tax")
        XCTAssertEqual(Set(index.similar(to: a, limit: 5).map(\.pageID)), [b, c])
        XCTAssertEqual(index.similar(to: a, limit: 5, excluding: [b]).map(\.pageID), [c])
        XCTAssertTrue(index.similar(to: UUID(), limit: 5).isEmpty)
    }

    func testRanked_ordersByScoreThenLimit() {
        let hits = [SemanticHit(pageID: UUID(), score: 0.4), SemanticHit(pageID: UUID(), score: 0.9),
                    SemanticHit(pageID: UUID(), score: 0.6)]
        XCTAssertEqual(SemanticIndex.ranked(hits, limit: 2).map(\.score), [0.9, 0.6])
    }

    func testUnavailableEmbedding_givesNothing() {
        let index = makeIndex(StubEmbedder(available: false))
        let id = UUID()
        XCTAssertFalse(index.index(pageID: id, text: "cat"))
        XCTAssertTrue(index.search(query: "cat", limit: 5).isEmpty)
        XCTAssertTrue(index.similar(to: id, limit: 5).isEmpty)
        XCTAssertFalse(index.isAvailable)
    }
}
