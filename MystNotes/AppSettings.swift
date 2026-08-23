import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
import PencilKit
#endif

/// User preferences for the whole app, persisted in `UserDefaults`. SwiftUI
/// reads most of these through `@AppStorage` (same keys) for live bindings in
/// Settings; non-view code (e.g. the canvas) reads them through these static
/// accessors so everything stays in sync.
enum AppSettings {
    private static let defaults = UserDefaults.standard

    enum Keys {
        static let toolType = "defaultToolType"
        static let inkColorHex = "defaultInkColorHex"
        static let inkWidth = "defaultInkWidth"
        static let template = "defaultTemplate"
        static let appearance = "appearance"
    }

    // MARK: Pen defaults (applied to a fresh canvas)

    static var defaultToolType: String {
        get { defaults.string(forKey: Keys.toolType) ?? "pen" }
        set { defaults.set(newValue, forKey: Keys.toolType) }
    }

    static var defaultInkColorHex: String {
        get { defaults.string(forKey: Keys.inkColorHex) ?? "#000000" }
        set { defaults.set(newValue, forKey: Keys.inkColorHex) }
    }

    static var defaultInkWidth: Double {
        get { defaults.object(forKey: Keys.inkWidth) as? Double ?? 4 }
        set { defaults.set(newValue, forKey: Keys.inkWidth) }
    }

    /// The tool a fresh canvas should start with, from the user's settings.
    /// Falls back to a black pen at 4pt.
#if canImport(UIKit)
    static func initialTool() -> PKInkingTool {
        let color = UIColor(Color(hex: defaultInkColorHex))
        return PKInkingTool(inkType(for: defaultToolType), color: color, width: defaultInkWidth)
    }

    static func inkType(for name: String) -> PKInkingTool.InkType {
        switch name {
        case "pencil": return .pencil
        case "marker": return .marker
        case "fountain": return .fountainPen
        case "monoline": return .monoline
        default: return .pen
        }
    }
#endif

    // MARK: Paper defaults

    static var defaultTemplate: String {
        get { defaults.string(forKey: Keys.template) ?? "blank" }
        set { defaults.set(newValue, forKey: Keys.template) }
    }

    // MARK: Appearance

    static var appearance: String {
        get { defaults.string(forKey: Keys.appearance) ?? "system" }
        set { defaults.set(newValue, forKey: Keys.appearance) }
    }

    static var colorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    // MARK: Sync status (informational)

    /// True when the user is signed into iCloud with this device.
    static var isCloudAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    /// True when payload files (drawings/imports) are actually being written
    /// to the iCloud Drive container rather than the local sandbox. Note this
    /// is currently expected to be false — file sync is deferred until the
    /// user frees iCloud space (see MystNotes.entitlements).
    static var isUsingCloudStorage: Bool {
        let cloud = FileStore.baseDirectory()
        let local = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return cloud != local
    }
}