import Foundation
import SwiftData
import CoreSpotlight
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

// Spotlight: notebooks and pages show up in system search, and tapping a hit
// opens the page (`MystNotesApp` -> `AppNavigationRequests` -> `ContentView`).
//
// Always on; there is no setting yet (BACKLOG if wanted). What leaves the
// app is what search already shows on screen: titles and the first ~300
// characters of a page's cached text. Locked notebooks and the templates
// notebook are never indexed, even while a locked notebook is open.
//
// Triggers: ~10 s after launch, on foreground, and 10 s after the last
// `ModelContext.didSave` (debounced). Ink edits save the context too, so the
// debounce is what keeps this off the drawing path. Per-item fingerprints
// mean an unchanged page costs nothing on a rerun.

// MARK: - Value snapshots (plain, Sendable, built on main, used anywhere)

nonisolated struct SpotlightPageSnapshot: Sendable, Equatable {
    let id: UUID
    let index: Int
    let title: String?
    /// Cached handwriting text plus typed text, already trimmed.
    let text: String
}

nonisolated struct SpotlightNotebookSnapshot: Sendable, Equatable {
    let id: UUID
    let title: String
    let folderName: String?
    let pageCount: Int
    let isLocked: Bool
    let isTemplates: Bool
    /// Empty for locked and templates notebooks: their text is never copied.
    let pages: [SpotlightPageSnapshot]
}

nonisolated struct SpotlightItemSpec: Sendable, Equatable {
    let uniqueID: String
    let domainID: String
    let title: String
    let contentDescription: String
    let isNotebook: Bool
}

// MARK: - Pure building and diffing

nonisolated enum SpotlightItems {
    static let descriptionLimit = 300
    static let batchSize = 200
    static let notebookPrefix = "notebook:"
    static let pagePrefix = "page:"

    static func notebookID(_ id: UUID) -> String { notebookPrefix + id.uuidString }
    static func pageID(_ id: UUID) -> String { pagePrefix + id.uuidString }

    /// What to index: notebooks, then their pages, minus anything locked or
    /// the templates notebook.
    static func specs(from notebooks: [SpotlightNotebookSnapshot]) -> [SpotlightItemSpec] {
        var out: [SpotlightItemSpec] = []
        for notebook in notebooks where !notebook.isLocked && !notebook.isTemplates {
            let domain = notebook.id.uuidString
            var detail = notebook.pageCount == 1 ? "1 page" : "\(notebook.pageCount) pages"
            if let folder = notebook.folderName, !folder.isEmpty { detail += " \u{00B7} \(folder)" }
            out.append(SpotlightItemSpec(uniqueID: notebookID(notebook.id), domainID: domain,
                                         title: notebook.title, contentDescription: detail, isNotebook: true))
            for page in notebook.pages {
                let named = page.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let title = named.isEmpty ? "Page \(page.index + 1) \u{00B7} \(notebook.title)" : named
                out.append(SpotlightItemSpec(uniqueID: pageID(page.id), domainID: domain, title: title,
                                             contentDescription: String(page.text.prefix(descriptionLimit)),
                                             isNotebook: false))
            }
        }
        return out
    }

    /// Whitespace collapsed to single spaces, capped, for a snapshot's text.
    static func condensed(_ parts: [String?], limit: Int = descriptionLimit) -> String {
        var words: [Substring] = []
        var length = 0
        outer: for part in parts {
            guard let part else { continue }
            for word in part.prefix(4 * limit).split(whereSeparator: \.isWhitespace) {
                words.append(word)
                length += word.count + 1
                if length >= limit { break outer }
            }
        }
        return String(words.joined(separator: " ").prefix(limit))
    }

    /// Ids that were indexed before and are gone now.
    static func staleIDs(previous: Set<String>, current: Set<String>) -> [String] {
        previous.subtracting(current).sorted()
    }

    /// Stable across launches (unlike `Hasher`): FNV-1a over title + description.
    static func fingerprint(_ spec: SpotlightItemSpec) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in (spec.title + "\u{1}" + spec.contentDescription).utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    /// Specs that are new or whose text changed since `previous` (id -> fingerprint).
    static func changed(_ specs: [SpotlightItemSpec], since previous: [String: String]) -> [SpotlightItemSpec] {
        specs.filter { previous[$0.uniqueID] != fingerprint($0) }
    }

    enum Target: Equatable {
        case notebook(UUID)
        case page(UUID)
    }

    /// Reads back a Spotlight `uniqueIdentifier`.
    static func parse(identifier: String) -> Target? {
        if identifier.hasPrefix(pagePrefix), let id = UUID(uuidString: String(identifier.dropFirst(pagePrefix.count))) {
            return .page(id)
        }
        if identifier.hasPrefix(notebookPrefix), let id = UUID(uuidString: String(identifier.dropFirst(notebookPrefix.count))) {
            return .notebook(id)
        }
        return nil
    }

    static func searchableItem(_ spec: SpotlightItemSpec) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: UTType.text)
        attributes.title = spec.title
        attributes.contentDescription = spec.contentDescription
        let item = CSSearchableItem(uniqueIdentifier: spec.uniqueID, domainIdentifier: spec.domainID,
                                    attributeSet: attributes)
        // The default expiry is one month; these are re-indexed on change only.
        item.expirationDate = .distantFuture
        return item
    }
}

