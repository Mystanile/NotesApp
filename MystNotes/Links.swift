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

    // MARK: Transclusion

    /// What undoing a transclusion's removal needs: the link's own identity
    /// and where it sat, as plain values.
    struct TransclusionSnapshot: Equatable {
        var id: UUID
        var hostPageID: UUID
        var nodeID: UUID
        var frame: CGRect
    }

    static func isTransclusion(_ link: Link) -> Bool { link.kind == "transclusion" }

    /// The node a transclusion shows, found among `links`. nil while the
    /// node has not arrived (sync order) or is deleted.
    static func node(for transclusion: Link, in links: [Link]) -> Link? {
        guard isTransclusion(transclusion), let key = transclusion.destinationID else { return nil }
        return links.first { isNode($0) && $0.id.uuidString == key }
    }

    /// A frame for a new transclusion of `node`, centred on `center` (page
    /// points): the node's own shape, the longer side `longSide`, shrunk to
    /// fit inside `pageSize` and kept on the page.
    static func transclusionFrame(for node: Link, centeredAt center: CGPoint, pageSize: CGSize,
                                  longSide: CGFloat = 300) -> CGRect {
        let w = max(node.anchorWidth, 1), h = max(node.anchorHeight, 1)
        var factor = longSide / max(w, h)
        if pageSize.width > 0, pageSize.height > 0 {
            factor = min(factor, pageSize.width * 0.9 / w, pageSize.height * 0.9 / h)
        }
        let size = CGSize(width: max(w * factor, 40), height: max(h * factor, 40))
        var origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        if pageSize.width > 0, pageSize.height > 0 {
            origin.x = min(max(origin.x, 0), max(pageSize.width - size.width, 0))
            origin.y = min(max(origin.y, 0), max(pageSize.height - size.height, 0))
        }
        return CGRect(origin: origin, size: size)
    }

    /// Shows `node`'s ink on `host` at `frame` (host page points). The link
    /// lives on the host, points its destination at the node's page, and has
    /// no strokes of its own: the node owns the list. Marks the host and
    /// saves. `id` restores a removed one under its old identity.
    @discardableResult
    static func addTransclusion(of node: Link, onto host: Page, frame: CGRect,
                                in context: ModelContext, now: Date = Date(), id: UUID? = nil) -> Link {
        let link = Link(sourcePageID: host.id, destinationPageID: node.sourcePageID)
        if let id { link.id = id }
        link.kind = "transclusion"
        link.destinationKind = "region"
        link.destinationID = node.id.uuidString
        setFrame(link, frame)
        context.insert(link)
        host.markModified(at: now)
        try? context.save()
        return link
    }

    /// Moves or resizes a transclusion. Marks the host and saves.
    static func moveTransclusion(_ link: Link, to frame: CGRect, in context: ModelContext, now: Date = Date()) {
        setFrame(link, frame)
        markSources([link.sourcePageID], in: context, now: now)
        try? context.save()
    }

    /// Takes a transclusion off its host. Marks the host, saves, and returns
    /// what `restoreTransclusion` needs. The node and its ink are untouched.
    @discardableResult
    static func removeTransclusion(_ link: Link, in context: ModelContext, now: Date = Date()) -> TransclusionSnapshot {
        let snapshot = TransclusionSnapshot(
            id: link.id, hostPageID: link.sourcePageID,
            nodeID: UUID(uuidString: link.destinationID ?? "") ?? UUID(),
            frame: CGRect(x: link.anchorX, y: link.anchorY, width: link.anchorWidth, height: link.anchorHeight))
        let host = link.sourcePageID
        context.delete(link)
        markSources([host], in: context, now: now)
        try? context.save()
        return snapshot
    }

    /// Undo of `removeTransclusion`: the same link, under its old id. nil
    /// when the host page or the node is gone by now.
    @discardableResult
    static func restoreTransclusion(_ snapshot: TransclusionSnapshot, in context: ModelContext,
                                    now: Date = Date()) -> Link? {
        let pages = (try? context.fetch(FetchDescriptor<Page>())) ?? []
        let links = (try? context.fetch(FetchDescriptor<Link>())) ?? []
        guard let host = pages.first(where: { $0.id == snapshot.hostPageID }),
              let node = links.first(where: { isNode($0) && $0.id == snapshot.nodeID }),
              !links.contains(where: { $0.id == snapshot.id }) else { return nil }
        return addTransclusion(of: node, onto: host, frame: snapshot.frame, in: context, now: now, id: snapshot.id)
    }

    private static func setFrame(_ link: Link, _ frame: CGRect) {
        link.anchorX = Double(frame.minX)
        link.anchorY = Double(frame.minY)
        link.anchorWidth = Double(frame.width)
        link.anchorHeight = Double(frame.height)
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

    /// After a text box's text changes: drops the box's mention links whose
    /// label is no longer between `[[ ]]` in `text`. A link with no title
    /// (made before labels were kept) goes only when the text has no
    /// `[[ ]]` at all. Marks the page and saves when something went; returns
    /// how many links went.
    @discardableResult
    static func pruneMentions(forBlock blockID: UUID, text: String, on page: Page,
                              in context: ModelContext, now: Date = Date()) -> Int {
        let key = blockID.uuidString
        let labels = PageMentions.labels(in: text)
        let hasTokens = PageMentions.hasTokens(in: text)
        let links = (try? context.fetch(FetchDescriptor<Link>())) ?? []
        var removed = 0
        for link in links where link.kind == "mention" && link.sourcePageID == page.id && link.destinationID == key {
            let keep: Bool
            if let title = link.title { keep = labels.contains(title) } else { keep = hasTokens }
            if !keep {
                context.delete(link)
                removed += 1
            }
        }
        if removed > 0 {
            page.markModified(at: now)
            try? context.save()
        }
        return removed
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
