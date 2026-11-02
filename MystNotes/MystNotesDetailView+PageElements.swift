import SwiftUI
import SwiftData
#if targetEnvironment(macCatalyst) || canImport(UIKit)
import PencilKit
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import PDFKit
import PhotosUI

extension NotebookDetailView {
    // MARK: - Page elements

    /// `[[page]]` in a text box: an anchorless "mention" edge, tied to its box.
    /// `label` is the text inserted between the brackets; it is kept in
    /// `Link.title` so editing the text can tell which links still have a
    /// token. nil (a restored legacy box) stays nil.
    func addMention(from page: Page, to destinationID: UUID, blockID: UUID, label: String?) {
        let key = blockID.uuidString
        let existing = (try? modelContext.fetch(FetchDescriptor<Link>())) ?? []
        guard !existing.contains(where: {
            $0.kind == "mention" && $0.sourcePageID == page.id && $0.destinationPageID == destinationID && $0.destinationID == key
        }) else { return }
        let link = Link(sourcePageID: page.id, destinationPageID: destinationID)
        link.kind = "mention"
        link.destinationID = key
        link.title = label
        link.anchorWidth = 0
        link.anchorHeight = 0
        modelContext.insert(link)
        page.markModified()
        saveMetadata("Couldn't save mention")
    }

