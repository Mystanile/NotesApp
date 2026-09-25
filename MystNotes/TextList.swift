import Foundation

/// Bullets and checklists in a text box, kept in the text itself - a
/// "• " or "☐ "/"☑ " at the start of a line. Nothing new to store or sync,
/// and exports, thumbnails and Markdown carry the lists as they are.
nonisolated enum TextList {
    enum Style { case bullets, checklist }

    static let bullet = "• "
    static let unchecked = "☐ "
    static let checked = "☑ "
    private static let prefixes = [bullet, unchecked, checked]

    /// Every non-blank line gets the style's prefix - or, if every one
    /// already has it, loses it. Another list style is replaced.
    static func toggle(_ style: Style, in text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let filled = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allHaveIt = !filled.isEmpty && filled.allSatisfy { has(style, $0) }
        return lines.map { line in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
            let bare = strip(line)
            return allHaveIt ? bare : (style == .bullets ? bullet : unchecked) + bare
        }.joined(separator: "\n")
    }

    /// After a return typed at the end of a list item: the next item's
    /// prefix, or - on an empty item - the list ended. nil when the edit
    /// wasn't a return after a list line.
    static func continuing(from old: String, to new: String) -> String? {
        guard new.count == old.count + 1, new.hasSuffix("\n"), new.dropLast() == old else { return nil }
        let lastLine = old.components(separatedBy: "\n").last ?? ""
        guard let prefix = prefixes.first(where: { lastLine.hasPrefix($0) }) else { return nil }
        if lastLine == prefix {
            return String(old.dropLast(prefix.count))
        }
        return new + (prefix == checked ? unchecked : prefix)
    }

    /// Ticks or unticks the checklist item on the line holding `offset`.
    static func toggleCheck(atOffset offset: Int, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var start = 0
        for index in lines.indices {
            let end = start + lines[index].count
            if offset <= end {
                if lines[index].hasPrefix(unchecked) {
                    lines[index] = checked + lines[index].dropFirst(unchecked.count)
                } else if lines[index].hasPrefix(checked) {
                    lines[index] = unchecked + lines[index].dropFirst(checked.count)
                }
                break
            }
            start = end + 1
        }
        return lines.joined(separator: "\n")
    }

    private static func has(_ style: Style, _ line: String) -> Bool {
        style == .bullets ? line.hasPrefix(bullet) : (line.hasPrefix(unchecked) || line.hasPrefix(checked))
    }

    private static func strip(_ line: String) -> String {
        for prefix in prefixes where line.hasPrefix(prefix) { return String(line.dropFirst(prefix.count)) }
        return line
    }
}
