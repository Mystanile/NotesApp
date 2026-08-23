import SwiftUI
import SwiftData

/// A search hit: a single page whose text matched, plus enough context to
/// open the notebook at that page and show why it matched.
struct SearchResult: Hashable {
    let notebook: Notebook
    let pageID: UUID
    let pageNumber: Int
    let snippet: String
}

/// Global search across every notebook. On first appearance it runs the
/// (possibly slow) OCR pass over any page whose drawing hasn't been indexed
/// yet, then filters the typed-text, OCR, and PDF text blobs in memory on each
/// keystroke — no re-recognition after that initial pass.
struct SearchResultsView: View {
    let query: String

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Notebook.title) private var allNotebooks: [Notebook]
    @Query private var allImportedDocuments: [ImportedDocument]

    @State private var results: [SearchResult] = []
    @State private var isIndexing = true

    /// ImportedDocument has no inverse relationship from Page, so map page id
    /// -> its import record once here (reduce to avoid a trap if two ever share
    /// a page).
    private var docByPageID: [UUID: ImportedDocument] {
        allImportedDocuments.reduce(into: [:]) { dict, doc in
            if let page = doc.page { dict[page.id] = doc }
        }
    }

    private var allPages: [Page] {
        allNotebooks.flatMap { $0.pages ?? [] }
    }

    var body: some View {
        Group {
            if isIndexing {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Indexing handwriting for search…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if results.isEmpty {
                ContentUnavailableView(
                    "No results for “\(query)”",
                    systemImage: "magnifyingglass",
                    description: Text("Try a different word, or check the spelling.")
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
        .task { await indexThenSearch() }
        .onChange(of: query) { _, _ in computeResults() }
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

    // MARK: - Indexing & matching

    private func indexThenSearch() async {
        await HandwritingRecognizer.indexAllIfNeeded(pages: allPages, modelContext: modelContext)
        isIndexing = false
        computeResults()
    }

    private func computeResults() {
        let needles = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needles.isEmpty else { results = []; return }

        var found: [SearchResult] = []
        for notebook in allNotebooks {
            let pages = (notebook.pages ?? []).sorted { $0.index < $1.index }
            for (index, page) in pages.enumerated() {
                let blob = SearchIndex.searchableText(for: page, importedDocument: docByPageID[page.id])
                guard blob.contains(needles) else { continue }
                found.append(SearchResult(
                    notebook: notebook,
                    pageID: page.id,
                    pageNumber: index + 1,
                    snippet: snippet(in: blob, needles: needles)
                ))
            }
        }
        results = found
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