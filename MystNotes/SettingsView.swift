import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// App settings (plan Phase 6). Preferences live in `UserDefaults` via
/// `@AppStorage` (matching the keys in `AppSettings`), and take effect when a
/// canvas is opened or a notebook is created.
struct SettingsView: View {
    @AppStorage(AppSettings.Keys.toolType) private var toolType = "pen"
    @AppStorage(AppSettings.Keys.inkWidth) private var inkWidth: Double = 4
    @AppStorage(AppSettings.Keys.fingerDrawing) private var fingerDrawing = false
    @AppStorage(AppSettings.Keys.template) private var defaultTemplate = "blank"
    @AppStorage(AppSettings.Keys.appearance) private var appearance = "system"
    @AppStorage(AppSettings.Keys.paperColor) private var paperColor = PaperColor.white.rawValue
    @AppStorage(AppSettings.Keys.lineSpacing) private var lineSpacing = LineSpacingOption.normal.rawValue
    @AppStorage(AppSettings.Keys.signedInDisplayName) private var signedInDisplayName = ""
    @AppStorage(AppSettings.Keys.isSignedIn) private var isSignedIn = false
    @AppStorage(AppSettings.Keys.isGuestMode) private var isGuestMode = false
    @AppStorage(AppSettings.Keys.syncFolderName) private var syncFolderName = ""
    @AppStorage(AppSettings.Keys.hiddenToolbarItems) private var hiddenToolbarItems = ""

    @ObservedObject private var sync = SyncEngine.shared
    @State private var showingFolderPicker = false
    /// The one folder picker serves the sync folder and the backup folder:
    /// a view gets a single `.fileImporter` (see the gotcha).
    @State private var pickingBackupFolder = false
    @State private var backupName = Backup.displayName
    @State private var backupLastRun = Backup.lastRun
    @State private var backupMessage: String?
    @State private var isBackingUp = false
    @Environment(\.modelContext) private var modelContext
    @State private var diagnosticsMessage: String?
    @State private var confirmingRebuild = false
    @State private var diagnosticsArchive: URL?
    @State private var trash = TrashRetention.Summary()
    @State private var confirmingEmptyTrash = false
    @State private var isExportingLibrary = false
    @Query private var notebooks: [Notebook]
    @Query private var importedDocuments: [ImportedDocument]

    private let toolOptions: [(id: String, label: String)] = [
        ("pen", "Pen"),
        ("pencil", "Pencil"),
        ("marker", "Marker"),
        ("fountain", "Fountain Pen"),
        ("monoline", "Monoline"),
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
                Toggle("Draw with Finger", isOn: $fingerDrawing)
            } header: {
                Text("Pen")
            } footer: {
                Text("These apply when you open a page. With Draw with Finger off, Apple Pencil draws and your finger scrolls. With it on, your finger draws and two fingers scroll.")
            }

