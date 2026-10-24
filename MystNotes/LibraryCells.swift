import SwiftUI

// MARK: - Folder cell

struct FolderCellView: View {
    let folder: Folder

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: folder.smartQuery == nil ? "folder.fill" : "folder.fill.badge.gearshape")
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
    /// Imported artwork by page id, handed down by the library (a `@Query`
    /// per cell would fetch the whole table once per cell). `nil` means this
    /// cover shows no page preview (the small "Recent" covers).
    var previewArtwork: [UUID: [ImportedDocument]]? = nil

    /// The most recently modified page that has ink; `nil` for a notebook
    /// with none, and always `nil` for a locked one.
    static func previewPage(of notebook: Notebook) -> Page? {
        guard notebook.isLocked != true else { return nil }
        return (notebook.pages ?? [])
            .filter { $0.drawingFileRef != nil }
            .max { ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast) }
    }

    private var coverColor: Color { Self.color(for: notebook.coverStyle) }

    static func color(for coverStyle: String) -> Color {
        switch coverStyle {
        case "sunset": return .orange
        case "ocean": return .blue
        case "forest": return .green
        case "mono": return .gray
        case "berry": return .pink
        default: return .indigo
        }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let spine = max(6, w * 0.09)
            ZStack(alignment: .topLeading) {
                // Page edges peeking out on the right, under the cover.
                RoundedRectangle(cornerRadius: w * 0.06)
                    .fill(Color(white: 0.96))
                    .overlay(
                        RoundedRectangle(cornerRadius: w * 0.06)
                            .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
                    )
                    .offset(x: max(1.5, w * 0.02), y: max(1, w * 0.012))

                // The cover.
                RoundedRectangle(cornerRadius: w * 0.06)
                    .fill(LinearGradient(colors: [coverColor.opacity(0.88), coverColor],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))

                // The spine: a darker band with a soft highlight where it folds.
                UnevenRoundedRectangle(topLeadingRadius: w * 0.06, bottomLeadingRadius: w * 0.06)
                    .fill(coverColor.mix(with: .black, by: 0.28))
                    .frame(width: spine)
                Rectangle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: max(1, w * 0.012))
                    .offset(x: spine)

                // A paper label for the title.
                Text(notebook.title.isEmpty ? "Untitled" : notebook.title)
                    .font(.system(size: max(8, w * 0.085), weight: .semibold))
                    .foregroundStyle(Color(white: 0.2))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, w * 0.05)
                    .padding(.vertical, w * 0.035)
                    .frame(maxWidth: (w - spine) * 0.78, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: w * 0.025).fill(Color(white: 0.98)))
                    .offset(x: spine + (w - spine) * 0.11, y: geo.size.height * 0.14)

                // The latest page, small, under the label.
                if let artwork = previewArtwork, let page = Self.previewPage(of: notebook) {
                    let top = w * 0.52
                    let height = min(w * 0.6 / PageGeometry.aspectRatio(page.aspectRatio), geo.size.height - top - w * 0.07)
                    PageThumbnailView(page: page, importedDocuments: artwork[page.id] ?? [], height: height)
                        .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
                        .accessibilityHidden(true)
                        .frame(width: geo.size.width - spine)
                        .offset(x: spine, y: top)
                }
            }
            .shadow(color: .black.opacity(0.18), radius: max(1, w * 0.02), y: max(1, w * 0.015))
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
    }
}

// MARK: - Recent notebook cell (smaller cover, used in the horizontal "Recent" strip)

struct RecentNotebookCellView: View {
    let notebook: Notebook

    var body: some View {
        VStack(spacing: 6) {
            NotebookCoverView(notebook: notebook)
                .frame(width: 100)
            Text(notebook.title)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.primary)
                .frame(width: 100)
        }
    }
}

// MARK: - Notebook cell (cover + title + page count, used in the library grid)

struct NotebookCellView: View {
    let notebook: Notebook
    var previewArtwork: [UUID: [ImportedDocument]] = [:]

    private var pageCount: Int {
        notebook.pages?.count ?? 0
    }

    var body: some View {
        VStack(spacing: 8) {
            NotebookCoverView(notebook: notebook, previewArtwork: previewArtwork)
                .overlay(alignment: .topLeading) {
                    if notebook.isLocked == true {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(6)
                            .accessibilityLabel("Locked")
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if notebook.isFavorite == true {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .padding(6)
                            .accessibilityLabel("Favorite")
                    }
                }
            Text(notebook.title)
                .font(.subheadline)
                .lineLimit(1)
                .foregroundStyle(.primary)
            Text(Self.editedText(notebook.modifiedAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(notebook.title), \(pageCount) page\(pageCount == 1 ? "" : "s"), "
                            + Self.editedText(notebook.modifiedAt).lowercasedFirst
                            + (notebook.isLocked == true ? ", locked" : "")
                            + (notebook.isFavorite == true ? ", favorite" : ""))
    }

    /// "Edited today", "Edited yesterday", "Edited Tuesday" (within the last
    /// week), otherwise "Edited Oct 3".
    static func editedText(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        let format: String
        switch days {
        case ..<1: return "Edited today"
        case 1: return "Edited yesterday"
        case 2...6: format = "EEEE"
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            format = sameYear ? "MMM d" : "MMM d y"
        }
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate(format)
        return "Edited " + f.string(from: date)
    }
}

private extension String {
    /// "Edited today" reads better lowercase mid-sentence; "Edited Oct 3" keeps its date.
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
