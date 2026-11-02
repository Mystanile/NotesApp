import Foundation

/// Finds the web links in a text box's content, so the read-only box can make
/// them tappable. Pure; no UI.
nonisolated enum TextLinks {
    /// The URLs `NSDataDetector` finds in `text`, with their ranges, in order.
    /// Mail and phone links are skipped: only http(s) is opened from a note.
    static func ranges(in text: String) -> [(Range<String.Index>, URL)] {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return [] }
        let whole = NSRange(text.startIndex..<text.endIndex, in: text)
        var found: [(Range<String.Index>, URL)] = []
        for match in detector.matches(in: text, options: [], range: whole) {
            guard let url = match.url,
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let range = Range(match.range, in: text) else { continue }
            found.append((range, url))
        }
        return found
    }

    /// `text` with a `.link` attribute on every detected URL.
    static func attributed(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        for (range, url) in ranges(in: text) {
            if let lower = AttributedString.Index(range.lowerBound, within: result),
               let upper = AttributedString.Index(range.upperBound, within: result) {
                result[lower..<upper].link = url
            }
        }
        return result
    }
}
