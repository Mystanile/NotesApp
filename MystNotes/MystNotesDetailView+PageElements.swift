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
            guard inkSelection.delete(exactly: selection.strokes) else { return }
            let lines = max(text.split(separator: "\n").count, 1)
            var block = TextBlockSnapshot(id: UUID(), content: text)
            block.frame = CGRect(x: selection.bounds.minX - 6, y: selection.bounds.minY - 6,
                                 width: max(selection.bounds.width + 12, 120), height: selection.bounds.height + 12)
            block.fontSize = min(max(Double(selection.bounds.height) / Double(lines) * 0.6, 12), 48)
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
            modelContext.insert(block)
            page.textBlocks = (page.textBlocks ?? []) + [block]
        } else if let block = page.textBlocks?.first(where: { $0.id == snapshot.id }) {
            page.textBlocks?.removeAll { $0.id == snapshot.id }
            modelContext.delete(block)
        }
        page.markModified()
        saveMetadata("Failed to save text block")
        let canvas = canvasView
        canvas.undoManager?.registerUndo(withTarget: canvas) { _ in
            setTextBlock(snapshot, present: !present, on: page)
        }
    }

    func addTextBlock() {
        guard let page = currentPage else { return }
        let block = TypedTextBlock(content: "", page: page)
        block.frameX = 60
        block.frameY = 60
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
        sticker.frameX = 100
        sticker.frameY = 100
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
