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
        VStack(spacing: Space.xl) {
            Spacer()

            VStack(spacing: Space.l) {
                Image("BrandMark")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 112, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 112 * 0.2237, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                    .accessibilityHidden(true)

                VStack(spacing: Space.s) {
                    Text("Linework")
                        .font(Typography.display)
                    Text("Sign in with your Apple ID to keep your notebooks private and synced through your own iCloud.")
                        .font(Typography.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: Space.m) {
                SignInWithAppleButton(.signIn, onRequest: configure, onCompletion: handle)
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(maxWidth: 320)
                    .frame(height: 50)

                if let errorMessage {
                    Text(errorMessage)
                        .font(Typography.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
            }

            VStack(spacing: Space.xs) {
                Button("Continue Without an Account") {
                    AppSettings.isGuestMode = true
                }
                .font(Typography.label)
                .minimumHitTarget()

                Text("Your notebooks stay on this device and won't sync to iCloud.")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            Spacer()
            Spacer()
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
