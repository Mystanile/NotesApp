import Foundation
import SwiftData

/// The one place that changes a `Link`. A link syncs with its source page,
/// and `contentSignature` hashes only page `modifiedAt`, so every change
/// here marks the source page(s) modified (M2 task 1).
enum Links {
    /// A picked destination. Saves, so the caller need not.
    static func setDestination(_ link: Link, toPage pageID: UUID, in context: ModelContext, now: Date = Date()) {
        link.destinationPageID = pageID
        markSources([link.sourcePageID], in: context, now: now)
        try? context.save()
    }

    /// Deletes every link into or out of `pageIDs` and marks the surviving
    /// source pages outside the set. Does not save.
    static func removeAll(touching pageIDs: Set<UUID>, in context: ModelContext, now: Date = Date()) {
        guard !pageIDs.isEmpty else { return }
        let links = (try? context.fetch(FetchDescriptor<Link>())) ?? []
        var sources: Set<UUID> = []
        for link in links where pageIDs.contains(link.sourcePageID) || pageIDs.contains(link.destinationPageID) {
            if !pageIDs.contains(link.sourcePageID) { sources.insert(link.sourcePageID) }
            context.delete(link)
        }
        markSources(sources, in: context, now: now)
    }

    private static func markSources(_ ids: Set<UUID>, in context: ModelContext, now: Date) {
        guard !ids.isEmpty else { return }
        let pages = (try? context.fetch(FetchDescriptor<Page>())) ?? []
        for page in pages where ids.contains(page.id) { page.markModified(at: now) }
    }
}
