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
    /// box, then the same destination picker as a plain link.
    func linkSelection() {
        guard let anchor = Self.linkAnchor(around: inkSelection.display.corners ?? []) else { return }
        addLink(anchoredTo: anchor)
        inkSelection.clear()
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

    func addLink(anchoredTo anchor: CGRect? = nil) {
        guard let page = currentPage else { return }
        // Placeholder self-referencing destination — immediately prompting
        // the picker below means the user always ends up choosing a real
        // target right away.
        let link = Link(sourcePageID: page.id, destinationPageID: page.id)
        link.anchorX = anchor.map { Double($0.minX) } ?? 40
        link.anchorY = anchor.map { Double($0.minY) } ?? 40
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
