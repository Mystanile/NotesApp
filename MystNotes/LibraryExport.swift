import Foundation
import SwiftData
#if canImport(UIKit)
import UIKit

/// Everything out, in open formats (invariant 9): a notebook's text as
/// Markdown, and the whole library as a zip of every notebook's PDF and
/// Markdown in a tree of its folders.
enum LibraryExport {
    /// The notebook's words: page names, typed text, and recognized
    /// handwriting as a quote under each page.
    static func markdown(for notebook: Notebook) -> String {
        var lines = ["# \(notebook.title)", ""]
        let pages = (notebook.pages ?? []).sorted { $0.index < $1.index }
        for (offset, page) in pages.enumerated() {
            let name = page.title.map { ": \($0)" } ?? ""
            lines.append("## Page \(offset + 1)\(name)")
            lines.append("")
            if let tags = page.tags, !tags.isEmpty {
                lines.append("Tags: " + tags.map { "#\($0)" }.joined(separator: " "))
                lines.append("")
            }
            let blocks = (page.textBlocks ?? []).sorted { ($0.frameY, $0.frameX) < ($1.frameY, $1.frameX) }
            for block in blocks where !block.content.isEmpty {
                lines.append(markdownLists(block.content))
                lines.append("")
            }
            if let handwriting = page.recognizedTextCache?.trimmingCharacters(in: .whitespacesAndNewlines),
               !handwriting.isEmpty {
                lines.append("> \(handwriting)")
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// A text box's list prefixes (`TextList`) as Markdown lists.
    static func markdownLists(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            if line.hasPrefix(TextList.bullet) { return "- " + line.dropFirst(TextList.bullet.count) }
            if line.hasPrefix(TextList.unchecked) { return "- [ ] " + line.dropFirst(TextList.unchecked.count) }
            if line.hasPrefix(TextList.checked) { return "- [x] " + line.dropFirst(TextList.checked.count) }
            return line
        }.joined(separator: "\n")
    }

    /// Writes every notebook as `<folders>/<title>.pdf` and `.md` under a
    /// new folder in `directory`, then zips it. Returns both. Rendering
    /// reads the models, so it runs here on the main actor, yielding
    /// between notebooks so the app stays responsive.
    static func makeArchive(of notebooks: [Notebook], documents: [ImportedDocument],
                            in directory: URL) async throws -> (folder: URL, zip: URL) {
        let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let root = directory.appendingPathComponent("Linework Library \(stamp)", isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        // The Markdown takes handwriting from the OCR cache, which only
        // search fills: read any page it has not seen yet.
        for notebook in notebooks {
            if let context = notebook.modelContext {
                await HandwritingRecognizer.indexAllIfNeeded(pages: notebook.pages ?? [], modelContext: context)
            }
        }
        let stacked = ImportedDocument.stacksByPage(documents)
        var used: Set<String> = []
        for notebook in notebooks {
            let folder = folderPath(of: notebook.folder).reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var name = safe(notebook.title.isEmpty ? "Notebook" : notebook.title)
            var copy = 2
            // Lowercased: the file system ignores case, so "Notes" and "notes"
            // would be one file and the second would replace the first.
            while used.contains(folder.appendingPathComponent(name).path.lowercased()) { name = "\(safe(notebook.title)) (\(copy))"; copy += 1 }
            used.insert(folder.appendingPathComponent(name).path.lowercased())

            let pages = (notebook.pages ?? []).sorted { $0.index < $1.index }
            if !pages.isEmpty {
                let pdf = PageRenderer.pdfData(for: pages.map { ($0, ArtworkLayer.stack(for: $0, stacked: stacked)) })
                try pdf.write(to: folder.appendingPathComponent("\(name).pdf"), options: .atomic)
            }
            try Data(markdown(for: notebook).utf8).write(to: folder.appendingPathComponent("\(name).md"), options: .atomic)
            await Task.yield()
        }

        let zip = directory.appendingPathComponent("\(root.lastPathComponent).zip")
        try? fm.removeItem(at: zip)
        try zipDirectory(root, to: zip)
        return (root, zip)
    }

    /// A coordinated read with `.forUploading` hands back a zipped copy of
    /// a directory - Foundation's own zip, no dependency.
    nonisolated static func zipDirectory(_ directory: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: directory, options: .forUploading, error: &coordinationError) { zipped in
            do { try FileManager.default.copyItem(at: zipped, to: destination) } catch { copyError = error }
        }
        if let error = coordinationError ?? copyError { throw error }
    }

    private static func folderPath(of folder: Folder?) -> [String] {
        var names: [String] = []
        var current = folder
        while let folder = current, names.count < 32 {
            names.insert(safe(folder.name.isEmpty ? "Folder" : folder.name), at: 0)
            current = folder.parentFolder
        }
        return names
    }

    private static func safe(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }
}
#endif
