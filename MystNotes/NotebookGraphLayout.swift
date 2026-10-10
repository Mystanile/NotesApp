import Foundation
import CoreGraphics

extension Notebook {
    /// Page Map positions the user set, in fractions (0...1) of the map.
    var graphPositions: [UUID: CGPoint] {
        guard let data = graphLayout?.data(using: .utf8),
              let raw = try? JSONDecoder().decode([String: [Double]].self, from: data) else { return [:] }
        var result: [UUID: CGPoint] = [:]
        for (key, xy) in raw where xy.count == 2 {
            if let id = UUID(uuidString: key) { result[id] = CGPoint(x: xy[0], y: xy[1]) }
        }
        return result
    }

    /// Stores one card's position (clamped to the map) as a settings change.
    func setGraphPosition(_ point: CGPoint, forPageID id: UUID, at date: Date = Date()) {
        var raw = graphPositions.reduce(into: [String: [Double]]()) { $0[$1.key.uuidString] = [$1.value.x, $1.value.y] }
        raw[id.uuidString] = [min(max(point.x, 0), 1), min(max(point.y, 0), 1)]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        graphLayout = (try? encoder.encode(raw)).flatMap { String(data: $0, encoding: .utf8) }
        markSettingsModified(at: date)
    }
}