            Section {
                Picker("Default Template", selection: $defaultTemplate) {
                    ForEach(PageTemplate.options, id: \.id) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                Picker("Paper Colour", selection: $paperColor) {
                    ForEach(PaperColor.allCases, id: \.rawValue) { option in
                        Label {
                            Text(option.label)
                        } icon: {
                            PaperSwatch(style: PaperStyle(color: option, spacing: .normal))
                        }
                        .tag(option.rawValue)
                    }
                }
                Picker("Line Spacing", selection: $lineSpacing) {
                    ForEach(LineSpacingOption.allCases, id: \.rawValue) { option in
                        Label {
                            Text(option.label)
                        } icon: {
                            PaperSwatch(style: PaperStyle(color: .white, spacing: option))
                        }
                        .tag(option.rawValue)
                    }
                }
                NavigationLink {
                    PageTemplatesView()
                } label: {
                    Label("Page Templates", systemImage: "doc.on.doc")
                }
            } header: {
                Text("Paper & Templates")
            } footer: {
                Text("The default is the first page of a new notebook. Make your own paper from a PDF or a picture, then start new pages from it. Paper colour and line spacing are display preferences for this device. Dark paper is for writing only: exports and thumbnails use white paper.")
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
                NavigationLink {
                    AISettingsView()
                } label: {
                    Label("AI Study Helper", systemImage: "sparkles")
                }
            } header: {
                Text("AI Study Helper")
            } footer: {
                Text("Optional and off by default. Nothing is sent unless you ask.")
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
                    // Spike tooling for Docs/SPIKE_ICLOUD_CONFLICTS.md, and the
                    // one honest way to verify MetricKit delivers on device.
                    Button("Simulate Crash (Debug)", role: .destructive) {
                        AppLog.note("crash", "simulated crash requested from Settings")
                        fatalError("Simulated crash for MetricKit verification")
                    }
                    Button("Write Sync Diagnostics") {
                        diagnosticsMessage = "Writing…"
                        Task {
                            switch await SyncDiagnostics.write() {
                            case .success(let url): diagnosticsMessage = "Wrote \(url.lastPathComponent)"
                            case .failure(let error): diagnosticsMessage = error.localizedDescription
                            }
                        }
                    }
                    #endif
                }
                Button(syncFolderName.isEmpty ? "Rebuild Index…" : "Rebuild Index from Folder…") { confirmingRebuild = true }
                    .disabled(sync.status == .syncing)
                    .confirmationDialog(
                        syncFolderName.isEmpty ? "Rebuild the library index from the local copy?" : "Rebuild the library index from the sync folder?",
                        isPresented: $confirmingRebuild, titleVisibility: .visible
                    ) {
                        Button("Rebuild", role: .destructive) { SyncEngine.shared.rebuildIndex() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(syncFolderName.isEmpty
                             ? "Use this if notebooks or pages look wrong or missing. The library is reconstructed from the copy Linework keeps on this device."
                             : "Use this if notebooks or pages look wrong or missing. The library is reconstructed from what's in the folder. Any edit that never reached the folder is kept in the folder's trash.")
                    }
                Button(isExportingLibrary ? "Exporting Library…" : "Export Library…") {
                    exportLibrary()
                }
                .disabled(isExportingLibrary || notebooks.isEmpty)
                Button("Export Diagnostics…") {
                    Task {
                        let result = await Task.detached { Result { try DiagnosticsExport.makeArchive() } }.value
                        switch result {
                        case .success(let url): diagnosticsArchive = url
                        case .failure(let error): diagnosticsMessage = error.localizedDescription
                        }
                    }
                }
                if let diagnosticsMessage {
                    Text(diagnosticsMessage).font(.footnote).foregroundStyle(.secondary)
                }
                LabeledContent("Status") {
                    Text(syncStatusText)
                        .foregroundStyle(isSyncFailed ? Color.red : Color.secondary)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Sync")
            } footer: {
                Text("Pick a folder in iCloud Drive, or any folder a sync service keeps up to date. Linework saves your library there shortly after you stop writing, and reads changes back when it opens or when you tap Sync Now. Devices merge page by page. If two devices change the same page, the newer one is shown and the older one goes to the folder's trash.")
            }

            Section {
                if let backupName {
                    LabeledContent("Folder", value: backupName)
                    LabeledContent("Last backup",
                                   value: backupLastRun.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not yet")
                    Button(isBackingUp ? "Backing Up…" : "Back Up Now") { backUpNow() }
                        .disabled(isBackingUp)
                    Button("Stop Backing Up", role: .destructive) {
                        Backup.clear()
                        self.backupName = nil
                    }
                } else {
                    Button("Choose Backup Folder…") {
                        pickingBackupFolder = true
                        showingFolderPicker = true
                    }
                }
                if let backupMessage {
                    Text(backupMessage).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Backup")
            } footer: {
                Text("Once a day, Linework saves a copy of your whole library here. Pick a folder in Dropbox, Google Drive, OneDrive or on a drive. You get one file per weekday, so the last week is always there. To restore, unzip a backup and choose it as the sync folder.")
            }

            Section {
                #if canImport(UIKit)
                NavigationLink("Restore Pages…") { RestoreTrashView(directories: localTrashDirectories) }
                #endif
                if trash.isEmpty {
                    Text("Nothing in the trash.")
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Items", value: "\(trash.count)")
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(trash.bytes), countStyle: .file))
                    if let age = trash.age(at: Date()) {
                        LabeledContent("Oldest", value: "\(max(Int(age / 86400), 0)) days")
                    }
                    Button("Empty Trash Now…", role: .destructive) { confirmingEmptyTrash = true }
                        .confirmationDialog("Empty the trash on this device?",
                                            isPresented: $confirmingEmptyTrash, titleVisibility: .visible) {
                            Button("Empty Trash", role: .destructive) { emptyTrash() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Deleted pages, conflict copies and unused files are removed for good. Anything another device still has in its own trash is unaffected.")
                        }
                }
            } header: {
                Text("Trash")
            } footer: {
                Text("Deleted pages, older copies from sync conflicts and unused files wait here for 30 days. After that they are removed, on this device and in the sync folder.")
            }

            Section {
                ForEach(ToolbarItemChoice.allCases) { item in
                    Toggle(item.label, isOn: Binding(
                        get: { !ToolbarItemChoice.hidden(in: hiddenToolbarItems).contains(item) },
                        set: { shown in
                            var hidden = ToolbarItemChoice.hidden(in: hiddenToolbarItems)
                            if shown { hidden.remove(item) } else { hidden.insert(item) }
                            hiddenToolbarItems = ToolbarItemChoice.stored(hidden)
                        }
                    ))
                }
            } header: {
                Text("Toolbar")
            } footer: {
                Text("Choose which tools show in a notebook. The pen and eraser always stay.")
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
                    Text("You are using Linework without an account.")
                        .foregroundStyle(.secondary)
                    Button("Sign In with Apple") {
                        AppSettings.exitGuestMode()
                    }
                }
            } header: {
                Text("Account")
            }

            Section {
                VStack(spacing: Space.m) {
                    Image("BrandMark")
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 72 * 0.2237, style: .continuous))
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                        .accessibilityHidden(true)
                    VStack(spacing: Space.xxs) {
                        Text("Linework")
                            .font(Typography.title)
                        Text("Made for Apple Pencil.")
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Space.s)
                .accessibilityElement(children: .combine)
                LabeledContent("Version", value: versionString)
            } header: {
                Text("About")
            }
        }
        .navigationTitle("Settings")
        .task { await refreshTrash() }
        .sheet(item: $diagnosticsArchive) { url in
            ShareSheet(items: [url])
        }
        .fileImporter(isPresented: $showingFolderPicker, allowedContentTypes: [.folder]) { result in
            defer { pickingBackupFolder = false }
            guard case .success(let url) = result else { return }
            if pickingBackupFolder {
                do {
                    try Backup.setFolder(url)
                    backupName = Backup.displayName
                    backUpNow()
                } catch {
                    backupMessage = "Couldn't use that folder: \(error.localizedDescription)"
                }
            } else {
                SyncEngine.shared.chooseFolder(url)
            }
        }
    }

    /// Off the main thread (invariant 10): staging copies every payload.
    private func backUpNow() {
        isBackingUp = true
        backupMessage = nil
        let container = modelContext.container
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try Backup.run(container: container) } }.value
            isBackingUp = false
            switch result {
            case .success: backupLastRun = Backup.lastRun
            case .failure(let error): backupMessage = error.localizedDescription
            }
        }
    }

    /// Every notebook as a PDF and Markdown, in its folders, zipped
    /// (`LibraryExport`), to the share sheet.
    private func exportLibrary() {
        #if canImport(UIKit)
        isExportingLibrary = true
        Task {
            defer { isExportingLibrary = false }
            // Everything includes locked notebooks: prove it's the owner.
            if notebooks.contains(where: { $0.isLocked == true }),
               !(await NotebookLock.shared.authenticate("Export your whole library, including locked notebooks")) {
                return
            }
            do {
                let sorted = notebooks.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                let archive = try await LibraryExport.makeArchive(of: sorted, documents: importedDocuments,
                                                                  in: FileManager.default.temporaryDirectory)
                diagnosticsArchive = archive.zip
            } catch {
                diagnosticsMessage = "Couldn't export the library: \(error.localizedDescription)"
            }
        }
        #endif
    }

    /// Both off the main actor: they stat a directory that can hold a
    /// month of payloads.
    private func refreshTrash() async {
        let directories = localTrashDirectories
        trash = await Task.detached(priority: .utility) {
            TrashRetention.summary(of: directories)
        }.value
    }

    private func emptyTrash() {
        let directories = localTrashDirectories
        Task {
            await Task.detached(priority: .utility) { TrashRetention.emptyNow(directories) }.value
            await refreshTrash()
        }
    }

    private var localTrashDirectories: [URL] {
        TrashRetention.localDirectories(payloads: FileStore.baseDirectory(),
                                        mirror: SyncEnvironment.mirrorDirectory)
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
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}


/// A small preview of a paper: its fill and a few ruled lines at its spacing.
private struct PaperSwatch: View {
    let style: PaperStyle

    var body: some View {
        Canvas { context, size in
            context.withCGContext { cg in
                PageTemplate.draw("lined", in: CGSize(width: size.width * 3, height: size.height * 3), context: cg, paper: style)
            }
        }
        .frame(width: 26, height: 26)
        .background(style.fillColor)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.gray.opacity(0.4), lineWidth: 1))
    }
}
