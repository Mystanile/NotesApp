import Foundation

/// `[[` in a text box mentions another page (BACKLOG, "M2 design").
nonisolated enum PageMentions {
    /// The text after a trailing `[[` that hasn't been closed, else nil.
    static func pendingQuery(in text: String) -> String? {
        guard let open = text.range(of: "[[", options: .backwards) else { return nil }
        let rest = text[open.upperBound...]
        return rest.contains("]]") || rest.contains("\n") ? nil : String(rest)
    }

    /// Replaces the trailing `[[partial` with `[[label]]`.
    static func completing(_ text: String, with label: String) -> String {
        guard let open = text.range(of: "[[", options: .backwards) else { return text }
        return String(text[..<open.lowerBound]) + "[[\(label)]]"
    }

    /// Every `[[ … ]]` token's inner text, untrimmed, in order.
    private static func tokens(in text: String) -> [String] {
        var out: [String] = []
        var cursor = text.startIndex
        while let open = text.range(of: "[[", range: cursor..<text.endIndex),
              let close = text.range(of: "]]", range: open.upperBound..<text.endIndex) {
            out.append(String(text[open.upperBound..<close.lowerBound]))
            cursor = close.upperBound
        }
        return out
    }

    /// The (trimmed, non-empty) labels inside the text's `[[ … ]]` tokens.
    static func labels(in text: String) -> Set<String> {
        Set(tokens(in: text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
    }

    /// True when the text holds at least one closed `[[ … ]]` token.
    static func hasTokens(in text: String) -> Bool { !tokens(in: text).isEmpty }

    /// One row of the `[[` menu.
    struct Suggestion: Equatable, Sendable {
        var pageID: UUID
        /// What is shown and what is inserted between the brackets.
        var label: String
    }

    /// A page the menu may offer. `title` is empty when the page has none.
    typealias Candidate = (id: UUID, title: String, notebookTitle: String, notebookID: UUID, pageNumber: Int)

    /// The open notebook's pages first ("p. N · Title"), then other
    /// notebooks' ("Notebook · p. N"); within each, a prefix match before a
    /// contains match, then page order. Case-insensitive; at most `limit`.
    @MainActor
    static func suggestions(query: String, current: Notebook?, pages: [Candidate], limit: Int = 6) -> [Suggestion] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let currentID = current?.id
        struct Hit { var group: Int; var rank: Int; var notebook: String; var number: Int; var suggestion: Suggestion }
        var hits: [Hit] = []
        for page in pages {
            let isHere = page.notebookID == currentID
            let label = isHere
                ? (page.title.isEmpty ? "p. \(page.pageNumber)" : "p. \(page.pageNumber) · \(page.title)")
                : "\(page.notebookTitle) · p. \(page.pageNumber)"
            var rank = 0
            if !needle.isEmpty {
                let candidates = [label, page.title, page.notebookTitle].map { $0.lowercased() }
                if candidates.contains(where: { !$0.isEmpty && $0.hasPrefix(needle) }) {
                    rank = 0
                } else if candidates.contains(where: { $0.contains(needle) }) {
                    rank = 1
                } else {
                    continue
                }
            }
            hits.append(Hit(group: isHere ? 0 : 1, rank: rank, notebook: page.notebookTitle.lowercased(),
                            number: page.pageNumber, suggestion: Suggestion(pageID: page.id, label: label)))
        }
        hits.sort { ($0.group, $0.rank, $0.notebook, $0.number) < ($1.group, $1.rank, $1.notebook, $1.number) }
        return hits.prefix(limit).map(\.suggestion)
    }
}
