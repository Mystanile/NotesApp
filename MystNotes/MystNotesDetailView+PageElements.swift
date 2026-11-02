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
    func addMention(from page: Page, to destinationID: UUID, blockID: UUID) {
        let key = blockID.uuidString
        let existing = (try? modelContext.fetch(FetchDescriptor<Link>())) ?? []
        guard !existing.contains(where: {
            $0.kind == "mention" && $0.sourcePageID == page.id && $0.destinationPageID == destinationID && $0.destinationID == key
        }) else { return }
        let link = Link(sourcePageID: page.id, destinationPageID: destinationID)
        link.kind = "mention"
        link.destinationID = key
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
            for destination in snapshot.mentions { addMention(from: page, to: destination, blockID: snapshot.id) }
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
            await save(canvasView.drawing, to: page)
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
            let link = Links.makeNode(on: page, strokeIDs: snapshot.strokeIDs, title: snapshot.title,
                                      anchor: snapshot.anchor, in: context)
            link.id = snapshot.id
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

    /// Every node on this notebook's pages (the Page Map's chips, greying).
    var notebookNodes: [Link] {
        let pageIDs = Set(sortedPages.map(\.id))
        return allLinks.filter { Links.isNode($0) && pageIDs.contains($0.sourcePageID) }
    }

    /// What `.task(id:)` watches to recompute `goneNodeIDs`: a page's ink
    /// only changes with its `modifiedAt`, and nodes come and go.
    struct GoneNodesKey: Equatable {
        var stamps: [Date?]
        var nodeIDs: [UUID]
    }

    var goneNodesKey: GoneNodesKey {
        GoneNodesKey(stamps: sortedPages.map(\.modifiedAt), nodeIDs: notebookNodes.map(\.id).sorted { $0.uuidString < $1.uuidString })
    }

    /// Which nodes' ink is gone, read from the records off the main thread.
    func refreshGoneNodes() async {
        let probes = NodeInk.probes(of: notebookNodes)
        let gone = probes.isEmpty ? [] : await NodeInk.goneDetached(probes).value
        guard !Task.isCancelled, gone != goneNodeIDs else { return }
        goneNodeIDs = gone
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
