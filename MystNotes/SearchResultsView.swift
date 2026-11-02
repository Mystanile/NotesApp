import SwiftUI
import SwiftData

/// A search hit: a single page whose text matched, plus enough context to
/// open the notebook at that page and show why it matched.
struct SearchResult: Hashable {
    let notebook: Notebook
    let pageID: UUID
    let pageNumber: Int
    let snippet: String
    /// The text that was searched for. Empty when the page was opened some
    /// other way (a link, the tag list), which also means no highlight.
    var query: String = ""
    /// Where the match is, in page (drawing) coordinates. Set for typed text
    /// (the block's frame). Nil for PDF text - mapping a PDF selection into
    /// page space needs the imported artwork's placement, which search does
    /// not have handy - and for handwriting, whose rect comes from
    /// `RecognizedLinesStore` when the page opens (`SearchHighlightLens`), so
    /// building the list never reads a file per hit.
    var matchRect: CGRect? = nil

    var highlight: SearchHighlight? {
        query.isEmpty ? nil : SearchHighlight(pageID: pageID, query: query, rect: matchRect, snippet: snippet)
    }
}

/// Global search across every notebook. Results come straight from cached
/// text; the handwriting index is kept current by `SearchIndexer` in the
/// background, and this view only shows how far along it is and refreshes as
/// pages finish. Typing never waits on recognition.
struct SearchResultsView: View {
    let query: String

    @Query(sort: \Notebook.title) private var allNotebooks: [Notebook]
    @Query private var allImportedDocuments: [ImportedDocument]

    @State private var results: [SearchResult] = []
    @State private var recomputeTask: Task<Void, Never>?
    private let indexer = SearchIndexer.shared

    private var allPages: [Page] {
        PageTemplates.libraryNotebooks(allNotebooks).flatMap { $0.pages ?? [] }
    }

    var body: some View {
        VStack(spacing: 0) {
            if indexer.pendingCount > 0 {
                indexingBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Group {
                if results.isEmpty {
                    ContentUnavailableView(
                        "No results for \u{201C}\(query)\u{201D}",
                        systemImage: "magnifyingglass",
                        description: Text(indexer.pendingCount > 0
                                          ? "Handwriting is still being indexed. More may appear."
                                          : "Try a different word, or check the spelling.")
                    )
                } else {
                    List(results, id: \.self) { result in
                        NavigationLink(value: result) {
                            row(for: result)
                        }
                    }
                    .listStyle(.plain)
                }
            }
        }
        .animation(Motion.quick, value: indexer.pendingCount > 0)
        .task {
            computeResults()
            indexer.requestRun()
        }
        .onChange(of: query) { _, _ in computeResults() }
        // A page finished indexing: it may now match.
        // Coalesced: a pass can finish pages in bursts.
        .onChange(of: indexer.completedCount) { _, _ in scheduleRecompute() }
        .onDisappear { recomputeTask?.cancel() }
        // A sync pull or a delete while the list is open.
        .onChange(of: allPages.count) { _, _ in computeResults() }
    }

    /// Slim and non-blocking: results stay usable underneath.
    private var indexingBanner: some View {
        HStack(spacing: Space.s) {
            ProgressView().controlSize(.small)
            Text("Indexing \(indexer.pendingCount) \(indexer.pendingCount == 1 ? "page" : "pages")\u{2026}")
                .font(Typography.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .surfaceCard(radius: Radius.m, elevated: false)
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.xs)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func row(for result: SearchResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.notebook.title)
                .font(.headline)
            HStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Page \(result.pageNumber)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !result.snippet.isEmpty {
                Text(result.snippet)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Matching

    private func scheduleRecompute() {
        recomputeTask?.cancel()
        recomputeTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            computeResults()
        }
    }

    private func computeResults() {
        SearchIndex.pruneBlobCache(keeping: Set(allPages.map(\.id)))
        let needles = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needles.isEmpty else { results = []; return }

        // ImportedDocument has no inverse relationship from Page, so map
        // page id -> its import records once per pass.
        let docsByPageID = ImportedDocument.stacksByPage(allImportedDocuments)

        var found: [SearchResult] = []
        // A locked notebook's text stays out of results until it's open.
        for notebook in allNotebooks where NotebookLock.shared.isOpen(notebook) {
            let pages = (notebook.pages ?? []).sorted { $0.index < $1.index }
            for (index, page) in pages.enumerated() {
                let blob = SearchIndex.cachedSearchableText(for: page, importedDocuments: docsByPageID[page.id] ?? [])
                guard blob.contains(needles) else { continue }
                found.append(SearchResult(
                    notebook: notebook,
                    pageID: page.id,
                    pageNumber: index + 1,
                    snippet: snippet(in: blob, needles: needles),
                    query: query.trimmingCharacters(in: .whitespacesAndNewlines),
                    matchRect: typedTextRect(in: page, needles: needles)
                ))
            }
        }
        results = found
    }

    /// The frame of the first typed text block containing the query, in page
    /// coordinates.
    private func typedTextRect(in page: Page, needles: String) -> CGRect? {
        guard let block = (page.textBlocks ?? []).first(where: { $0.content.lowercased().contains(needles) }) else {
            return nil
        }
        return CGRect(x: block.frameX, y: block.frameY, width: block.frameWidth, height: block.frameHeight)
    }

    /// A short window of text around the first match, so the result row shows
    /// *why* the page matched rather than the start of a long blob.
    private func snippet(in blob: String, needles: String) -> String {
        guard let range = blob.range(of: needles) else {
            return String(blob.prefix(80))
        }
        let lower = blob.index(range.lowerBound, offsetBy: -30, limitedBy: blob.startIndex) ?? blob.startIndex
        let upper = blob.index(range.upperBound, offsetBy: 40, limitedBy: blob.endIndex) ?? blob.endIndex
        var text = String(blob[lower..<upper]).replacingOccurrences(of: "\n", with: " ")
        if lower != blob.startIndex { text = "…" + text }
        if upper != blob.endIndex { text += "…" }
        return text
    }
}