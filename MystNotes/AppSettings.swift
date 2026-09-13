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
        static let hasSeenOnboarding = "hasSeenOnboarding"
        static let hasSeededTutorialNotebook = "hasSeededTutorialNotebook"
        static let isSignedIn = "isSignedIn"
        static let signedInUserID = "signedInAppleUserID"
        static let signedInDisplayName = "signedInDisplayName"
        static let isGuestMode = "isGuestMode"
        static let syncFolderBookmark = "syncFolderBookmark"
        static let syncFolderName = "syncFolderName"
        static let lastAppliedRemoteSignature = "syncLastAppliedRemoteSignature"
        static let installID = "installID"
        static let lastPushSignature = "syncLastPushSignature"
        static let syncTombstones = "syncTombstones"
    }

    // MARK: Account (Sign in with Apple)

    /// Whether someone has completed Sign in with Apple on this device.
    /// `ContentView` gates the whole app on this (or `isGuestMode`) — no
    /// account and no guest choice means no library. Bound live via
    /// `@AppStorage` in `ContentView`/`SettingsView` so signing out from
    /// Settings immediately swaps back to the login screen.
    static var isSignedIn: Bool {
        get { defaults.bool(forKey: Keys.isSignedIn) }
        set { defaults.set(newValue, forKey: Keys.isSignedIn) }
    }

    /// True once someone has chosen "Continue Without an Account" on the
    /// login screen — an alternative way past `ContentView`'s gate that
    /// carries no Apple ID identity.
    static var isGuestMode: Bool {
        get { defaults.bool(forKey: Keys.isGuestMode) }
        set { defaults.set(newValue, forKey: Keys.isGuestMode) }
    }

    static func exitGuestMode() {
        isGuestMode = false
    }

    // MARK: Folder sync (the free-account alternative to CloudKit)

    /// Security-scoped bookmark to the user-chosen sync folder (typically in
    /// iCloud Drive). See `SyncFolder`.
    static var syncFolderBookmark: Data? {
        get { defaults.data(forKey: Keys.syncFolderBookmark) }
        set { defaults.set(newValue, forKey: Keys.syncFolderBookmark) }
    }

    /// Display name of that folder, for Settings.
    static var syncFolderName: String {
        get { defaults.string(forKey: Keys.syncFolderName) ?? "" }
        set { defaults.set(newValue, forKey: Keys.syncFolderName) }
    }

    /// Signature of the last remote snapshot this device fully applied or
    /// authored, so an unchanged folder isn't re-applied every foreground.
    static var lastAppliedRemoteSignature: String? {
        get { defaults.string(forKey: Keys.lastAppliedRemoteSignature) }
        set { defaults.set(newValue, forKey: Keys.lastAppliedRemoteSignature) }
    }

    /// A random id made once per install; the sync engine's device name
    /// carries its first characters so two devices' pushes can be told
    /// apart in the folder.
    static var installID: String {
        if let id = defaults.string(forKey: Keys.installID) { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: Keys.installID)
        return id
    }

    /// `LibrarySnapshot.signature` of the last snapshot this device pushed,
    /// so a no-op push is skipped.
    static var lastPushSignature: String {
        get { defaults.string(forKey: Keys.lastPushSignature) ?? "" }
        set { defaults.set(newValue, forKey: Keys.lastPushSignature) }
    }

    /// JSON-encoded `[Tombstone]` for folders/notebooks deleted on this
    /// device, so those deletions propagate through the next push instead of
    /// the item coming back from another device's snapshot.
    static var syncTombstonesData: Data? {
        get { defaults.data(forKey: Keys.syncTombstones) }
        set { defaults.set(newValue, forKey: Keys.syncTombstones) }
    }

    /// The stable identifier from `ASAuthorizationAppleIDCredential.user`,
    /// re-checked at launch via `getCredentialState` to catch a revoked
    /// sign-in. Stored in UserDefaults rather than Keychain to match this
    /// app's existing settings storage — fine for personal use; Keychain
    /// would be the more correct place for a real shipped multi-user app.
    static var signedInUserID: String {
        get { defaults.string(forKey: Keys.signedInUserID) ?? "" }
        set { defaults.set(newValue, forKey: Keys.signedInUserID) }
    }

    /// Display name captured the first time someone signs in — Apple only
    /// includes the name on that very first authorization for a given app,
    /// so every sign-in after that relies on this cached copy.
    static var signedInDisplayName: String {
        get { defaults.string(forKey: Keys.signedInDisplayName) ?? "" }
        set { defaults.set(newValue, forKey: Keys.signedInDisplayName) }
    }

    static func signOut() {
        isSignedIn = false
        isGuestMode = false
        signedInUserID = ""
        signedInDisplayName = ""
    }

    // MARK: First-run state

    /// Whether the swipeable "what is this app" onboarding has been shown.
    /// Set true the moment it's dismissed — it's shown at most once, ever.
    static var hasSeenOnboarding: Bool {
        get { defaults.bool(forKey: Keys.hasSeenOnboarding) }
        set { defaults.set(newValue, forKey: Keys.hasSeenOnboarding) }
    }

    /// Whether the auto-generated "Welcome to Mystnotes" notebook has already
    /// been created once. Checked instead of just "is the library empty" so
    /// deliberately deleting that notebook doesn't bring it back.
    static var hasSeededTutorialNotebook: Bool {
        get { defaults.bool(forKey: Keys.hasSeededTutorialNotebook) }
        set { defaults.set(newValue, forKey: Keys.hasSeededTutorialNotebook) }
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
        // .fixedUIColor, not UIColor(_:) - see its doc comment. A plain
        // UIColor(Color(hex:)) bridges to a *dynamic* color that silently
        // re-resolves against dark mode, which is exactly how a "black"
        // pen ended up drawing white ink.
        let color = Color(hex: defaultInkColorHex).fixedUIColor
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
}