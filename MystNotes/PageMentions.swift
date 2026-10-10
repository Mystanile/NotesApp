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
}
