import SwiftUI

// MARK: - Folder cell

struct FolderCellView: View {
    let folder: Folder

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.system(size: 44))
                .foregroundStyle(.blue)
            Text(folder.name.isEmpty ? "Untitled Folder" : folder.name)
                .font(.subheadline)
                .lineLimit(1)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

// MARK: - Notebook cover (reused wherever a notebook needs a visual thumbnail)

struct NotebookCoverView: View {
    let notebook: Notebook

    private var coverColor: Color {
        switch notebook.coverStyle {
        case "sunset": return .orange
        case "ocean": return .blue
        case "forest": return .green
        case "mono": return .gray
        case "berry": return .pink
        default: return .indigo
        }
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    LinearGradient(
                        colors: [coverColor.opacity(0.85), coverColor],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .aspectRatio(3.0 / 4.0, contentMode: .fit)

            Text(notebook.title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .padding(10)
                .lineLimit(2)
        }
    }
}

// MARK: - Notebook cell (cover + title + page count, used in the library grid)

struct NotebookCellView: View {
    let notebook: Notebook

    private var pageCount: Int {
        notebook.pages?.count ?? 0
    }

    var body: some View {
        VStack(spacing: 8) {
            NotebookCoverView(notebook: notebook)
            Text(notebook.title)
                .font(.subheadline)
                .lineLimit(1)
                .foregroundStyle(.primary)
            Text("\(pageCount) page\(pageCount == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
