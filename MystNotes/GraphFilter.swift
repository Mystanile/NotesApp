import Foundation

/// M2 task 11: the kinds of edge the Page Map draws. Filtering by kind hides
/// edges only; it never moves a card.
nonisolated enum EdgeKind: String, CaseIterable, Hashable, Sendable {
    /// A plain link (`Link.kind == nil`).
    case explicit
    /// A `[[ ]]` mention from a text block.
    case mention
    /// A node's ink shown on another page.
    case transclusion
    /// Derived: a page carries a tag.
    case tag

    var title: String {
        switch self {
        case .explicit: return "Links"
        case .mention: return "Mentions"
        case .transclusion: return "Transclusions"
        case .tag: return "Tags"
        }
    }

    var systemImage: String {
        switch self {
        case .explicit: return "arrow.right"
        case .mention: return "text.bubble"
        case .transclusion: return "rectangle.on.rectangle"
        case .tag: return "number"
        }
    }
}

/// What the graph needs to know about one page, as plain values: filterable
/// and layout-able off the main actor and in tests without SwiftData.
nonisolated struct GraphPageInfo: Hashable, Sendable {
    var id: UUID
    var index: Int
    var title: String?
    var tags: [String]
    var modifiedAt: Date?
    /// Recognized handwriting, for search.
    var text: String

    init(id: UUID = UUID(), index: Int = 0, title: String? = nil, tags: [String] = [],
         modifiedAt: Date? = nil, text: String = "") {
        self.id = id
        self.index = index
        self.title = title
        self.tags = tags
        self.modifiedAt = modifiedAt
        self.text = text
    }

    @MainActor
    init(page: Page) {
        self.init(id: page.id, index: page.index, title: page.title, tags: page.tags ?? [],
                  modifiedAt: page.modifiedAt, text: page.recognizedTextCache ?? "")
    }

    /// "p. N · title", or "p. N".
    var label: String {
        guard let title, !title.isEmpty else { return "p. \(index + 1)" }
        return "p. \(index + 1) · \(title)"
    }
}

/// M2 task 11: what the user narrowed the map to. Pure.
///
/// Filtering never hides a card, because hiding would change the layout
/// under the user's eyes. Pages that don't match are *dimmed*; edge kinds
/// that are switched off are *hidden*.
nonisolated struct GraphFilter: Equatable, Sendable {
    /// Tag keys (lowercased). A page matches if it carries any of them.
    var tags: Set<String> = []
    /// Only pages edited at or after this date. A page that predates
    /// `modifiedAt` (nil) does not match.
    var since: Date?
    /// The edge kinds to show. Empty means all of them.
    var kinds: Set<EdgeKind> = []
    var searchText: String = ""

    struct Result: Equatable, Sendable {
        /// Pages that don't match every active criterion.
        var dimmedPageIDs: Set<UUID> = []
        /// Pages that match an active search: they get a ring.
        var highlightedPageIDs: Set<UUID> = []
        var hiddenEdgeKinds: Set<EdgeKind> = []
    }

    static let dimmedOpacity: Double = 0.15

    var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// True when any criterion narrows the page set.
    var dimsPages: Bool { !tags.isEmpty || since != nil || !query.isEmpty }

    var isActive: Bool { dimsPages || !kinds.isEmpty }

    func shows(_ kind: EdgeKind) -> Bool { kinds.isEmpty || kinds.contains(kind) }

    /// Switches one kind on or off. The last visible kind can't be switched
    /// off (an empty set means "all"), and switching everything back on
    /// returns to the empty set.
    func toggling(_ kind: EdgeKind) -> GraphFilter {
        var visible = kinds.isEmpty ? Set(EdgeKind.allCases) : kinds
        if visible.contains(kind) {
            guard visible.count > 1 else { return self }
            visible.remove(kind)
        } else {
            visible.insert(kind)
        }
        var copy = self
        copy.kinds = visible.count == EdgeKind.allCases.count ? [] : visible
        return copy
    }

    func togglingTag(_ name: String) -> GraphFilter {
        var copy = self
        let key = name.lowercased()
        if copy.tags.contains(key) { copy.tags.remove(key) } else { copy.tags.insert(key) }
        return copy
    }

    func apply(to pages: [GraphPageInfo]) -> Result {
        var result = Result()
        result.hiddenEdgeKinds = Set(EdgeKind.allCases.filter { !shows($0) })
        guard dimsPages else { return result }
        let needle = query
        for page in pages {
            var matches = true
            if !tags.isEmpty {
                matches = matches && page.tags.contains { tags.contains($0.lowercased()) }
            }
            if let since {
                matches = matches && (page.modifiedAt.map { $0 >= since } ?? false)
            }
            if !needle.isEmpty {
                let hit = Self.matches(page, query: needle)
                matches = matches && hit
                if hit { result.highlightedPageIDs.insert(page.id) }
            }
            if !matches { result.dimmedPageIDs.insert(page.id) }
        }
        // A ring only on pages that survive the other criteria too.
        result.highlightedPageIDs.subtract(result.dimmedPageIDs)
        return result
    }

    private static func matches(_ page: GraphPageInfo, query: String) -> Bool {
        if let title = page.title, title.localizedStandardContains(query) { return true }
        if page.tags.contains(where: { $0.localizedStandardContains(query) }) { return true }
        if "p. \(page.index + 1)".localizedStandardContains(query) { return true }
        return !page.text.isEmpty && page.text.localizedStandardContains(query)
    }
}
