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
enum HandwritingRecognizer {
    /// Recognizes the text in a page's drawing file. Returns nil when there is
    /// no drawing, it's blank, or recognition finds nothing. Runs the Vision
    /// request off the main actor so the UI never hangs on a search.
    static func ocrText(forDrawingFile url: URL) async -> String? {
#if canImport(UIKit)
        guard let data = try? Data(contentsOf: url),
              let drawing = try? PKDrawing(data: data) else {
            return nil
        }

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
        var renderedInk: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            renderedInk = drawing.image(from: bounds, scale: 2)
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
            return lines.joined(separator: " ")
        }.value
#else
        return nil
#endif
    }

    /// Re-recognizes a page's handwriting only if its drawing changed since the
    /// last OCR, then persists the cache. Safe to call from a background task.
    @MainActor
    static func refreshOCR(for page: Page, modelContext: ModelContext) async {
        let url = FileStore.url(for: "\(page.id.uuidString).drawing")
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        // Skip if we already indexed this drawing and it hasn't changed
        // since. The nil check is what lets pages recover: everything
        // indexed while the dark-mode render bug was live got a nil cache
        // plus a fresh ocrUpdatedAt, and the date check alone would treat
        // that as "already done" and skip it forever, leaving those pages
        // permanently unsearchable.
        if let ocrDate = page.ocrUpdatedAt,
           page.recognizedTextCache != nil,
           let modDate = try? url.resourceValues(forKeys: [URLResourceKey.contentModificationDateKey]).contentModificationDate,
           modDate <= ocrDate {
            return
        }

        // Empty string, not nil, when recognition legitimately finds
        // nothing: nil means "never successfully indexed" and triggers a
        // retry, so storing nil for a pure drawing would re-run the
        // expensive Vision pass on it every single time search is opened.
        // Pages left nil by the dark-mode render bug still get their one
        // retry, then settle. SearchIndex already ignores empty text.
        let text = await ocrText(forDrawingFile: url)
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
            await refreshOCR(for: page, modelContext: modelContext)
        }
    }
}