// MARK: - Persisted id -> fingerprint map (Caches; rebuildable, so losing it just reindexes)

nonisolated enum SpotlightIndexStore {
    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Spotlight/indexed.json")
    }

    static func load(from url: URL = defaultURL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }

    static func save(_ map: [String: String], to url: URL = defaultURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Main-actor capture

@MainActor
enum SpotlightSnapshots {
    /// Plain values for every notebook. Locked and templates notebooks get no
    /// pages, so their text is never even read.
    static func capture(in context: ModelContext) -> [SpotlightNotebookSnapshot] {
        let notebooks = (try? context.fetch(FetchDescriptor<Notebook>())) ?? []
        return notebooks.map { notebook in
            let locked = notebook.isLocked == true
            let templates = PageTemplates.isTemplatesNotebook(notebook)
            let all = notebook.pages ?? []
            let pages: [SpotlightPageSnapshot] = (locked || templates) ? [] : all.sorted { $0.index < $1.index }.map { page in
                let typed = (page.textBlocks ?? []).map { Optional($0.content) }
                return SpotlightPageSnapshot(id: page.id, index: page.index, title: page.title,
                                             text: SpotlightItems.condensed([page.recognizedTextCache] + typed))
            }
            return SpotlightNotebookSnapshot(id: notebook.id, title: notebook.title,
                                             folderName: notebook.folder?.name, pageCount: all.count,
                                             isLocked: locked, isTemplates: templates, pages: pages)
        }
    }
}

// MARK: - Coordinator

@MainActor
final class SpotlightIndexer {
    static let shared = SpotlightIndexer()
    nonisolated static let launchDelay: Duration = .seconds(10)
    nonisolated static let debounce: Duration = .seconds(10)

    private var container: ModelContainer?
    private var started = false
    private var running = false
    private var pending: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    /// Call once at launch.
    func start(container: ModelContainer) {
        guard !started else { return }
        started = true
        self.container = container
        let center = NotificationCenter.default
        // Debounced: a save per stroke must not mean an index pass per stroke.
        observers.append(center.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule(after: SpotlightIndexer.debounce) }
        })
#if canImport(UIKit)
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule(after: .seconds(2)) }
        })
#endif
        schedule(after: SpotlightIndexer.launchDelay)
    }

    private func schedule(after delay: Duration) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.runPass()
        }
    }

    private func runPass() async {
        guard let container, !running else { return }
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        // Capturing snapshots reads every page on main. Never while a
        // notebook is open (ink latency, invariant 10): try again later; the
        // notebook closing and the app becoming active both reschedule.
        if SearchIndexer.shared.openNotebookCount > 0 {
            schedule(after: .seconds(60))
            return
        }
        running = true
        defer { running = false }
        let snapshots = SpotlightSnapshots.capture(in: container.mainContext)
        // Everything past this line is off the main thread.
        await SpotlightIndexer.indexDetached(snapshots: snapshots).value
    }

    /// Capture-free by construction: the work runs on the global pool, not
    /// the main actor (see CLAUDE.md, the actor isolation gotcha).
    nonisolated static func indexDetached(snapshots: [SpotlightNotebookSnapshot]) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            await SpotlightWorker.run(snapshots: snapshots)
        }
    }
}

nonisolated enum SpotlightWorker {
    /// Diffs against the persisted map, deletes what is gone, indexes what
    /// is new or changed in batches, then saves the map. A failed batch is
    /// left out of the map so the next pass retries it.
    static func run(snapshots: [SpotlightNotebookSnapshot], index: CSSearchableIndex = .default(),
                    storeURL: URL = SpotlightIndexStore.defaultURL) async {
        let specs = SpotlightItems.specs(from: snapshots)
        var map = SpotlightIndexStore.load(from: storeURL)
        let stale = SpotlightItems.staleIDs(previous: Set(map.keys), current: Set(specs.map(\.uniqueID)))
        for start in stride(from: 0, to: stale.count, by: SpotlightItems.batchSize) {
            let batch = Array(stale[start..<min(start + SpotlightItems.batchSize, stale.count)])
            do {
                try await index.deleteSearchableItems(withIdentifiers: batch)
                for id in batch { map[id] = nil }
            } catch {}
        }
        let todo = SpotlightItems.changed(specs, since: map)
        for start in stride(from: 0, to: todo.count, by: SpotlightItems.batchSize) {
            let batch = Array(todo[start..<min(start + SpotlightItems.batchSize, todo.count)])
            do {
                try await index.indexSearchableItems(batch.map(SpotlightItems.searchableItem))
                for spec in batch { map[spec.uniqueID] = SpotlightItems.fingerprint(spec) }
            } catch {}
        }
        SpotlightIndexStore.save(map, to: storeURL)
    }
}
