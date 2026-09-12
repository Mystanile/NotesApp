import SwiftUI
import UniformTypeIdentifiers

/// App settings (plan Phase 6). Preferences live in `UserDefaults` via
/// `@AppStorage` (matching the keys in `AppSettings`), and take effect when a
/// canvas is opened or a notebook is created.
struct SettingsView: View {
    @AppStorage(AppSettings.Keys.toolType) private var toolType = "pen"
    @AppStorage(AppSettings.Keys.inkWidth) private var inkWidth: Double = 4
    @AppStorage(AppSettings.Keys.template) private var defaultTemplate = "blank"
    @AppStorage(AppSettings.Keys.appearance) private var appearance = "system"
    @AppStorage(AppSettings.Keys.signedInDisplayName) private var signedInDisplayName = ""
    @AppStorage(AppSettings.Keys.isSignedIn) private var isSignedIn = false
    @AppStorage(AppSettings.Keys.isGuestMode) private var isGuestMode = false
    @AppStorage(AppSettings.Keys.syncFolderName) private var syncFolderName = ""

    @ObservedObject private var sync = SyncEngine.shared
    @State private var showingFolderPicker = false
    @State private var diagnosticsMessage: String?

    private let toolOptions: [(id: String, label: String)] = [
        ("pen", "Pen"),
        ("pencil", "Pencil"),
        ("marker", "Marker"),
        ("fountain", "Fountain Pen"),
        ("monoline", "Monoline"),
    ]

    private let templateOptions: [(id: String, label: String)] = [
        ("blank", "Blank"),
        ("lined", "Lined"),
        ("grid", "Grid"),
        ("dotted", "Dotted"),
    ]

    var body: some View {
        Form {
            Section {
                Picker("Default Tool", selection: $toolType) {
                    ForEach(toolOptions, id: \.id) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                ColorPicker("Default Ink Color", selection: inkColorBinding)
                Stepper("Ink Width: \(Int(inkWidth)) pt", value: $inkWidth, in: 1...20)
            } header: {
                Text("Pen")
            } footer: {
                Text("Applied to a page when you open it.")
            }

            Section {
                Picker("Default Template", selection: $defaultTemplate) {
                    ForEach(templateOptions, id: \.id) { option in
                        Text(option.label).tag(option.id)
                    }
                }
            } header: {
                Text("Paper")
            } footer: {
                Text("Used for the first page of a new notebook.")
            }

            Section {
                Picker("Theme", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
            } header: {
                Text("Appearance")
            }

            Section {
                if syncFolderName.isEmpty {
                    Button("Choose Sync Folder…") { showingFolderPicker = true }
                } else {
                    LabeledContent("Folder", value: syncFolderName)
                    Button("Sync Now") { SyncEngine.shared.syncNow() }
                        .disabled(sync.status == .syncing)
                    Button("Choose a Different Folder…") { showingFolderPicker = true }
                    Button("Turn Off Folder Sync", role: .destructive) { SyncEngine.shared.clearFolder() }
                    #if DEBUG
                    // Spike tooling for Docs/SPIKE_ICLOUD_CONFLICTS.md.
                    Button("Write Sync Diagnostics") {
                        switch SyncDiagnostics.write() {
                        case .success(let url): diagnosticsMessage = "Wrote \(url.lastPathComponent)"
                        case .failure(let error): diagnosticsMessage = error.localizedDescription
                        }
                    }
                    if let diagnosticsMessage {
                        Text(diagnosticsMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                    #endif
                }
                LabeledContent("Status") {
                    Text(syncStatusText)
                        .foregroundStyle(isSyncFailed ? Color.red : Color.secondary)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Sync")
            } footer: {
                Text("Pick a folder inside iCloud Drive (or any folder a sync service keeps mirrored). Mystnotes writes your library and its drawings there about half a minute after you stop editing and whenever it goes to the background, and reads changes back when it opens or you tap Sync Now. Edits merge page by page, so two devices can work on different pages of the same notebook offline. If both change the same page, the more recent version is shown and the other is kept in the folder's trash.")
            }

            Section {
                if isSignedIn {
                    if !signedInDisplayName.isEmpty {
                        LabeledContent("Signed in as", value: signedInDisplayName)
                    }
                    Button("Sign Out", role: .destructive) {
                        AppSettings.signOut()
                    }
                } else if isGuestMode {
                    Text("Using Mystnotes without an account.")
                        .foregroundStyle(.secondary)
                    Button("Sign In with Apple") {
                        AppSettings.exitGuestMode()
                    }
                }
            } header: {
                Text("Account")
            }

            Section("About") {
                LabeledContent("Version", value: versionString)
            }
        }
        .navigationTitle("Settings")
        .fileImporter(isPresented: $showingFolderPicker, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            SyncEngine.shared.chooseFolder(url)
        }
    }

    private var isSyncFailed: Bool {
        if case .failed = sync.status { return true }
        return false
    }

    private var syncStatusText: String {
        switch sync.status {
        case .idle:
            return syncFolderName.isEmpty ? "Not set up" : "Ready"
        case .syncing:
            return "Syncing…"
        case .succeeded(let date):
            return "Last synced \(date.formatted(date: .abbreviated, time: .shortened))"
        case .waiting(let message):
            return message
        case .failed(let message):
            return message
        }
    }

    /// `@AppStorage` can't hold a SwiftUI `Color`, so bridge through the hex
    /// string in `AppSettings`.
    private var inkColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: AppSettings.defaultInkColorHex) },
            set: { AppSettings.defaultInkColorHex = $0.toHex() }
        )
    }

    private var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            ?? "1.0"
    }
}