    /// Lasso → Convert to Text: the selection's handwriting, read by the
    /// same Vision pipeline search uses, becomes a text box where the ink
    /// was, and the ink goes - one undo step that brings the ink back and
    /// takes the box away.
    func convertSelectionToText(on page: Page) {
        guard let selection = inkSelection.selectedStrokes else { return }
        let canvas = canvasView
        Task {
            let recognized = await HandwritingRecognizer.text(in: PKDrawing(strokes: selection.strokes), separator: "\n")
            guard canvasView === canvas else { return }
            guard let text = recognized?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                exportMessage = "Couldn't read any handwriting in the selection."
                return
            }
            canvas.undoManager?.beginUndoGrouping()
            defer {
                canvas.undoManager?.endUndoGrouping()
                refreshUndoRedoState()
            }
            // Where the ink is now: the selection may have moved while it was read.
            guard let bounds = inkSelection.delete(exactly: selection.strokes) else { return }
            let lines = max(text.split(separator: "\n").count, 1)
            var block = TextBlockSnapshot(id: UUID(), content: text)
            block.frame = CGRect(x: bounds.minX - 6, y: bounds.minY - 6,
                                 width: max(bounds.width + 12, 120), height: bounds.height + 12)
            block.fontSize = min(max(Double(bounds.height) / Double(lines) * 0.6, 12), 48)
            setTextBlock(block, present: true, on: page)
        }
    }

    /// Adds or removes one text box and registers the opposite on the
    /// page's undo stack (so undo registers redo).
    func setTextBlock(_ snapshot: TextBlockSnapshot, present: Bool, on page: Page) {
        if present {
            let block = TypedTextBlock(content: snapshot.content, page: page)
            block.id = snapshot.id
            (block.frameX, block.frameY) = (snapshot.frame.minX, snapshot.frame.minY)
            (block.frameWidth, block.frameHeight) = (snapshot.frame.width, snapshot.frame.height)
            block.fontSize = snapshot.fontSize
            block.textColorHex = snapshot.textColorHex
            block.fontDesign = snapshot.fontDesign
            (block.isBold, block.isItalic) = (snapshot.isBold, snapshot.isItalic)
            modelContext.insert(block)
            page.textBlocks = (page.textBlocks ?? []) + [block]
            for destination in snapshot.mentions { addMention(from: page, to: destination, blockID: snapshot.id, label: nil) }
        } else if let block = page.textBlocks?.first(where: { $0.id == snapshot.id }) {
            page.textBlocks?.removeAll { $0.id == snapshot.id }
            modelContext.delete(block)
            // Its mentions go with it; "Linked from" and the Page Map kept
            // showing them after the text was gone.
            mentionLinks(of: snapshot.id, on: page).forEach(modelContext.delete)
        }
        page.markModified()
        saveMetadata("Failed to save text block")
        let canvas = canvasView
        canvas.undoManager?.registerUndo(withTarget: canvas) { _ in
            setTextBlock(snapshot, present: !present, on: page)
        }
    }

    /// The text box's own delete button. Undoable, like every other edit:
    /// before, a deleted box and its typing were gone for good.
    func deleteTextBlock(_ block: TypedTextBlock, on page: Page) {
        let mentions = mentionLinks(of: block.id, on: page).map(\.destinationPageID)
        setTextBlock(TextBlockSnapshot(of: block, mentions: mentions), present: false, on: page)
    }

    /// A text box's text is settled: mention links whose `[[ ]]` token is
    /// gone go too (they kept showing in "Linked from" and the Page Map).
    func pruneMentions(of block: TypedTextBlock, on page: Page) {
        let removed = Links.pruneMentions(forBlock: block.id, text: block.content, on: page, in: modelContext)
        if removed > 0 { scheduleAutosave() }
    }

    /// The other notebooks' pages that a link from or to this notebook
    /// reaches, for the Page Map's ghost cards. Built from the notebooks the
    /// view already holds, and only when the map opens.
    func foreignPagesForPageMap() -> [UUID: GraphForeignPage] {
        let own = Set((notebook.pages ?? []).map(\.id))
        var wanted = Set<UUID>()
        for link in allLinks {
            if own.contains(link.sourcePageID), !own.contains(link.destinationPageID) { wanted.insert(link.destinationPageID) }
            if own.contains(link.destinationPageID), !own.contains(link.sourcePageID) { wanted.insert(link.sourcePageID) }
        }
        guard !wanted.isEmpty else { return [:] }
        var out: [UUID: GraphForeignPage] = [:]
        for other in allNotebooks where other.id != notebook.id {
            for page in other.pages ?? [] where wanted.contains(page.id) {
                out[page.id] = GraphForeignPage(title: page.title ?? "", notebookTitle: other.title,
                                                pageNumber: page.index + 1)
            }
        }
        return out
    }

    func mentionLinks(of blockID: UUID, on page: Page) -> [Link] {
        let key = blockID.uuidString
        return ((try? modelContext.fetch(FetchDescriptor<Link>())) ?? []).filter {
            $0.kind == "mention" && $0.sourcePageID == page.id && $0.destinationID == key
        }
    }

    /// Where a new text box or sticker goes: the middle of what is on
    /// screen, kept on the page, and stepped down past any element already
    /// there. A fixed corner put it off screen when zoomed in, and a second
    /// one exactly on top of the first.
    func newElementOrigin(size: CGSize, on page: Page) -> CGPoint {
        let center = viewport.pagePoint(from: CGPoint(x: canvasView.bounds.midX, y: canvasView.bounds.midY))
        let taken = (page.textBlocks ?? []).map { CGPoint(x: $0.frameX, y: $0.frameY) }
            + (page.stickers ?? []).map { CGPoint(x: $0.frameX, y: $0.frameY) }
        return Self.elementOrigin(centeredOn: center, size: size, pageSize: PageGeometry.contentSize(for: page), taken: taken)
    }

    static func elementOrigin(centeredOn center: CGPoint, size: CGSize, pageSize: CGSize, taken: [CGPoint]) -> CGPoint {
        var origin = CGPoint(x: min(max(center.x - size.width / 2, 0), max(pageSize.width - size.width, 0)),
                             y: min(max(center.y - size.height / 2, 0), max(pageSize.height - size.height, 0)))
        // Bounded: on a page full of elements it stops rather than walking
        // off the page.
        for _ in 0..<20 where taken.contains(where: { abs($0.x - origin.x) < 4 && abs($0.y - origin.y) < 4 }) {
            origin.x += 24
            origin.y += 24
        }
        return origin
    }

    func addTextBlock() {
        guard let page = currentPage else { return }
        let block = TypedTextBlock(content: "", page: page)
        let origin = newElementOrigin(size: CGSize(width: block.frameWidth, height: block.frameHeight), on: page)
        block.frameX = origin.x
        block.frameY = origin.y
        modelContext.insert(block)
        if page.textBlocks == nil {
            page.textBlocks = [block]
        } else {
            page.textBlocks?.append(block)
        }
        page.markModified()
        saveMetadata("Failed to save text block")
    }

    func addSticker(_ symbolName: String) {
        guard let page = currentPage else { return }
        let sticker = Sticker(assetRef: symbolName, page: page)
        let origin = newElementOrigin(size: CGSize(width: sticker.frameWidth, height: sticker.frameHeight), on: page)
        sticker.frameX = origin.x
        sticker.frameY = origin.y
        modelContext.insert(sticker)
        if page.stickers == nil {
            page.stickers = [sticker]
        } else {
            page.stickers?.append(sticker)
        }
        page.markModified()
        saveMetadata("Failed to save sticker")
    }

    /// Lasso → "Link This To…": a link whose tap area is the selection's
    /// box, then the same destination picker as a plain link. The link also
    /// records the selection's stroke ids (invariant 6), so its anchor can
    /// follow the ink; if they can't be read yet it is still made, without.
    func linkSelection() {
        guard let page = currentPage,
              let anchor = Self.linkAnchor(around: inkSelection.display.corners ?? []) else { return }
        let strokes = inkSelection.selectedStrokes?.strokes ?? []
        let canvas = canvasView
        inkSelection.clear()
        Task {
            let ids = strokes.isEmpty ? nil : await flushInkAndReadIDs(strokes, on: page)
            // A page turn in the meantime installed another canvas.
            guard canvasView === canvas else { return }
            addLink(anchoredTo: anchor, strokeIDs: ids)
        }
    }

    // MARK: - Nodes

    /// A node being named: the alert is up.
    struct NodeDraft: Equatable {
        var pageID: UUID
        var strokeIDs: [String]
        var anchor: CGRect
        /// What a blank field falls back to.
        var suggestion: String
    }

    /// Everything needed to put a node back (undo of a delete, redo of a make).
    struct NodeSnapshot {
        var id: UUID
        var strokeIDs: [String]
        var title: String
        var anchor: CGRect

        init(id: UUID = UUID(), strokeIDs: [String], title: String, anchor: CGRect) {
            self.id = id
            self.strokeIDs = strokeIDs
            self.title = title
            self.anchor = anchor
        }

        init(of link: Link) {
            self.init(id: link.id, strokeIDs: link.strokeIDs ?? [], title: link.title ?? "",
                      anchor: CGRect(x: link.anchorX, y: link.anchorY, width: link.anchorWidth, height: link.anchorHeight))
        }
    }

    /// Writes the canvas if it has unsaved ink, then returns the stable ids
    /// of `strokes` - or nil if any has none yet. A stroke only has an id
    /// once a record holding it has been written, so a node made seconds
    /// after drawing must save first. A clean canvas is never saved: it may
    /// be blank only because its ink hasn't arrived.
    func flushInkAndReadIDs(_ strokes: [PKStroke], on page: Page) async -> [String]? {
        if canvasIsDirty && canvasPageID == page.id {
            canvasIsDirty = false
            autosaveTask?.cancel()
            let drawing = canvasView.drawing
            let before = page.modifiedAt
            await save(drawing, to: page)
            // A successful save stamps the page; an unchanged date means the
            // write failed. `save` re-marks the canvas dirty when it is still
            // this page's, but that leaves nothing scheduled - re-arm the
            // autosave. If the canvas has moved on, the ink exists only in
            // `drawing`: one more try, so it isn't stranded.
            if page.modifiedAt == before {
                if canvasPageID == page.id {
                    canvasIsDirty = true
                    scheduleAutosave()
                } else {
                    await save(drawing, to: page)
                }
            }
        }
        let map = StrokeIDCache.shared.map(for: page.id)
        var ids: [String] = []
        for stroke in strokes {
            guard let id = map.existingID(for: stroke) else { return nil }
            ids.append(id.uuidString)
        }
        return ids.isEmpty ? nil : ids
    }

    /// Lasso → Make Node: reads the stroke ids (saving first) while the
    /// handwriting is read for a suggested name, then asks for the name.
    func beginMakeNode(on page: Page) {
        guard page.type != "whiteboard", let selection = inkSelection.selectedStrokes else { return }
        let canvas = canvasView
        let strokes = selection.strokes
        let bounds = selection.bounds
        let ocr = Task { await HandwritingRecognizer.text(in: PKDrawing(strokes: strokes), separator: "\n") }
        Task {
            let ids = await flushInkAndReadIDs(strokes, on: page)
            let recognized = await ocr.value
            guard canvasView === canvas else { return }
            guard let ids else {
                exportMessage = "Couldn't make a node from this ink yet. Try again in a moment."
                return
            }
            let suggestion = Links.nodeTitle(recognized: recognized, pageNumber: page.index + 1)
            nodeTitleText = suggestion
            nodeDraft = NodeDraft(pageID: page.id, strokeIDs: ids, anchor: bounds, suggestion: suggestion)
        }
    }

    /// The alert's Make button. Cancel just drops the draft.
    func commitNodeDraft() {
        guard let draft = nodeDraft else { return }
        nodeDraft = nil
        guard let page = sortedPages.first(where: { $0.id == draft.pageID }) else { return }
        let typed = nodeTitleText.trimmingCharacters(in: .whitespacesAndNewlines)
        setNode(NodeSnapshot(strokeIDs: draft.strokeIDs, title: typed.isEmpty ? draft.suggestion : typed,
                             anchor: draft.anchor),
                present: true, on: page)
        inkSelection.clear()
    }

    /// Adds or removes one node and registers the opposite on the page's
    /// undo stack, like `setTextBlock`.
    func setNode(_ snapshot: NodeSnapshot, present: Bool, on page: Page) {
        Self.applyNode(snapshot, present: present, on: page, in: modelContext)
        let canvas = canvasView
        canvas.undoManager?.registerUndo(withTarget: canvas) { _ in
            setNode(snapshot, present: !present, on: page)
        }
        refreshUndoRedoState()
    }

    /// The model half of `setNode`: puts the node back under its own id, or
    /// takes it away. Marks the page and saves either way.
    static func applyNode(_ snapshot: NodeSnapshot, present: Bool, on page: Page, in context: ModelContext) {
        if present {
            Links.makeNode(on: page, strokeIDs: snapshot.strokeIDs, title: snapshot.title,
                           anchor: snapshot.anchor, in: context, id: snapshot.id)
        } else {
            let id = snapshot.id
            let found = (try? context.fetch(FetchDescriptor<Link>(predicate: #Predicate { $0.id == id }))) ?? []
            found.forEach(context.delete)
            page.markModified()
        }
        do { try context.save() } catch { AppLog.note("save", "node: \(error)") }
    }

    func deleteNode(_ link: Link, on page: Page) {
        setNode(NodeSnapshot(of: link), present: false, on: page)
    }

    func beginRenameNode(_ link: Link) {
        renameNodeText = link.title ?? ""
        nodeToRename = link
    }

    func commitRenameNode() {
        guard let link = nodeToRename else { return }
        nodeToRename = nil
        guard link.modelContext != nil else { return }
        Links.setTitle(link, renameNodeText, in: modelContext)
    }

    /// Every node on this notebook's pages, from the cache `refreshNodeCache`
    /// keeps (the Page Map's chips, greying). Not recomputed per body.
    var notebookNodes: [Link] { nodeCache }

    /// The cache's input: changes when a node is made or removed, or the
    /// notebook's pages change. O(links) of trivial work, no fetch.
    struct NodeSetKey: Equatable {
        var linkCount: Int
        var nodeFingerprint: Int
        var pageCount: Int
    }

    var nodeSetKey: NodeSetKey {
        var fingerprint = 0
        for link in allLinks where Links.isNode(link) { fingerprint ^= link.id.hashValue }
        return NodeSetKey(linkCount: allLinks.count, nodeFingerprint: fingerprint, pageCount: notebook.pages?.count ?? 0)
    }

    func refreshNodeCache() {
        let pageIDs = Set((notebook.pages ?? []).map(\.id))
        nodeCache = allLinks.filter { Links.isNode($0) && pageIDs.contains($0.sourcePageID) }
    }

    /// What `.task(id:)` watches to re-probe the nodes' ink: the node set,
    /// and each node page's `modifiedAt` (cheap to read; the task itself
    /// compares the record's `InkStamp`, so a page whose ink didn't change
    /// is not decoded). The open page is left out while it has unsaved
    /// ink - its record is about to change and the canvas is the truth.
    nonisolated struct GoneNodesKey: Equatable {
        var nodeIDs: [UUID]
        var stamps: [Date?]
    }

    var goneNodesKey: GoneNodesKey {
        let nodePageIDs = Set(nodeCache.map(\.sourcePageID))
        let skipped = canvasIsDirty ? canvasPageID : nil
        let pages = (notebook.pages ?? []).filter { nodePageIDs.contains($0.id) && $0.id != skipped }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        return GoneNodesKey(nodeIDs: nodeCache.map(\.id).sorted { $0.uuidString < $1.uuidString },
                            stamps: pages.map(\.modifiedAt))
    }

    /// Which nodes' ink is gone, read from the records off the main thread.
    /// Debounced (2 s, so a burst of autosaves while drawing costs nothing),
    /// and per page: only a page whose record changed on disk is decoded
    /// again. A page that's being drawn on is left to its last verdict.
    func refreshGoneNodes() async {
        try? await Task.sleep(for: .seconds(2))
        if Task.isCancelled { return }
        let byPage = Dictionary(grouping: NodeInk.probes(of: nodeCache), by: \.pageID)
        var cache = goneCache.filter { byPage[$0.key] != nil }
        let drawingOn = canvasIsDirty ? canvasPageID : nil
        for (pageID, probes) in byPage where pageID != drawingOn {
            if Task.isCancelled { return }
            let result = await NodeInk.recheckDetached(pageID: pageID, probes: probes,
                                                       previous: cache[pageID], store: drawingStore).value
            if let result { cache[pageID] = result }
        }
        if Task.isCancelled { return }
        if cache != goneCache { goneCache = cache }
        let gone = cache.values.reduce(into: Set<UUID>()) { $0.formUnion($1.gone) }
        if gone != goneNodeIDs { goneNodeIDs = gone }
    }

    // MARK: Connections panel data

    /// Pages that link to `pageID`, each once, never the page itself.
    static func incomingSourceIDs(to pageID: UUID, links: [Link]) -> [UUID] {
        Array(Set(links.lazy.filter { $0.destinationPageID == pageID && $0.sourcePageID != pageID }.map(\.sourcePageID)))
    }

    /// Pages `pageID` links out to, each once, never the page itself.
    static func outgoingDestinationIDs(from pageID: UUID, links: [Link]) -> [UUID] {
        Array(Set(links.lazy.filter { $0.sourcePageID == pageID && $0.destinationPageID != pageID }.map(\.destinationPageID)))
    }

    /// What the connections snapshot is recomputed on: the open page, the
    /// links that touch it, whether the card is open, and what is hiding.
    struct ConnectionsKey: Equatable {
        var pageID: UUID?
        var linkPrint: Int
        var expanded: Bool
        var hiding: UUID?
        var presenting: Bool
    }

    var connectionsKey: ConnectionsKey {
        guard let id = currentPage?.id else {
            return ConnectionsKey(pageID: nil, linkPrint: 0, expanded: connectionsExpanded,
                                  hiding: pendingDeletion?.pageID, presenting: isPresenting)
        }
        var hasher = Hasher()
        for link in allLinks where link.sourcePageID == id || link.destinationPageID == id {
            hasher.combine(link.id)
            hasher.combine(link.sourcePageID)
            hasher.combine(link.destinationPageID)
            hasher.combine(link.kind)
            hasher.combine(link.title)
            hasher.combine(link.anchorX)
            hasher.combine(link.anchorY)
        }
        return ConnectionsKey(pageID: id, linkPrint: hasher.finalize(), expanded: connectionsExpanded,
                              hiding: pendingDeletion?.pageID, presenting: isPresenting)
    }

    /// Recomputes the card's data. Collapsed, that is a count and nothing
    /// fetched; expanded, the page fetches the lists need.
    func refreshConnections() {
        guard !isPresenting, let page = currentPage else {
            if connections != .init() { connections = .init() }
            return
        }
        let hiding = pendingDeletion?.pageID
        let nodeLinks = nodes(on: page)
        let nodeEntries = nodeLinks.map { ConnectionsPanel.NodeEntry(id: $0.id, title: $0.title ?? "Node", isGone: false) }
        var next = ConnectionsPanel.Snapshot()
        if connectionsExpanded {
            let entry: (Page) -> ConnectionsPanel.Entry = {
                .init(id: $0.id, label: LinkedFromStrip.label(for: $0, currentNotebookID: notebook.id))
            }
            next.linkedFrom = LinkedFromStrip.sources(linkingTo: page.id, links: allLinks,
                                                      pages: pagesLinking(to: page.id).filter { $0.id != hiding }).map(entry)
            next.linksTo = pagesLinked(from: page.id).filter { $0.id != hiding }
                .sorted { ($0.notebook?.title ?? "", $0.index) < ($1.notebook?.title ?? "", $1.index) }
                .map(entry)
            next.nodes = nodeEntries
            next.count = next.linkedFrom.count + next.linksTo.count + nodeEntries.count
        } else {
            next.count = Self.incomingSourceIDs(to: page.id, links: allLinks).filter { $0 != hiding }.count
                + Self.outgoingDestinationIDs(from: page.id, links: allLinks).filter { $0 != hiding }.count
                + nodeEntries.count
        }
        if next != connections { connections = next }
    }

    /// The node links on `page`, in reading order.
    func nodes(on page: Page) -> [Link] {
        allLinks.filter { $0.sourcePageID == page.id && Links.isNode($0) }
            .sorted { ($0.anchorY, $0.anchorX) < ($1.anchorY, $1.anchorX) }
    }

    /// The box around a selection's corners (page coordinates, the same
    /// space as link anchors), at least 44pt each way so it stays tappable.
    static func linkAnchor(around corners: [CGPoint]) -> CGRect? {
        guard let minX = corners.map(\.x).min(), let maxX = corners.map(\.x).max(),
              let minY = corners.map(\.y).min(), let maxY = corners.map(\.y).max() else { return nil }
        return CGRect(x: minX, y: minY, width: max(44, maxX - minX), height: max(44, maxY - minY))
    }

    /// A new link starts pointing at its own page until a destination is
    /// picked. Cancelling the picker used to leave it there: an anchor that
    /// went nowhere, and a self-edge in the Page Map that synced.
    func removeUnfinishedLinks() {
        let unfinished = allLinks.filter(Links.isUnfinished)
        guard !unfinished.isEmpty else { return }
        unfinished.forEach(modelContext.delete)
        currentPage?.markModified()
        saveMetadata("Failed to remove an unfinished link")
    }

    func addLink(anchoredTo anchor: CGRect? = nil, strokeIDs: [String]? = nil) {
        guard let page = currentPage else { return }
        // Placeholder self-referencing destination — immediately prompting
        // the picker below means the user always ends up choosing a real
        // target right away.
        let link = Link(sourcePageID: page.id, destinationPageID: page.id)
        link.anchorX = anchor.map { Double($0.minX) } ?? 40
        link.anchorY = anchor.map { Double($0.minY) } ?? 40
        link.strokeIDs = strokeIDs
        if let anchor {
            link.anchorWidth = Double(anchor.width)
            link.anchorHeight = Double(anchor.height)
        }
        modelContext.insert(link)
        page.markModified()
        saveMetadata("Failed to save link")
        linkNeedingDestination = link
    }
}
