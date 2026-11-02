import Foundation

// MARK: - Library sorting
//
// Pure logic, no SwiftData: the library maps its notebooks and folders to
// `LibrarySortItem`s, sorts, and maps back. Everything here is testable
// without a model container (`LibrarySortTests`).

/// What the library is sorted by. Raw values are what `AppSettings` stores.
nonisolated enum LibrarySortKey: String, CaseIterable, Identifiable, Sendable {
    case modified, created, title, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .modified: return "Date Edited"
        case .created: return "Date Created"
        case .title: return "Title"
        case .custom: return "Custom"
        }
    }

    var systemImage: String {
        switch self {
        case .modified: return "clock"
        case .created: return "calendar"
        case .title: return "textformat"
        case .custom: return "hand.draw"
        }
    }
}

nonisolated struct LibrarySortOrder: Equatable, Sendable {
    var key: LibrarySortKey
    /// Ignored for `.custom`, which is always in the user's order.
    var ascending: Bool

    /// Title A-Z: how the library listed things before sorting existed.
    static let `default` = LibrarySortOrder(key: .title, ascending: true)
}

/// The five facts a sort needs about a notebook or a folder.
nonisolated struct LibrarySortItem: Equatable, Sendable {
    var id: UUID
    var title: String
    var created: Date
    var modified: Date
    var manualOrder: Double?
}

nonisolated enum LibrarySort {
    /// Two positions closer than this are renumbered instead of split.
    static let minimumGap = 1e-6

    /// `elements` in `order`. Total and stable: ties fall back to title,
    /// then newest edit, then id, so two devices list the same library the
    /// same way.
    static func sorted<T>(_ elements: [T], by order: LibrarySortOrder, item: (T) -> LibrarySortItem) -> [T] {
        let keyed = elements.map { (element: $0, item: item($0)) }
        return keyed.sorted { precedes($0.item, $1.item, order) }.map { $0.element }
    }

    static func precedes(_ a: LibrarySortItem, _ b: LibrarySortItem, _ order: LibrarySortOrder) -> Bool {
        switch order.key {
        case .custom:
            switch (a.manualOrder, b.manualOrder) {
            case let (x?, y?):
                if x != y { return x < y }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
            // Unordered items (new since the last arrange) by newest edit.
            if a.modified != b.modified { return a.modified > b.modified }
        case .modified:
            if a.modified != b.modified { return order.ascending ? a.modified < b.modified : a.modified > b.modified }
        case .created:
            if a.created != b.created { return order.ascending ? a.created < b.created : a.created > b.created }
        case .title:
            let result = a.title.localizedStandardCompare(b.title)
            if result != .orderedSame {
                return order.ascending ? result == .orderedAscending : result == .orderedDescending
            }
        }
        return tieBreak(a, b)
    }

    private static func tieBreak(_ a: LibrarySortItem, _ b: LibrarySortItem) -> Bool {
        let titles = a.title.localizedStandardCompare(b.title)
        if titles != .orderedSame { return titles == .orderedAscending }
        if a.modified != b.modified { return a.modified > b.modified }
        return a.id.uuidString < b.id.uuidString
    }

    // MARK: Custom order

    /// The value for an item dropped at `index` among the others.
    ///
    /// `orders` is the `manualOrder` of every *other* item of the level, in
    /// display order (the moved item is not in it); `index` is where the
    /// moved item lands, 0...orders.count. The value is the midpoint of its
    /// new neighbours, or the end neighbour -/+ 1.0 at either end. When no
    /// value can be chosen - the gap is under `minimumGap`, or a neighbour
    /// has no order yet - `value` is nil and `renumber` holds 1, 2, 3...
    /// for the whole level *including* the moved item, in its new order.
    static func manualOrder(movingTo index: Int, in orders: [Double?]) -> (value: Double?, renumber: [Double]?) {
        let position = min(max(index, 0), orders.count)
        let renumbered: (value: Double?, renumber: [Double]?) =
            (nil, (1...(orders.count + 1)).map { Double($0) })

        let hasBefore = position > 0
        let hasAfter = position < orders.count
        let before: Double? = hasBefore ? orders[position - 1] : nil
        let after: Double? = hasAfter ? orders[position] : nil

        switch (hasBefore, hasAfter) {
        case (false, false):
            return (1.0, nil)
        case (false, true):
            guard let next = after else { return renumbered }
            return (next - 1.0, nil)
        case (true, false):
            guard let previous = before else { return renumbered }
            return (previous + 1.0, nil)
        case (true, true):
            guard let previous = before else { return renumbered }
            // Items without an order sort after every numbered one, so
            // landing in front of them only needs to clear the last number.
            guard let next = after else { return (previous + 1.0, nil) }
            if next - previous < minimumGap { return renumbered }
            return ((previous + next) / 2, nil)
        }
    }

    /// The `manualOrder` values to write after `moved` was dropped into
    /// `finalOrder` (every id of the level, in display order after the
    /// move). One entry normally; every id when the level had to be
    /// renumbered.
    static func assignments(finalOrder ids: [UUID], moved: UUID, orders: [UUID: Double]) -> [UUID: Double] {
        guard let position = ids.firstIndex(of: moved) else { return [:] }
        let others = ids.filter { $0 != moved }
        let result = manualOrder(movingTo: position, in: others.map { orders[$0] })
        if let value = result.value { return [moved: value] }
        guard let numbers = result.renumber, numbers.count == ids.count else { return [:] }
        var assigned: [UUID: Double] = [:]
        for (id, number) in zip(ids, numbers) { assigned[id] = number }
        return assigned
    }

    /// 1, 2, 3... in the order given: what switching to Custom the first
    /// time writes, so the arrangement starts as the user last saw it.
    static func seed(visibleOrder ids: [UUID]) -> [UUID: Double] {
        var assigned: [UUID: Double] = [:]
        for (offset, id) in ids.enumerated() { assigned[id] = Double(offset + 1) }
        return assigned
    }

    /// `ids` with `moved` shifted by `delta` places (clamped to the ends);
    /// nil when it would not move.
    static func shifted(_ ids: [UUID], moving moved: UUID, by delta: Int) -> [UUID]? {
        guard let from = ids.firstIndex(of: moved) else { return nil }
        let to = min(max(from + delta, 0), ids.count - 1)
        guard to != from else { return nil }
        var result = ids
        result.remove(at: from)
        result.insert(moved, at: to)
        return result
    }
}
