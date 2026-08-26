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

    var body: some View {
        Group {
            if isSignedIn || isGuestMode {
                NavigationStack {
                    LibraryView(parentFolder: nil)
                        .navigationDestination(for: Folder.self) { folder in
                            LibraryView(parentFolder: folder)
                        }
                        .navigationDestination(for: Notebook.self) { notebook in
                            NotebookDetailView(notebook: notebook)
                        }
                        .navigationDestination(for: SearchResult.self) { result in
                            NotebookDetailView(notebook: result.notebook, initialPageID: result.pageID)
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
            validateAppleIDCredentialState()
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
