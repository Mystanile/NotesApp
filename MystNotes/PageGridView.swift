import SwiftUI

/// Which pages of the Page Grid are ticked. A plain value so the rules
/// (toggle, select all, whether Delete is allowed) are testable without a view.
nonisolated struct PageGridSelection: Equatable {
    private(set) var ids: Set<UUID> = []

    var count: Int { ids.count }
    var isEmpty: Bool { ids.isEmpty }

    func contains(_ id: UUID) -> Bool { ids.contains(id) }

    mutating func toggle(_ id: UUID) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
    }

    mutating func selectAll(_ all: [UUID]) { ids = Set(all) }
    mutating func clear() { ids = [] }

    /// True when every one of `all` is ticked (and there is at least one).
    func isAllSelected(of all: [UUID]) -> Bool {
        !all.isEmpty && all.allSatisfy { ids.contains($0) }
    }

    /// The ticked pages in notebook order, ignoring ids that are gone.
    func ordered(in all: [UUID]) -> [UUID] { all.filter { ids.contains($0) } }

    /// A notebook always keeps one page: deleting is allowed only when
    /// something is ticked and at least one page would remain.
    func canDelete(totalPages: Int) -> Bool {
        !ids.isEmpty && ids.count < totalPages
    }

    /// "Delete 3 pages?" copy for the confirmation dialog.
    static func deleteTitle(count: Int) -> String {
        "Delete \(count) \(count == 1 ? "page" : "pages")?"
    }
}

/// Every page of the open notebook as a grid of thumbnails, with multi-select.
/// The documents come from the parent (one fetch for the whole notebook), never
/// a `@Query` per cell.
struct PageGridView: View {
    let pages: [Page]
    var documentsByPageID: [UUID: [ImportedDocument]] = [:]
    /// Transcluded ink by host page id, resolved once by the parent.
    var transclusionsByPageID: [UUID: [PageElements.Transclusion]] = [:]
    var currentPageID: UUID?
    var onOpen: (UUID) -> Void
    var onDelete: ([UUID]) -> Void
    var onDuplicate: ([UUID]) -> Void
    var onCopyTo: ([UUID]) -> Void
    var onExport: ([UUID]) -> Void
    /// Moves a page to a zero-based index. Offered as Move to Start / End
    /// in each cell's menu; nil hides them.
    var onMove: ((UUID, Int) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var selection = PageGridSelection()
    @State private var selecting = false
    @State private var confirmingDelete = false

    private let thumbnailHeight: CGFloat = 150
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 130, maximum: 240), spacing: Space.l, alignment: .top)]
    }
    private var allIDs: [UUID] { pages.map(\.id) }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: Space.l) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                        cell(index: index, page: page)
                    }
                }
                .padding(Space.l)
            }
            .navigationTitle(selecting ? selectionTitle : "All Pages")
            #if os(iOS) || targetEnvironment(macCatalyst)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { topToolbar }
            .safeAreaInset(edge: .bottom) {
                if selecting { actionBar }
            }
            .confirmationDialog(PageGridSelection.deleteTitle(count: selection.count),
                                isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete \(selection.count) \(selection.count == 1 ? "Page" : "Pages")", role: .destructive) {
                    let ids = selection.ordered(in: allIDs)
                    dismiss()
                    onDelete(ids)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Delete \(selection.count) \(selection.count == 1 ? "page" : "pages")? They go to the trash and can be restored for 30 days.")
            }
        }
    }

    private var selectionTitle: String {
        selection.isEmpty ? "Select Pages" : "\(selection.count) Selected"
    }

    // MARK: Cells

    private func cell(index: Int, page: Page) -> some View {
        let isCurrent = page.id == currentPageID
        let isPicked = selection.contains(page.id)
        let title = (page.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let label = title.isEmpty ? "Page \(index + 1)" : "Page \(index + 1), \(title)"
        return Button {
            if selecting {
                selection.toggle(page.id)
            } else {
                dismiss()
                onOpen(page.id)
            }
        } label: {
            VStack(spacing: Space.xs) {
                PageThumbnailView(page: page,
                                  importedDocuments: documentsByPageID[page.id] ?? [],
                                  isSelected: isCurrent,
                                  height: thumbnailHeight,
                                  transclusions: transclusionsByPageID[page.id] ?? [])
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Palette.selectionRing, lineWidth: isCurrent || isPicked ? 3 : 0)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if selecting {
                            Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                                .font(.title2)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(isPicked ? Color.white : Color.secondary,
                                                 isPicked ? Palette.selectionRing : Color.clear)
                                .background(Circle().fill(.thinMaterial))
                                .padding(Space.xs)
                        }
                    }
                Text("\(index + 1)")
                    .font(Typography.label)
                    .foregroundStyle(isCurrent ? Palette.selectionRing : .primary)
                if !title.isEmpty {
                    Text(title)
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: Metrics.minHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(isCurrent ? "Current page" : "")
        .accessibilityAddTraits(selecting && isPicked ? [.isButton, .isSelected] : .isButton)
        .contextMenu {
            if let onMove {
                Button("Move to Start", systemImage: "arrow.up.to.line") { onMove(page.id, 0) }
                    .disabled(index == 0)
                Button("Move to End", systemImage: "arrow.down.to.line") { onMove(page.id, pages.count - 1) }
                    .disabled(index == pages.count - 1)
            }
        }
    }

    // MARK: Toolbars

    @ToolbarContentBuilder
    private var topToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(selecting ? "Cancel" : "Close") {
                if selecting {
                    selecting = false
                    selection.clear()
                } else {
                    dismiss()
                }
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            if selecting {
                Button(selection.isAllSelected(of: allIDs) ? "Deselect All" : "Select All") {
                    if selection.isAllSelected(of: allIDs) { selection.clear() } else { selection.selectAll(allIDs) }
                }
            } else {
                Button("Select") { selecting = true }
            }
        }
    }

    private var actionBar: some View {
        let ids = selection.ordered(in: allIDs)
        return HStack {
            barButton("Duplicate", "plus.square.on.square") { onDuplicate(ids); exitSelection() }
                .disabled(selection.isEmpty)
            Spacer()
            barButton("Copy to Notebook\u{2026}", "doc.on.doc") { dismiss(); onCopyTo(ids) }
                .disabled(selection.isEmpty)
            Spacer()
            barButton("Export", "square.and.arrow.up") { dismiss(); onExport(ids) }
                .disabled(selection.isEmpty)
            Spacer()
            Button(role: .destructive) { confirmingDelete = true } label: {
                Label("Delete", systemImage: "trash").labelStyle(.titleAndIcon)
            }
            .disabled(!selection.canDelete(totalPages: pages.count))
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
        .background(.bar)
    }

    private func barButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol).labelStyle(.titleAndIcon) }
    }

    private func exitSelection() {
        selecting = false
        selection.clear()
    }
}
