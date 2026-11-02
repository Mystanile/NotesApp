import SwiftUI
import SwiftData
import AuthenticationServices

/// App root. Gates everything behind either Sign in with Apple (`isSignedIn`)
/// or an explicit "Continue Without an Account" choice (`isGuestMode`) — both
/// live via `@AppStorage` so signing out from Settings swaps back to the
/// login screen immediately. Past that gate, hosts the NavigationStack and
/// registers the navigation destinations once, at the top — pushed
/// LibraryViews and NotebookDetailViews don't need to re-register these
/// themselves.
struct ContentView: View {
    @AppStorage(AppSettings.Keys.appearance) private var appearance = "system"
    @AppStorage(AppSettings.Keys.isSignedIn) private var isSignedIn = false
    @AppStorage(AppSettings.Keys.isGuestMode) private var isGuestMode = false
    @State private var showingOnboarding = !AppSettings.hasSeenOnboarding

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    /// The last scene phase other than `.inactive`; see `SyncEngine.shouldPullOnActive`.
    @State private var lastSettledPhase: ScenePhase?

    var body: some View {
        Group {
            if isSignedIn || isGuestMode {
                NavigationStack {
                    LibraryView(parentFolder: nil)
                        .navigationDestination(for: Folder.self) { folder in
                            if let query = folder.smartQuery {
                                SearchResultsView(query: query)
                                    .navigationTitle(folder.name)
                            } else {
                                LibraryView(parentFolder: folder)
                            }
                        }
                        .navigationDestination(for: Notebook.self) { notebook in
                            LockedNotebookGate(notebook: notebook) { NotebookDetailView(notebook: notebook) }
                        }
                        .navigationDestination(for: SearchResult.self) { result in
                            LockedNotebookGate(notebook: result.notebook) {
                                NotebookDetailView(notebook: result.notebook, initialPageID: result.pageID)
                            }
                        }
                }
                #if targetEnvironment(macCatalyst) || canImport(UIKit)
                .fullScreenCover(isPresented: $showingOnboarding) {
                    OnboardingView {
                        AppSettings.hasSeenOnboarding = true
                        showingOnboarding = false
                    }
                }
                #endif
            } else {
                LoginView()
            }
        }
        .preferredColorScheme(scheme)
        .task {
            MainThreadWatchdog.checkpoint("ContentView.task")
            validateAppleIDCredentialState()
            SyncEngine.shared.configure(container: modelContext.container)
            Backup.runIfDue(container: modelContext.container)
            SyncEngine.shared.pullOnForeground()
        }
        .onChange(of: scenePhase) { _, phase in
            MainThreadWatchdog.checkpoint("ContentView.scenePhase \(phase)")
            // Watchdog pause, watcher suspend, background push and relock are
            // process-wide: see `AppLifecycle`. Only the per-scene pull is here.
            if phase == .active, SyncEngine.shouldPullOnActive(previous: lastSettledPhase) {
                SyncEngine.shared.pullOnForeground()
            }
            if phase != .inactive { lastSettledPhase = phase }
        }
    }

    private var scheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    /// Apple ID sign-ins can be revoked from outside the app (Settings on
    /// the device, or account.apple.com) — check once at launch and sign
    /// out locally if that happened, rather than trusting the cached
    /// `isSignedIn` flag forever.
    private func validateAppleIDCredentialState() {
        let userID = AppSettings.signedInUserID
        guard AppSettings.isSignedIn, !userID.isEmpty else { return }
        ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { state, _ in
            guard state == .revoked || state == .notFound else { return }
            Task { @MainActor in
                AppSettings.signOut()
            }
        }
    }
}
