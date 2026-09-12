import Foundation
#if canImport(UIKit)
import PencilKit
#endif

/// Reads and writes a page's ink file, `<page-id>.drawing`.
///
/// This is the one place `.drawing` bytes touch disk, and it carries
/// invariant 1 - never lose ink - for that file:
///
/// - **Saves are atomic.** Bytes go to a sibling `.tmp` file and are
///   renamed into place, so the committed file is never partially
///   written. A kill mid-save leaves the previous drawing intact and a
///   stray `.tmp` the loader ignores.
/// - **Unreadable files are quarantined, never overwritten.** A file that
///   exists but doesn't decode (a payload copied before it finished
///   downloading, a bad sector) is moved to `trash/` next to it before the
///   page is shown blank, so the next autosave can't destroy the only copy.
///
/// `MystNotesDetailView` used to do this inline; `DurabilityTests` drives
/// this exact path against a temp directory.
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
    /// The page's saved ink, or `nil` if there is none. A file that exists
    /// but isn't a readable drawing is moved to `trash/` and also answers
    /// `nil`.
    ///
    /// "Readable" needs two checks. `PKDrawing(data:)` throws on
    /// truncation and most garbage, but a short run of arbitrary bytes can
    /// parse as a drawing with zero strokes - indistinguishable from a
    /// genuinely blank page. So a zero-stroke result is trusted only if the
    /// bytes start the way PencilKit's own archives do. Anything with
    /// strokes in it is kept no matter what.
    func load(pageID: UUID) -> PKDrawing? {
        let target = fileURL(for: pageID)
        guard let data = try? Data(contentsOf: target) else { return nil }
        if let drawing = try? PKDrawing(data: data),
           !drawing.strokes.isEmpty || data.starts(with: Self.archiveHeader) {
            return drawing
        }
        Self.moveToTrash(target, tag: "unreadable")
        return nil
    }

    /// The leading bytes of a PencilKit archive, taken from the framework
    /// itself so the check tracks whatever version is running.
    private static let archiveHeader: Data = PKDrawing().dataRepresentation().prefix(4)

    /// Atomically writes the drawing and returns the file name to keep in
    /// `Page.drawingFileRef`.
    @discardableResult
    func save(_ drawing: PKDrawing, pageID: UUID) throws -> String {
        let target = fileURL(for: pageID)
        let staging = target.appendingPathExtension("tmp")
        let fm = FileManager.default
        try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

        do {
            try write(drawing.dataRepresentation(), staging)
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: target)
            }
        } catch {
            // Only the never-committed fragment is discarded; the target
            // was not touched.
            try? fm.removeItem(at: staging)
            throw error
        }
        return target.lastPathComponent
    }
#endif

    /// What deleting a page does to its ink: the file goes to `trash/`.
    func trashDrawing(forPageID pageID: UUID) {
        Self.moveToTrash(fileURL(for: pageID), tag: "deleted")
    }

    /// Same for any other payload this page owned (an imported PDF or
    /// image no remaining page uses).
    func trashPayload(named name: String) {
        Self.moveToTrash(url(name), tag: "deleted")
    }

    /// Moves a payload into `trash/` beside it instead of deleting it
    /// (invariant 3), under a name that can't collide with a later copy of
    /// the same page. `tag` says why it went there - "unreadable",
    /// "conflict", "deleted" - so the user can tell the entries apart.
    static func moveToTrash(_ file: URL, tag: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else { return }
        let trash = file.deletingLastPathComponent().appendingPathComponent("trash", isDirectory: true)
        try? fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let name = file.deletingPathExtension().lastPathComponent + "-\(stamp)-\(tag)." + file.pathExtension
        try? fm.moveItem(at: file, to: trash.appendingPathComponent(name))
    }
}
