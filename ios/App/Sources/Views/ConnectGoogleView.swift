import SwiftUI
import AuthenticationServices

struct ConnectGoogleView: View {
    @EnvironmentObject private var appState: AppState

    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 64))
                .foregroundStyle(.blue)
                .padding(.bottom, 16)

            Text("Connect your Google account")
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text("Sign in so the app can read and update the contacts in your own Google account. That's the only thing it can touch — nothing else in your Google account is accessible.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 12)
                .padding(.horizontal, 32)

            if let email = appState.connectionEmail {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(email)
                        .font(.subheadline.weight(.medium))
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
                .background(Capsule().fill(Color.green.opacity(0.15)))
                .padding(.top, 24)
            }

            Spacer()

            Button {
                Task { await signIn() }
            } label: {
                HStack {
                    if isConnecting {
                        ProgressView()
                            .padding(.trailing, 4)
                    } else {
                        Image(systemName: "g.circle.fill")
                    }
                    Text(isConnecting ? "Signing in…" : "Sign in with Google")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isConnecting)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .alert("Couldn't sign in", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Something went wrong. Please try again.")
        }
    }

    private func signIn() async {
        isConnecting = true
        defer { isConnecting = false }
        do {
            try await appState.connectGoogle()
            // Show the email chip for a beat, then advance automatically.
            try? await Task.sleep(nanoseconds: 900_000_000)
            appState.phase = .access
        } catch {
            if let authError = error as? ASWebAuthenticationSessionError,
               authError.code == .canceledLogin {
                return  // user dismissed the sheet — not an error
            }
            errorMessage = AppState.friendlyMessage(for: error)
            showError = true
        }
    }
}
