import Foundation
import SwiftData
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// What the indexer needs to know about a page to decide whether it is stale.
/// Plain values, so the check can run off the main actor.
nonisolated struct PageOCRState: Sendable {
    let id: UUID
    let ocrUpdatedAt: Date?
    let hasCache: Bool
}

/// The indexer's own SwiftData context, on its own executor, so neither the
/// staleness scan nor the OCR write ever touches the main context (invariant
/// 10). Created off the main thread (`SearchIndexer.runPass`). OCR fields
/// never call `markModified` - derived data, locked decision.
@ModelActor
actor SearchOCRStore {
    /// Ids of pages whose ink needs recognition. Two narrow fetches (ids and
    /// OCR dates; ids with no cache) rather than every page in full - the
    /// cached text can be large.
    func stalePageIDs() -> [UUID] {
        var all = FetchDescriptor<Page>()
        all.propertiesToFetch = [\Page.id, \Page.ocrUpdatedAt]
        var uncached = FetchDescriptor<Page>(predicate: #Predicate<Page> { $0.recognizedTextCache == nil })
        uncached.propertiesToFetch = [\Page.id]
        let missing = Set(((try? modelContext.fetch(uncached)) ?? []).map(\.id))
        let states = ((try? modelContext.fetch(all)) ?? []).map {
            PageOCRState(id: $0.id, ocrUpdatedAt: $0.ocrUpdatedAt, hasCache: !missing.contains($0.id))
        }
        return SearchIndexer.staleIDs(in: states, now: Date())
    }

    /// Recognizes one page and stages the result in this context. Returns
    /// true when something was written (not yet saved - see `save`). Skips a
    /// page whose ink changed within `settleInterval`: that is the open
    /// page's, and `HandwritingIndexer`'s debounce handles it.
    func refresh(pageID: UUID) async -> Bool {
        guard let modified = DrawingStore.live.inkModifiedDate(forPageID: pageID),
              SearchIndexer.isSettled(inkModified: modified, now: Date()) else { return false }
        var descriptor = FetchDescriptor<Page>(predicate: #Predicate<Page> { $0.id == pageID })
        descriptor.fetchLimit = 1
        guard let page = (try? modelContext.fetch(descriptor))?.first,
              SearchIndexer.needsOCR(inkModified: modified, ocrUpdatedAt: page.ocrUpdatedAt,
                                     hasCache: page.recognizedTextCache != nil) else { return false }
        let text = await HandwritingRecognizer.recognizeAndStash(pageID: pageID, inkModified: modified)
        // A sync pull can delete the page while Vision runs.
        guard page.modelContext != nil, !page.isDeleted else { return false }
        page.recognizedTextCache = text
        page.ocrUpdatedAt = Date()
        return true
    }

    /// File names of every imported picture in the library (narrow fetch).
    func photoFileRefs() -> [String] {
        let descriptor = FetchDescriptor<ImportedDocument>(predicate: #Predicate<ImportedDocument> { $0.sourceType == "image" })
        let docs = (try? modelContext.fetch(descriptor)) ?? []
        return docs.map(\.fileRef)
    }

    func save() {
        guard modelContext.hasChanges else { return }
        do { try modelContext.save() } catch { print("Failed to persist OCR cache: \(error)") }
    }
}


/// Keeps handwriting search current in the background, so opening search
/// finds an index that is already built instead of building it in front of
/// the user.
///
/// It walks pages whose ink is newer than `ocrUpdatedAt` (or that were never
/// recognized), one at a time, pausing between pages. Started at launch
/// (after a short delay), whenever the app becomes active, and when the
/// search screen opens; stopped when the app goes to the background.
///
/// Invariant 10: it does not run while a notebook is open
/// (`notebookOpened` / `notebookClosed`; the open page is
/// `HandwritingIndexer`'s), the stale list and the OCR writes live on a
/// background context (`SearchOCRStore`), and every ink render goes through
/// `InkRenderQueue` with the drawing already decoded. This class only
/// sequences them.
@MainActor
@Observable
final class SearchIndexer {
    static let shared = SearchIndexer()

    /// True while somebody is actively drawing on a canvas; the indexer waits
    /// rather than competing with the pencil. Nothing sets it yet; the
    /// notebook-open gate and the per-page recency check cover it.
    static var isInkActive = false

    /// Ink changed this recently belongs to `HandwritingIndexer`'s debounce,
    /// not to a background pass.
    nonisolated static let settleInterval: TimeInterval = 15
    nonisolated static let launchDelay: Duration = .seconds(5)
    nonisolated static let pageGap: Duration = .seconds(1)

    /// Pages still waiting for recognition in the current pass.
    private(set) var pendingCount = 0
    /// Bumps when pages finish and are saved, so views can refresh results.
    private(set) var completedCount = 0

    /// Notebook screens on display (more than one with several windows).
    /// While above zero a pass pauses.
    @ObservationIgnored private(set) var openNotebookCount = 0

    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    // MARK: - Lifecycle

    /// Call once at launch. Schedules the first pass after a short delay so
    /// it never competes with the app coming up.
    func start(container: ModelContainer) {
        guard !started else { return }
        started = true
        self.container = container
#if canImport(UIKit)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestRun() }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        })
#endif
        Task { [weak self] in
            try? await Task.sleep(for: SearchIndexer.launchDelay)
            self?.requestRun()
        }
    }

    /// A notebook screen appeared: pause any pass until all are gone.
    func notebookOpened() {
        openNotebookCount += 1
    }

    /// A notebook screen went away. A paused pass resumes by itself.
    func notebookClosed() {
        openNotebookCount = max(0, openNotebookCount - 1)
    }

    /// Starts a pass unless one is already running. Cheap to call often. A
    /// pass that was stopped may still be finishing its page; the new one
    /// waits for it, so two never overlap.
    func requestRun() {
        guard container != nil else { return }
        if let task, !task.isCancelled { return }
#if canImport(UIKit)
        guard UIApplication.shared.applicationState != .background else { return }
#endif
        generation += 1
        let mine = generation
        let previous = task
        task = Task(priority: .utility) { [weak self] in
            await previous?.value
            guard let self, self.isCurrent(mine) else { return }
            await self.runPass(mine)
            if self.generation == mine { self.task = nil }
        }
    }

    /// Cancels the running pass (app backgrounded). The page in flight
    /// finishes, but it is stale from here on: it writes no counts and
    /// starts nothing.
    func stop() {
        generation += 1
        task?.cancel()
        pendingCount = 0
    }

    // MARK: - The pass

    private func isCurrent(_ mine: Int) -> Bool {
        Self.shouldContinue(passGeneration: mine, currentGeneration: generation,
                            cancelled: Task.isCancelled)
    }

    /// Waits while a notebook is open or ink is active. False when the pass
    /// went stale meanwhile.
    private func waitUntilQuiet(_ mine: Int) async -> Bool {
        while isCurrent(mine), openNotebookCount > 0 || Self.isInkActive {
            try? await Task.sleep(for: .seconds(1))
        }
        return isCurrent(mine)
    }

    private func runPass(_ mine: Int) async {
        guard let container else { return }
        guard await waitUntilQuiet(mine) else { return }
        // Created off the main thread, so its context is too.
        let store = await Task.detached(priority: .utility) {
            SearchOCRStore(modelContainer: container)
        }.value
        let stale = await store.stalePageIDs()
        guard isCurrent(mine) else { return }
        pendingCount = stale.count

        var unsaved = 0
        func flush() async {
            guard unsaved > 0 else { return }
            await store.save()
            // Counts only move for the pass that is still current.
            if isCurrent(mine) { completedCount += unsaved }
            unsaved = 0
        }

        for id in stale {
            guard isCurrent(mine) else { break }
            if openNotebookCount > 0 || Self.isInkActive {
                await flush()
                guard await waitUntilQuiet(mine) else { break }
            }
            let wrote = await store.refresh(pageID: id)
            if wrote { unsaved += 1 }
            guard isCurrent(mine) else { break }
            pendingCount = max(0, pendingCount - 1)
            if unsaved >= Self.saveBatch { await flush() }
            if wrote { try? await Task.sleep(for: Self.pageGap) }
        }
        // Saved however the loop ended (done, stopped, cancelled).
        await flush()

        // Then the photos, one at a time, under the same rules.
        guard isCurrent(mine) else { return }
        let cache = ImageTextCache.shared
        let allRefs = await store.photoFileRefs()
        let photos = await Task.detached(priority: .utility) {
            Self.photosNeedingText(fileRefs: allRefs, hasEntry: { cache.hasEntry(forFileRef: $0) })
        }.value
        pendingCount += photos.count
        for ref in photos {
            guard isCurrent(mine) else { break }
            if openNotebookCount > 0 || Self.isInkActive {
                guard await waitUntilQuiet(mine) else { break }
            }
            let wrote = await HandwritingRecognizer.recognizeAndCachePhoto(fileRef: ref)
            guard isCurrent(mine) else { break }
            pendingCount = max(0, pendingCount - 1)
            if wrote {
                completedCount += 1
                try? await Task.sleep(for: Self.pageGap)
            }
        }
        if isCurrent(mine) { pendingCount = 0 }
    }

    nonisolated static let saveBatch = 10

    // MARK: - Pure checks

    /// A pass may write counts and start another page only while it is the
    /// newest pass and has not been cancelled.
    nonisolated static func shouldContinue(passGeneration: Int, currentGeneration: Int, cancelled: Bool) -> Bool {
        passGeneration == currentGeneration && !cancelled
    }

    /// Ink not written to within `settleInterval`: safe for a background pass.
    nonisolated static func isSettled(inkModified: Date, now: Date) -> Bool {
        now.timeIntervalSince(inkModified) >= settleInterval
    }

    /// Mirrors the skip test in `HandwritingRecognizer.refreshOCR`: a page
    /// needs recognition when it has ink and either was never recognized or
    /// the ink is newer than the last recognition.
    nonisolated static func needsOCR(inkModified: Date?, ocrUpdatedAt: Date?, hasCache: Bool) -> Bool {
        guard let inkModified else { return false }
        guard let ocrUpdatedAt, hasCache else { return true }
        return inkModified > ocrUpdatedAt
    }

    /// Photo files that still need reading: unique, non-empty, not PDFs, with
    /// no cache entry (an empty entry counts: it was read and had no text).
    nonisolated static func photosNeedingText(fileRefs: [String], hasEntry: (String) -> Bool) -> [String] {
        var seen = Set<String>()
        return fileRefs.filter { ref in
            guard SearchIndex.isPhoto(sourceType: "image", fileRef: ref), seen.insert(ref).inserted else { return false }
            return !hasEntry(ref)
        }
    }

    /// The ids among `states` whose ink needs recognition, skipping pages
    /// written to in the last `settleInterval`. Stats files, so it is only
    /// called from `SearchOCRStore`, never the main actor.
    nonisolated static func staleIDs(in states: [PageOCRState], now: Date) -> [UUID] {
        let store = DrawingStore.live
        return states.compactMap { state -> UUID? in
            let modified = store.inkModifiedDate(forPageID: state.id)
            if let modified, !isSettled(inkModified: modified, now: now) { return nil }
            return needsOCR(inkModified: modified, ocrUpdatedAt: state.ocrUpdatedAt,
                            hasCache: state.hasCache) ? state.id : nil
        }
    }
}
