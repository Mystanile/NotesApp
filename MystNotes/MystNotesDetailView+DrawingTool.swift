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
    // MARK: - Drawing tool

    #if targetEnvironment(macCatalyst) || canImport(UIKit)
    func applyToolState() {
        // Named in the log so a stall while switching tools or colours
        // says so - see MainThreadWatchdog.
        MainThreadWatchdog.checkpoint("DetailView.applyToolState")
        canvasView.tool = toolState.pkTool
        // Our lasso, not PencilKit's, on every page type.
        inkSelection.canvas = canvasView
        inkSelection.onDrawingChanged = scheduleAutosave
        inkSelection.isActive = toolState.activeKind == .lasso
        // Neither our lasso nor the fill leaves ink: the Pencil draws a
        // loop or taps. Written here, from both, so neither undoes the
        // other when switching straight from one to the other.
        let inks = !inkSelection.isActive && toolState.activeKind != .fill
        if canvasView.drawingGestureRecognizer.isEnabled != inks {
            canvasView.drawingGestureRecognizer.isEnabled = inks
        }
        updateCanvasInteractionEnabled()
    }

    /// Apple Pencil (Pro) double-tap: jump to the eraser, and on the next
    /// double-tap jump back to whatever tool was in hand. `.onChange(of:
    /// toolState)` pushes the change down to the canvas and the toolbar
    /// highlight follows automatically.
    func togglePencilEraser() {
        if toolState.activeKind == .eraser {
            toolState.activeKind = toolBeforeEraser ?? .pen
            toolBeforeEraser = nil
        } else {
            toolBeforeEraser = toolState.activeKind
            toolState.activeKind = .eraser
        }
    }

    /// Apple Pencil Pro squeeze: open the options of the tool in hand. The
    /// lasso has none, so the pen's open then. A second squeeze closes
    /// them again.
    func openColorOptions() {
        if openToolOptions != nil { openToolOptions = nil; return }
        let kind = toolState.activeKind
        openToolOptions = kind == .lasso ? .pen : kind
    }

    /// Image handles take the touches while an image is being adjusted.
    func updateCanvasInteractionEnabled() {
        canvasView.isUserInteractionEnabled = adjustingImageFrame == nil
    }

    func performFill(at point: CGPoint, on page: Page) {
        let drawing = canvasView.drawing
        let size = PageGeometry.contentSize(for: page)
        let color = toolState.fillColor.fixedUIColor
        Task {
            guard let filled = await FillTool.fill(drawing, in: size, at: point, color: color) else { return }
            canvasView.setDrawingUndoably(filled)
            scheduleAutosave()
        }
    }
    #endif

    // MARK: - Drawing toolbar

    /// The one place the toolbar is built, for the navigation bar's slot
    /// and the floating capsule both.
    func drawingToolbar(page: Page, style: DrawingToolbarView.Style, containerSize: CGSize) -> DrawingToolbarView {
        var scanNewPages: (() -> Void)?
        #if canImport(UIKit)
        if DocumentScannerView.isAvailable {
            scanNewPages = { importTarget = .newPages; showingScanner = true }
        }
        #endif
        return DrawingToolbarView(
            style: style,
            toolState: $toolState,
            openPopover: $openToolOptions,
            canUndo: canUndo,
            canRedo: canRedo,
            isFillToolAvailable: page.type != "whiteboard",
            isTextBoxAvailable: page.type != "whiteboard",
            containerSize: containerSize,
            onUndo: { canvasView.undoManager?.undo() },
            onRedo: { canvasView.undoManager?.redo() },
            onAddTextBox: addTextBlock,
            onAddSticker: { showingStickerPicker = true },
            onAddLink: { addLink() },
            onAddImage: { importTarget = .currentPage; showingImagePicker = true },
            onImportFile: { importTarget = .currentPage; presentFileImporter(for: [.pdf, .image]) },
            onPasteImage: { pasteImageFromClipboard() },
            canPasteImage: pasteboardHasImage,
            onNewPagesFromFiles: { importTarget = .newPages; presentFileImporter(for: [.pdf, .image]) },
            onNewPagesFromPhotos: { importTarget = .newPages; showingImagePicker = true },
            onNewPagesScan: scanNewPages
        )
    }

    // MARK: - Presentation

    /// Presentation mode is meant to be a clean, non-interactive view, but
    /// the fill tool acts on a tap - left armed, a stray tap on the
    /// presented page would fill a region. Stand it down on the way in.
    func enterPresentationMode() {
        shapePreview = nil
        adjustingImageFrame = nil
        adjustingLayerID = nil
        croppingRect = nil
#if targetEnvironment(macCatalyst) || canImport(UIKit)
        if toolState.activeKind == .fill { toolState.activeKind = .pen }
        updateCanvasInteractionEnabled()
#endif
        isPresenting = true
    }
}
