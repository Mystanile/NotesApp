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

    /// A fixed RGBA snapshot of this color, independent of the current
    /// light/dark appearance. `UIColor(Color)` bridges to a *dynamic*
    /// UIColor that re-resolves against whatever trait collection happens
    /// to be active wherever it's later used - fine for UI chrome that
    /// should track appearance, wrong for anything that must stay exactly
    /// the color that was picked. That's exactly why a "black" pen was
    /// silently drawing white ink in dark mode and vice versa: PKInkingTool
    /// held onto a dynamic UIColor(Color.black), which re-resolved against
    /// the dark trait collection at draw time instead of staying black.
    /// `Color.resolve(in:)` gives a real fixed snapshot instead of a
    /// dynamic color, so use this for persisted hex values and ink colors.
    private var resolvedComponents: (red: Double, green: Double, blue: Double, opacity: Double) {
        let resolved = resolve(in: EnvironmentValues())
        return (Double(resolved.red), Double(resolved.green), Double(resolved.blue), Double(resolved.opacity))
    }

    func toHex() -> String {
        let c = resolvedComponents
        let r = Int((c.red * 255).rounded())
        let g = Int((c.green * 255).rounded())
        let b = Int((c.blue * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    #if canImport(UIKit)
    /// Use for anything that must render as the exact color picked,
    /// regardless of system appearance - PencilKit ink colors in
    /// particular. See `resolvedComponents`.
    var fixedUIColor: UIColor {
        let c = resolvedComponents
        return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: c.opacity)
    }
    #endif
}
