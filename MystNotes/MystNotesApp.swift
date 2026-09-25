import SwiftUI
import SwiftData

@main
struct NotebookApp: App {
    init() {
        // One storage root now. Anything an earlier build left in the iCloud
        // container comes home once; see FileStore.
        FileStore.adoptLegacyCloudFilesOnce()
        // Crash, hang and disk-write diagnostics arrive from MetricKit on
        // the launch after they happen; see Diagnostics.swift.
        CrashReporter.shared.start()
        // Trashed payloads past their retention finally go. Local only -
        // the sync folder's trash is swept inside a sync run, while the
        // folder is held. Off the main thread: it stats a directory.
        TrashRetention.sweepLocalInBackground()
        // Artwork rows an older build left pointing at deleted pages; see
        // LibraryRebuild.dropOrphanedArtwork.
        LibraryRebuild.dropOrphanedArtworkInBackground(container: sharedModelContainer)
        MainThreadWatchdog.checkpoint("App.init")
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

        // SwiftData is a local, rebuildable index over the sync folder
        // (invariant 4). Never CloudKit: folder sync is the architecture,
        // not a stopgap, and CloudKit needs an entitlement this build
        // doesn't carry.
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        MainThreadWatchdog.checkpoint("App.sharedModelContainer")
        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            MainThreadWatchdog.checkpoint("App.sharedModelContainer done")
            return container
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
        .commands {
            #if targetEnvironment(macCatalyst) || canImport(UIKit)
            // Zoom for the Mac (and a hardware keyboard on iPad), where a
            // pinch isn't on offer: these land in the View menu on Mac and
            // in the ⌘-key overlay on iPad. The canvas in the key window
            // answers - see CanvasHostView.
            CommandGroup(after: .sidebar) {
                Divider()
                Button("Zoom In") { CanvasZoomCommand.zoomIn.post() }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Zoom Out") { CanvasZoomCommand.zoomOut.post() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Zoom to Fit") { CanvasZoomCommand.reset.post() }
                    .keyboardShortcut("0", modifiers: .command)
            }
            #endif
        }

        // A second, separate window scene: lets a notebook be opened in
        // its own standalone window (e.g. dragged into Split View next to
        // the main library window) via openWindow(id: "notebook", value:).
        WindowGroup(id: "notebook", for: PersistentIdentifier.self) { notebookIDBinding in
            NotebookWindowView(notebookID: notebookIDBinding.wrappedValue)
        }
        .modelContainer(sharedModelContainer)
    }
}
