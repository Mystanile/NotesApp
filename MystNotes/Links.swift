import Foundation
import CoreGraphics
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

    /// A picked node as the destination: an explicit link to a region.
    /// `destinationPageID` stays the node's page so page-level readers
    /// still navigate. Saves.
    static func setDestination(_ link: Link, toNode node: Link, in context: ModelContext, now: Date = Date()) {
        link.destinationKind = "region"
        link.destinationID = node.id.uuidString
        link.destinationPageID = node.sourcePageID
        markSources([link.sourcePageID], in: context, now: now)
        try? context.save()
    }

    /// A named region of strokes on `page`: a self-link of kind "node".
    /// A blank title falls back to a generic one, so a node is never nameless.
    /// `id` restores a node under its old identity. Marks the page and saves.
    @discardableResult
    static func makeNode(on page: Page, strokeIDs: [String], title: String, anchor: CGRect,
                         in context: ModelContext, now: Date = Date(), id: UUID? = nil) -> Link {
        let link = Link(sourcePageID: page.id, destinationPageID: page.id)
        // Set before the insert: undo of a delete puts the node back under
        // its own id, and an id changed after insert is a second identity.
        if let id { link.id = id }
        link.kind = "node"
        link.destinationKind = "region"
        link.strokeIDs = strokeIDs
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        link.title = trimmed.isEmpty ? nodeTitle(recognized: nil, pageNumber: page.index + 1) : trimmed
        link.anchorX = Double(anchor.minX)
        link.anchorY = Double(anchor.minY)
        link.anchorWidth = Double(anchor.width)
        link.anchorHeight = Double(anchor.height)
        context.insert(link)
        page.markModified(at: now)
        try? context.save()
        return link
    }

    /// Renames a link's title. Empty or whitespace-only is refused (false,
    /// nothing changed). Saves.
    @discardableResult
    static func setTitle(_ link: Link, _ title: String, in context: ModelContext, now: Date = Date()) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        link.title = trimmed
        markSources([link.sourcePageID], in: context, now: now)
        try? context.save()
        return true
    }

    /// A node's default name: the first non-empty line of the recognized
    /// handwriting, trimmed, at most 60 characters; else "Node, p. N".
    static func nodeTitle(recognized: String?, pageNumber: Int) -> String {
        let line = (recognized ?? "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let line else { return "Node, p. \(pageNumber)" }
        return String(line.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A plain anchor link (draws an anchor, navigates to a page or node).
    static func isPlainLink(_ link: Link) -> Bool { link.kind == nil }

    static func isNode(_ link: Link) -> Bool { link.kind == "node" }

    /// A link still pointing at its own page with nothing picked: what
    /// `addLink` creates before the destination picker answers. A node is
    /// also a self-link but has a kind and a destinationKind, so it is kept.
    static func isUnfinished(_ link: Link) -> Bool {
        link.kind == nil && link.destinationKind == nil && link.destinationID == nil
            && link.sourcePageID == link.destinationPageID
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
