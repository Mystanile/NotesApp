import Foundation
import SwiftData
#if canImport(UIKit)
import UIKit
import PencilKit
import Vision
#endif

/// On-device handwriting recognition for search (plan Phase 6).
///
/// The app stores each page's strokes as a `PKDrawing` file on disk. To make
/// that handwriting searchable we render the drawing back to an image and run
/// Apple's Vision framework (`VNRecognizeTextRequest`) over it, then store the
/// recognized text in `Page.recognizedTextCache`.
///
/// OCR is the slow step, so we only re-run it when a page's drawing actually
/// changed since it was last recognized — compared via the drawing file's
/// modification date against `Page.ocrUpdatedAt`. Unchanged pages keep their
/// cached text and cost nothing on later searches.

/// Debounces handwriting recognition so it doesn't run on every autosave.
///
/// OCR used to be awaited inside the 1-second autosave: renders the page at
/// 2x, composites it and runs a full `VNRecognizeTextRequest` over it. That
/// is a Vision pass per second for as long as someone keeps writing - all
/// of it thrown away by the next stroke, and enough CPU and transient
/// memory to cause the stutter (and the memory warnings that empty the
/// bitmap caches) it was supposed to stay clear of.
///
/// One timer per page, so turning to another page doesn't cancel the OCR
/// the page you left still owes. Nothing here is on the drawing path: the
/// recognition itself is `nonisolated async` and runs on the global
/// executor.
@MainActor
final class HandwritingIndexer {
    static let shared = HandwritingIndexer()

    /// Long enough to mean "stopped writing", short enough that search
    /// finds what you wrote a moment ago.
    static let delay: TimeInterval = 12

    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// The page each pending timer is for, so `flush` can run them now
    /// rather than dropping them.
    private var pending: [UUID: Page] = [:]

    /// Restarts `page`'s timer. Safe to call on every edit.
    func schedule(_ page: Page, modelContext: ModelContext, delay: TimeInterval = HandwritingIndexer.delay) {
        let pageID = page.id
        tasks[pageID]?.cancel()
        pending[pageID] = page
        tasks[pageID] = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
            }
            await HandwritingRecognizer.refreshOCR(for: page, modelContext: modelContext)
            self?.tasks[pageID] = nil
            self?.pending[pageID] = nil
        }
    }

    /// Runs whatever is waiting, now. Leaving a page or going to the
    /// background is a better moment for it than most - and it means a
    /// page you wrote on and walked away from is still indexed.
    func flush(modelContext: ModelContext) {
        for (_, page) in pending {
            schedule(page, modelContext: modelContext, delay: 0)
        }
    }
}


nonisolated enum HandwritingRecognizer {
    /// Recognizes the text in a page's ink. Returns nil when there is no
    /// drawing, it's blank, or recognition finds nothing. Runs the Vision
    /// request off the main actor so the UI never hangs on a search.
    static func ocrText(forPageID pageID: UUID) async -> String? {
#if canImport(UIKit)
        guard let drawing = DrawingStore.live.load(pageID: pageID) else {
            return nil
        }
        return await text(in: drawing)
#else
        return nil
#endif
    }

#if canImport(UIKit)
    /// The text in some ink - a page's, or a lasso selection's (Convert to
    /// Text). Lines come back in reading order, joined by `separator`.
    static func text(in drawing: PKDrawing, separator: String = " ") async -> String? {
        // Inset the ink bounds a little so strokes at the very edge aren't
        // clipped. A blank/empty drawing yields an empty (or null) bounds.
        let bounds = drawing.bounds.insetBy(dx: -20, dy: -20)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        // Render at 2x so handwriting is legible to the recognizer; 1x can
        // blur fine pen strokes into noise.
        //
        // Forcing the light trait collection is essential, not cosmetic:
        // PKDrawing.image() renders through PencilKit's dark-mode ink
        // inversion (it assumes a dark canvas and flips black ink to white).
        // Rendered in dark mode, black handwriting comes out WHITE - and the
        // white background composited below then makes it invisible, so
        // Vision finds nothing and the page silently becomes unsearchable.
        // That's why pages written in dark mode never showed up in search
        // while older, light-mode-indexed ones still did.
        // On the ink render queue, never the cooperative pool this async
        // function runs on (`InkRenderQueue`).
        let renderedInk: UIImage? = await InkRenderQueue.run {
            var image: UIImage?
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                image = drawing.image(from: bounds, scale: 2)
            }
            return image
        }
        guard let inkImage = renderedInk else { return nil }

        // PKDrawing.image(from:scale:) renders ink on a transparent
        // background - VNRecognizeTextRequest reliably returns zero
        // observations on a transparent image (confirmed independently: the
        // exact same text recognizes perfectly on an opaque background and
        // finds nothing at all on a transparent one), so composite onto an
        // opaque white background before handing it to Vision.
        let renderer = UIGraphicsImageRenderer(size: inkImage.size)
        let opaqueImage = renderer.image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: inkImage.size))
            inkImage.draw(at: .zero)
        }
        guard let cgImage = opaqueImage.cgImage else { return nil }

        return await Task.detached(priority: .background) { () -> String? in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return nil
            }

            // One candidate per text observation, in reading order.
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            guard !lines.isEmpty else { return nil }
            return lines.joined(separator: separator)
        }.value
    }
#endif

    /// Re-recognizes a page's handwriting only if its drawing changed since the
    /// last OCR, then persists the cache. Safe to call from a background task.
    @MainActor
    static func refreshOCR(for page: Page, modelContext: ModelContext) async {
        let store = DrawingStore.live
        guard let modDate = store.inkModifiedDate(forPageID: page.id) else { return }

        // Skip if we already indexed this drawing and it hasn't changed
        // since. The nil check is what lets pages recover: everything
        // indexed while the dark-mode render bug was live got a nil cache
        // plus a fresh ocrUpdatedAt, and the date check alone would treat
        // that as "already done" and skip it forever, leaving those pages
        // permanently unsearchable.
        if let ocrDate = page.ocrUpdatedAt,
           page.recognizedTextCache != nil,
           modDate <= ocrDate {
            return
        }

        // Empty string, not nil, when recognition legitimately finds
        // nothing: nil means "never successfully indexed" and triggers a
        // retry, so storing nil for a pure drawing would re-run the
        // expensive Vision pass on it every single time search is opened.
        // Pages left nil by the dark-mode render bug still get their one
        // retry, then settle. SearchIndex already ignores empty text.
        let text = await ocrText(forPageID: page.id)
        page.recognizedTextCache = text ?? ""
        page.ocrUpdatedAt = Date()
        do {
            try modelContext.save()
        } catch {
            print("Failed to persist OCR cache: \(error)")
        }
    }

    /// Runs `refreshOCR` over every page that still needs it (used when search
    /// first opens, so notebooks written before this feature existed get
    /// indexed). Returns once all pending pages are processed.
    static func indexAllIfNeeded(pages: [Page], modelContext: ModelContext) async {
        for page in pages {
            // The pass awaits OCR page by page: the search screen can close
            // and a sync pull can delete a page between two of them. A
            // deleted model must not be touched.
            if Task.isCancelled { return }
            guard page.modelContext != nil, !page.isDeleted else { continue }
            await refreshOCR(for: page, modelContext: modelContext)
        }
    }
}