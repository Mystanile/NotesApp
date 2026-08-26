import SwiftUI
import SwiftData

@main
struct NotebookApp: App {
    init() {
        // Copy any payload files written before iCloud storage was in play up
        // into the iCloud container, so existing notebooks' drawings follow
        // them to other devices. The container isn't mounted at this point, so
        // also re-run once iCloud actually becomes available.
        FileStore.migrateLegacyFilesIfNeeded()
        NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange,
            object: nil,
            queue: .main
        ) { _ in
            FileStore.invalidateCachedBaseDirectory()
            FileStore.migrateLegacyFilesIfNeeded()
        }
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Folder.self,
            Notebook.self,
            Page.self,
            TypedTextBlock.self,
            ImportedDocument.self,
            Link.self,
            Sticker.self
        ])

        // Read once, at container-build time — SwiftData can't swap a
        // ModelConfiguration on an already-running container, so a sync
        // preference change (login screen or Settings) only takes effect
        // the next time the app launches.
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: AppSettings.syncEnabled ? .automatic : .none
        )

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)

        // A second, separate window scene: lets a notebook be opened in
        // its own standalone window (e.g. dragged into Split View next to
        // the main library window) via openWindow(id: "notebook", value:).
        WindowGroup(id: "notebook", for: PersistentIdentifier.self) { notebookIDBinding in
            NotebookWindowView(notebookID: notebookIDBinding.wrappedValue)
        }
        .modelContainer(sharedModelContainer)
    }
}
