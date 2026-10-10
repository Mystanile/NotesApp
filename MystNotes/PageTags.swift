import Foundation

/// M2 tags on pages (BACKLOG, "M2 design"): free text, compared without
/// case, shown as first typed.
enum PageTags {
    /// Trimmed, a leading "#" dropped, empties and case-insensitive
    /// duplicates removed (the first spelling wins), sorted.
    static func normalized(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for raw in tags {
            var tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            while tag.hasPrefix("#") { tag.removeFirst() }
            tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty, seen.insert(tag.lowercased()).inserted else { continue }
            result.append(tag)
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    struct Tag: Identifiable {
        let name: String
        let pages: [Page]
        var id: String { name.lowercased() }
    }

    /// Every tag in `pages` with the pages that carry it, by name.
    static func counts(in pages: [Page]) -> [Tag] {
        var names: [String: String] = [:]
        var byKey: [String: [Page]] = [:]
        for page in pages {
            for tag in page.tags ?? [] {
                let key = tag.lowercased()
                if names[key] == nil { names[key] = tag }
                byKey[key, default: []].append(page)
            }
        }
        return byKey.keys
            .map { Tag(name: names[$0]!, pages: byKey[$0]!) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

extension Page {
    /// Normalizes `tags`, and marks the page modified only if they changed.
    func setTags(_ tags: [String], at date: Date = Date()) {
        let new = PageTags.normalized(tags)
        let old = PageTags.normalized(self.tags ?? [])
        guard new.map({ $0.lowercased() }) != old.map({ $0.lowercased() }) else { return }
        self.tags = new.isEmpty ? nil : new
        markModified(at: date)
    }
}
