import Foundation
import CoreGraphics

/// One line of recognized handwriting and where it sits on the page.
/// `rect` is in drawing (page) coordinates, top-left origin - the same space
/// as the ink and `TypedTextBlock` frames.
nonisolated struct RecognizedLine: Codable, Hashable, Sendable {
    var text: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(text: String, rect: CGRect) {
        self.text = text
        self.x = Double(rect.minX)
        self.y = Double(rect.minY)
        self.width = Double(rect.width)
        self.height = Double(rect.height)
    }

    var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

/// The pure geometry and matching behind search highlights. Kept apart from
/// Vision and the file system so it can be tested with plain numbers.
nonisolated enum RecognizedGeometry {
    /// Maps a Vision bounding box to drawing coordinates.
    ///
    /// - Parameters:
    ///   - normalized: `VNRecognizedTextObservation.boundingBox` - 0...1 of
    ///     the image, origin at the **bottom-left**.
    ///   - renderedRect: the drawing rect that was rendered into the image
    ///     (`drawing.bounds.insetBy(-20, -20)`), in drawing coordinates.
    ///   - scale: the render scale (2 for OCR). Pixels are `points * scale`;
    ///     the factor cancels for a normalized box, but the mapping is spelled
    ///     out so a change of render scale cannot silently skew it.
    /// - Returns: the box in drawing coordinates, origin top-left.
    static func drawingRect(normalized: CGRect, renderedRect: CGRect, scale: CGFloat = 2) -> CGRect {
        guard scale > 0, renderedRect.width > 0, renderedRect.height > 0 else { return .zero }
        let pixelWidth = renderedRect.width * scale
        let pixelHeight = renderedRect.height * scale
        let px = normalized.minX * pixelWidth
        let pw = normalized.width * pixelWidth
        let ph = normalized.height * pixelHeight
        // Flip: Vision's y grows upward, the drawing's grows downward.
        let py = (1 - normalized.maxY) * pixelHeight
        return CGRect(x: renderedRect.minX + px / scale,
                      y: renderedRect.minY + py / scale,
                      width: pw / scale,
                      height: ph / scale)
    }

    /// The first line containing `query`, ignoring case and diacritics. A
    /// multi-word query that no single line holds falls back to the line
    /// containing its first word that appears anywhere, so a phrase wrapped
    /// across two lines still lands near its start.
    static func line(matching query: String, in lines: [RecognizedLine]) -> RecognizedLine? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if let hit = lines.first(where: { $0.text.range(of: needle, options: options) != nil }) {
            return hit
        }
        let words = needle.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count > 1 else { return nil }
        for word in words {
            if let hit = lines.first(where: { $0.text.range(of: word, options: options) != nil }) {
                return hit
            }
        }
        return nil
    }
}

/// A local-only cache of where each page's recognized lines are
/// (`Library/Caches/RecognizedLines/<pageID>.json`).
///
/// Derived data: never synced, never exported, safe to lose - a missing or
/// stale file is recomputed on demand. It lives in the caches directory and
/// is only ever overwritten (atomic write), never removed, so invariant 3 has
/// nothing to say about it.
nonisolated struct RecognizedLinesFile: Codable, Sendable {
    /// The page's ink modification date, in milliseconds since 1970, that
    /// these lines were computed from. A different stamp means the ink has
    /// changed since and the lines are out of date.
    var ocrStamp: Int64
    var lines: [RecognizedLine]
}

nonisolated enum RecognizedLinesStore {
    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("RecognizedLines", isDirectory: true)
    }

    /// Millisecond stamp for an ink modification date. Whole milliseconds,
    /// rounded, so a date that round-trips through a file system still matches.
    static func stamp(for date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    static func fileURL(pageID: UUID, in directory: URL = defaultDirectory) -> URL {
        directory.appendingPathComponent("\(pageID.uuidString).json")
    }

    /// The stored lines, but only if they were computed from the ink as it is
    /// now (`stamp`).
    static func load(pageID: UUID, stamp: Int64, in directory: URL = defaultDirectory) -> [RecognizedLine]? {
        guard let data = try? Data(contentsOf: fileURL(pageID: pageID, in: directory)),
              let file = try? JSONDecoder().decode(RecognizedLinesFile.self, from: data),
              file.ocrStamp == stamp else { return nil }
        return file.lines
    }

    /// Writes (or overwrites) the page's lines. Atomic; failure is ignored,
    /// since the cache can always be recomputed.
    static func save(_ lines: [RecognizedLine], pageID: UUID, stamp: Int64, in directory: URL = defaultDirectory) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(RecognizedLinesFile(ocrStamp: stamp, lines: lines))
            try data.write(to: fileURL(pageID: pageID, in: directory), options: .atomic)
        } catch {
            // Derived data; the next request recomputes it.
        }
    }

    /// Fire-and-forget `save`, off the caller's actor. Capture-free by
    /// construction (values only), as `DrawingStore.saveDetached` is.
    static func saveInBackground(_ lines: [RecognizedLine], pageID: UUID, stamp: Int64) {
        Task.detached(priority: .utility) {
            save(lines, pageID: pageID, stamp: stamp)
        }
    }

    /// The page's recognized lines: from the cache when it is current,
    /// otherwise by running recognition now (through `InkRenderQueue`, off
    /// the main thread) and caching the result. Nil when the page has no ink
    /// or recognition fails.
    static func lines(forPageID pageID: UUID) async -> [RecognizedLine]? {
        let cached = await Task.detached(priority: .userInitiated) { () -> (stamp: Int64, lines: [RecognizedLine]?)? in
            guard let modified = DrawingStore.live.inkModifiedDate(forPageID: pageID) else { return nil }
            let inkStamp = RecognizedLinesStore.stamp(for: modified)
            return (inkStamp, RecognizedLinesStore.load(pageID: pageID, stamp: inkStamp))
        }.value
        guard let cached else { return nil }
        if let lines = cached.lines { return lines }
#if canImport(UIKit)
        let fresh = await HandwritingRecognizer.recognizeLines(forPageID: pageID) ?? []
        saveInBackground(fresh, pageID: pageID, stamp: cached.stamp)
        return fresh
#else
        return nil
#endif
    }
}
