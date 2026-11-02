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
    /// Driven by Spotlight and Shortcuts requests; user taps push onto it too.
    @State private var path = NavigationPath()
    @State private var requests = AppNavigationRequests.shared

    var body: some View {
        Group {
            if isSignedIn || isGuestMode {
                NavigationStack(path: $path) {
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
                                NotebookDetailView(notebook: result.notebook, initialPageID: result.pageID,
                                                   highlight: result.highlight)
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
        .onChange(of: requests.pendingPage, initial: true) { _, _ in consumeNavigationRequest() }
        .onChange(of: isSignedIn || isGuestMode) { _, _ in consumeNavigationRequest() }
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

    /// Opens what Spotlight or a Shortcut asked for, the same way a search
    /// result opens (`SearchResult`, behind `LockedNotebookGate`). Waits
    /// while the login screen is up; a missing notebook or page (not synced
    /// yet) is dropped, or falls back to the notebook.
    private func consumeNavigationRequest() {
        guard isSignedIn || isGuestMode, let request = requests.pendingPage else { return }
        requests.pendingPage = nil
        let id = request.notebookID
        var descriptor = FetchDescriptor<Notebook>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let notebook = (try? modelContext.fetch(descriptor))?.first,
              !PageTemplates.isTemplatesNotebook(notebook) else { return }
        var stack = NavigationPath()
        if let pageID = request.pageID,
           let page = (notebook.pages ?? []).first(where: { $0.id == pageID }) {
            stack.append(SearchResult(notebook: notebook, pageID: pageID, pageNumber: page.index + 1, snippet: ""))
        } else {
            stack.append(notebook)
        }
        path = stack
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
