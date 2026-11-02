import SwiftUI

// MARK: - Folder cell

struct FolderCellView: View {
    let folder: Folder

    private var detail: String {
        if folder.smartQuery != nil { return "Smart folder" }
        let count = (folder.notebooks?.count ?? 0) + (folder.subfolders?.count ?? 0)
        return count == 0 ? "Empty" : "\(count) item\(count == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(spacing: Space.s) {
            Image(systemName: folder.smartQuery == nil ? "folder.fill" : "folder.fill.badge.gearshape")
                .font(.system(size: 40))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
            VStack(spacing: Space.xxs) {
                Text(folder.name.isEmpty ? "Untitled Folder" : folder.name)
                    .font(Typography.headline)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.l)
        .padding(.horizontal, Space.s)
        .background(
            RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                .strokeBorder(Palette.separator, lineWidth: Metrics.hairline)
        )
        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(folder.name.isEmpty ? "Untitled Folder" : folder.name), folder, \(detail)")
    }
}

/// Press feedback for library cells. `.plain` gives a `NavigationLink` none,
/// so a tap looked dead until the push began.
struct LibraryCellButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Body(configuration: configuration)
    }

    private struct Body: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .opacity(configuration.isPressed ? 0.8 : 1)
                .animation(reduceMotion ? nil : Motion.quick, value: configuration.isPressed)
        }
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
            // Two layers: a tight contact shadow and a soft ambient one.
            .shadow(color: .black.opacity(0.16), radius: max(1, w * 0.012), y: max(0.5, w * 0.006))
            .shadow(color: .black.opacity(0.10), radius: max(4, w * 0.07), y: max(2, w * 0.035))
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
    }
}

// MARK: - Recent notebook cell (smaller cover, used in the horizontal "Recent" strip)

struct RecentNotebookCellView: View {
    let notebook: Notebook

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            NotebookCoverView(notebook: notebook)
                .frame(width: 112)
                .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 112 * 0.06, style: .continuous))
                .hoverEffect(.lift)
            Text(notebook.title.isEmpty ? "Untitled" : notebook.title)
                .font(Typography.label)
                .lineLimit(1)
                .foregroundStyle(.primary)
                .frame(width: 112, alignment: .leading)
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
        VStack(alignment: .leading, spacing: Space.s) {
            NotebookCoverView(notebook: notebook, previewArtwork: previewArtwork)
                .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                .hoverEffect(.lift)
                .overlay(alignment: .topLeading) {
                    if notebook.isLocked == true {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(Space.s)
                            .shadow(color: .black.opacity(0.35), radius: 1.5)
                            .accessibilityLabel("Locked")
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if notebook.isFavorite == true {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .padding(Space.s)
                            .shadow(color: .black.opacity(0.35), radius: 1.5)
                            .accessibilityLabel("Favorite")
                    }
                }
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(notebook.title.isEmpty ? "Untitled" : notebook.title)
                    .font(Typography.headline)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text(Self.editedText(notebook.modifiedAt))
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
