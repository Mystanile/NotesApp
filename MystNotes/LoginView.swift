import SwiftUI
import AuthenticationServices

/// The gate shown before the Library — nobody sees a notebook until they
/// sign in. This is about IDENTITY, not data isolation: CloudKit's private
/// database is already scoped per Apple ID automatically (see
/// `MystnotesApp`'s `ModelConfiguration`), so two people on two devices
/// already can't see each other's notebooks with zero code here. This
/// screen exists so the app actually knows who's using it.
struct LoginView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "note.text")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 8) {
                Text("Mystnotes")
                    .font(.largeTitle)
                    .fontWeight(.semibold)
                Text("Sign in with your Apple ID to keep your notebooks yours — private to you, synced through your own iCloud.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 48)
            }

            SignInWithAppleButton(.signIn, onRequest: configure, onCompletion: handle)
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(width: 280, height: 50)
                .padding(.top, 8)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 48)
            }

            VStack(spacing: 6) {
                Button("Continue Without an Account") {
                    AppSettings.syncEnabled = false
                    AppSettings.isGuestMode = true
                }
                .font(.subheadline)
                .fontWeight(.medium)

                Text("Your notebooks stay on this device only and won't sync to iCloud.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 60)
            }
            .padding(.top, 12)

            Spacer()
            Spacer()
        }
        .padding()
    }

    private func configure(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = [.fullName, .email]
    }

    private func handle(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                errorMessage = "Something went wrong signing in. Try again."
                return
            }
            AppSettings.signedInUserID = credential.user
            // Apple only includes the name on the very first authorization
            // for this app — cache it so later sign-ins still have it.
            if let name = credential.fullName {
                let formatted = PersonNameComponentsFormatter().string(from: name)
                if !formatted.isEmpty {
                    AppSettings.signedInDisplayName = formatted
                }
            }
            errorMessage = nil
            // Signing in for real always implies wanting sync — matters when
            // this follows "Continue Without an Account", which turns it off.
            AppSettings.syncEnabled = true
            AppSettings.isSignedIn = true

        case .failure(let error):
            let nsError = error as NSError
            // The user backing out of the sign-in sheet isn't an error worth
            // showing them.
            if nsError.domain == ASAuthorizationError.errorDomain,
               nsError.code == ASAuthorizationError.canceled.rawValue {
                return
            }
            errorMessage = "Couldn't sign in: \(error.localizedDescription)"
        }
    }
}
