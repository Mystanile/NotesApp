import Foundation
import SwiftData
#if canImport(UIKit)
import PencilKit

/// Getting ink back out of the trash: a deleted page, or the losing side of
/// a same-page conflict, restored as a new page in "Recovered Pages". The
/// trashed file stays where it is and expires on its own schedule
/// (`TrashRetention`) - restoring copies, it never moves or removes.
enum TrashRestore {
    static let notebookTitle = "Recovered Pages"

    /// Trashed ink records - `.strokes`, or a pre-record `.drawing` -
    /// newest first. A record's render cache is trashed beside it as a
    /// second `.drawing`; the record is the one listed.
    nonisolated static func restorableInk(in directories: [URL]) -> [TrashRetention.Entry] {
        let entries = directories.flatMap { TrashRetention.entries(in: $0) }
        let records = entries.filter { $0.url.pathExtension == "strokes" }
        let recordBases = Set(records.map { base(of: $0.url) })
        let legacy = entries.filter { $0.url.pathExtension == "drawing" && !recordBases.contains(base(of: $0.url)) }
        return (records + legacy).sorted { $0.trashedAt > $1.trashedAt }
    }

    /// The ink in a trashed file, or nil if it doesn't read.
    nonisolated static func drawing(in entry: TrashRetention.Entry) -> PKDrawing? {
        guard let data = try? Data(contentsOf: entry.url) else { return nil }
        if entry.url.pathExtension == "strokes" { return try? StrokeCodec.decode(data).drawing }
        return try? PKDrawing(data: data)
    }

    /// Saves the entry's ink as a new page at the end of "Recovered
    /// Pages", making that notebook if there isn't one. The caller saves
    /// the context.
    @MainActor
    @discardableResult
    static func restore(_ entry: TrashRetention.Entry, in context: ModelContext,
                        store: DrawingStore = .live) throws -> Page {
        guard let drawing = drawing(in: entry) else { throw CocoaError(.fileReadCorruptFile) }
        let notebooks = try context.fetch(FetchDescriptor<Notebook>())
        let notebook = notebooks.first { $0.title == notebookTitle } ?? {
            let made = Notebook(title: notebookTitle)
            context.insert(made)
            return made
        }()
        let page = Page(index: (notebook.pages ?? []).count, notebook: notebook)
        context.insert(page)
        notebook.pages = (notebook.pages ?? []) + [page]
        page.drawingFileRef = try store.save(drawing, pageID: page.id)
        page.markModified()
        return page
    }

    /// `<page-id>-<stamp>-<tag>`: the part before the stamp.
    nonisolated private static func base(of url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.split(separator: "-")
        return parts.count > 2 ? parts.dropLast(2).joined(separator: "-") : name
    }
}
#endif

#if canImport(UIKit)
import SwiftUI

/// Settings > Trash > Restore Pages: what's in the trash, newest first,
/// with a look at the ink, and a button to bring each back.
struct RestoreTrashView: View {
    let directories: [URL]
    @Environment(\.modelContext) private var modelContext
    @State private var items: [TrashRetention.Entry] = []
    @State private var restored: Set<URL> = []
    @State private var message: String?

    var body: some View {
        List {
            if items.isEmpty {
                Text("No pages in the trash.").foregroundStyle(.secondary)
            }
            ForEach(items, id: \.url) { item in
                HStack(spacing: 12) {
                    InkPreview(entry: item)
                        .frame(width: 60, height: 80)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.3)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.tag == "conflict" ? "Other version of a page" : "Deleted page")
                        Text(item.trashedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if restored.contains(item.url) {
                        Label("Restored", systemImage: "checkmark").labelStyle(.iconOnly).foregroundStyle(.green)
                    } else {
                        Button("Restore") { restore(item) }.buttonStyle(.bordered)
                    }
                }
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Restore Pages")
        .task {
            let directories = directories
            items = await Task.detached(priority: .utility) { TrashRestore.restorableInk(in: directories) }.value
        }
    }

    private func restore(_ item: TrashRetention.Entry) {
        do {
            try TrashRestore.restore(item, in: modelContext)
            try modelContext.save()
            restored.insert(item.url)
            message = "Restored pages are in the “\(TrashRestore.notebookTitle)” notebook."
        } catch {
            message = "Couldn't restore that page: \(error.localizedDescription)"
        }
    }
}

private struct InkPreview: View {
    let entry: TrashRetention.Entry
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit().padding(4) } else { Color.clear }
        }
        .task {
            let entry = entry
            image = await Task.detached(priority: .utility) { () -> UIImage? in
                guard let drawing = TrashRestore.drawing(in: entry), !drawing.bounds.isEmpty else { return nil }
                var rendered: UIImage?
                UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                    rendered = drawing.image(from: drawing.bounds.insetBy(dx: -10, dy: -10), scale: 0.5)
                }
                return rendered
            }.value
        }
    }
}
#endif
