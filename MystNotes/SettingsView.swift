import SwiftUI

/// App settings (plan Phase 6). Preferences live in `UserDefaults` via
/// `@AppStorage` (matching the keys in `AppSettings`), and take effect when a
/// canvas is opened or a notebook is created.
struct SettingsView: View {
    @AppStorage(AppSettings.Keys.toolType) private var toolType = "pen"
    @AppStorage(AppSettings.Keys.inkWidth) private var inkWidth: Double = 4
    @AppStorage(AppSettings.Keys.template) private var defaultTemplate = "blank"
    @AppStorage(AppSettings.Keys.appearance) private var appearance = "system"

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
                LabeledContent("iCloud Drive", value: AppSettings.isCloudAvailable ? "Signed in" : "Not available")
                LabeledContent("Storage", value: AppSettings.isUsingCloudStorage ? "iCloud Drive" : "On this Mac")
            } header: {
                Text("Sync")
            } footer: {
                Text(AppSettings.isUsingCloudStorage
                     ? "Drawings and imports sync to iCloud Drive."
                     : "Drawings and imports are stored on this device only. File sync is deferred until iCloud storage is freed — see the app's CloudKit capabilities.")
            }

            Section("About") {
                LabeledContent("Version", value: versionString)
            }
        }
        .navigationTitle("Settings")
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