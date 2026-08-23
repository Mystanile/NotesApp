import SwiftUI
import SwiftData

/// Modal sheet for picking a destination folder when moving a folder or
/// notebook. When moving a folder, pass it as `excludingFolder` so the
/// folder and its own descendants can't be selected as their own new
/// parent (that would create a cycle in the tree).
struct FolderPickerView: View {
    @Query(sort: \Folder.name) private var allFolders: [Folder]
    @Environment(\.dismiss) private var dismiss

    var excludingFolder: Folder?
    var onSelect: (Folder?) -> Void

    var body: some View {
        NavigationStack {
            List {
                Button {
                    onSelect(nil)
                    dismiss()
                } label: {
                    Label("My Library (Top Level)", systemImage: "house")
                }

                ForEach(rootFolders, id: \.id) { folder in
                    folderRow(folder, depth: 0)
                }
            }
            .navigationTitle("Move to…")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var rootFolders: [Folder] {
        allFolders.filter { $0.parentFolder == nil }
    }

    // NOTE: this function calls itself recursively (to render nested
    // subfolders), and SwiftUI's "some View" opaque return type cannot be
    // recursive — the compiler needs a single concrete type, and a
    // self-referential one is unresolvable. AnyView erases the type so
    // recursion is legal here.
    private func folderRow(_ folder: Folder, depth: Int) -> AnyView {
        guard !isExcluded(folder) else { return AnyView(EmptyView()) }

        return AnyView(
            Group {
                Button {
                    onSelect(folder)
                    dismiss()
                } label: {
                    Label(folder.name.isEmpty ? "Untitled Folder" : folder.name, systemImage: "folder")
                        .padding(.leading, CGFloat(depth) * 16)
                }
                .buttonStyle(.plain)

                ForEach(children(of: folder), id: \.id) { child in
                    folderRow(child, depth: depth + 1)
                }
            }
        )
    }

    private func children(of folder: Folder) -> [Folder] {
        allFolders.filter { $0.parentFolder?.id == folder.id }.sorted { $0.name < $1.name }
    }

    private func isExcluded(_ folder: Folder) -> Bool {
        guard let excluding = excludingFolder else { return false }
        var current: Folder? = folder
        while let c = current {
            if c.id == excluding.id { return true }
            current = c.parentFolder
        }
        return false
    }
}
