import Foundation
#if canImport(UIKit)
import PencilKit
#endif

/// Reads and writes a page's ink file, `<page-id>.drawing`.
///
/// This is the one place `.drawing` bytes touch disk. `MystNotesDetailView`
/// used to do this inline; it was pulled out so the durability tests can
/// drive the exact save and load path the app uses, against a temp
/// directory, and interrupt a write the way a kill would.
///
/// Behaviour is exactly what the view did: `load` answers `nil` for a
/// missing *or* undecodable file and the caller shows a blank page; `save`
/// writes the bytes straight to the target URL.
struct DrawingStore {
    /// Resolves a payload file name to its on-disk URL. The app uses
    /// `FileStore.url(for:)`, which still carries the dual-location
    /// fallback scheduled for deletion in M0 task 15.
    var url: (String) -> URL

    /// Writes bytes to a URL. Replaceable so a test can stop a write
    /// partway through and observe what is left on disk.
    var write: (Data, URL) throws -> Void = { try $0.write(to: $1) }

    static var live: DrawingStore { DrawingStore(url: FileStore.url(for:)) }

    static func inDirectory(_ directory: URL) -> DrawingStore {
        DrawingStore(url: { directory.appendingPathComponent($0) })
    }

    static func fileName(for pageID: UUID) -> String {
        "\(pageID.uuidString).drawing"
    }

    func fileURL(for pageID: UUID) -> URL {
        url(Self.fileName(for: pageID))
    }

#if canImport(UIKit)
    /// The page's saved ink, or `nil` if there is no readable file.
    func load(pageID: UUID) -> PKDrawing? {
        guard let data = try? Data(contentsOf: fileURL(for: pageID)) else { return nil }
        return try? PKDrawing(data: data)
    }

    /// Writes the drawing and returns the file name to keep in
    /// `Page.drawingFileRef`.
    @discardableResult
    func save(_ drawing: PKDrawing, pageID: UUID) throws -> String {
        let target = fileURL(for: pageID)
        try write(drawing.dataRepresentation(), target)
        return target.lastPathComponent
    }
#endif
}
