import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Small hex <-> Color conversion utility. SwiftData/CloudKit can't store
/// a SwiftUI Color directly, so anything user-colorable (text blocks, and
/// potentially more later) persists as a plain hex string instead.
extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    func toHex() -> String {
    #if canImport(UIKit)
        guard let components = UIColor(self).cgColor.components, components.count >= 3 else {
            return "#000000"
        }
        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    #else
        // For macOS, we can't directly convert Color to CGColor components easily
        // Return a default value or implement a different approach if needed
        return "#000000"
    #endif
    }
}
