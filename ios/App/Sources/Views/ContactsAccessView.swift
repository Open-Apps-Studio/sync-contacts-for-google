import SwiftUI
import Contacts
import SyncEngine

struct ContactsAccessView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase

    @State private var continueAnyway = false

    private var canContinue: Bool {
        appState.contactsAuthStatus == .authorized
            || (appState.contactsAccessIsLimited && continueAnyway)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Image(systemName: "person.2.circle")
                        .font(.system(size: 56))
                        .foregroundStyle(.blue)
                    Text("Allow contacts access")
                        .font(.title2.bold())
                    Text("To keep both lists identical, the app needs Full Access to your iPhone contacts. They never leave your phone except to your own Google account.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
                .padding(.top, 32)

                accessSection

                if appState.hasNativeGoogleSyncOverlap {
                    WarningCard(
                        symbol: "exclamationmark.triangle.fill",
                        title: "Google account already syncing",
                        message: "This iPhone also syncs contacts through a Google account in iOS Settings. Using both can create duplicates — consider turning off Contacts for that account in Settings › Contacts › Accounts.")
                }

                if appState.contactsAccessGranted || continueAnyway {
                    modeSection
                }

                Button {
                    appState.phase = .preview
                } label: {
                    Text("Preview First Sync")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canContinue)
                .padding(.top, 8)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .onChange(of: scenePhase) { newPhase in
            // Refresh after a round-trip to the Settings app.
            if newPhase == .active { appState.refreshContactsAuthStatus() }
        }
    }

    // MARK: - Access state

    @ViewBuilder
    private var accessSection: some View {
        switch appState.contactsAuthStatus {
        case .authorized:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Full access granted")
                    .font(.subheadline.weight(.medium))
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(Capsule().fill(Color.green.opacity(0.15)))

        case .denied, .restricted:
            VStack(spacing: 12) {
                WarningCard(
                    symbol: "hand.raised.fill",
                    title: "Contacts access is off",
                    message: "Turn on contacts access in Settings to sync.")
                Button("Grant Access in Settings") { openSettings() }
                    .buttonStyle(.bordered)
            }

        default:
            if appState.contactsAccessIsLimited {
                VStack(spacing: 12) {
                    WarningCard(
                        symbol: "exclamationmark.triangle.fill",
                        title: "Only some contacts are shared",
                        message: "With Limited Access, contacts you haven't shared can't be synced and may look deleted on Google. Full Access is strongly recommended.")
                    Button("Grant Full Access in Settings") { openSettings() }
                        .buttonStyle(.bordered)
                    Button("Continue anyway") { continueAnyway = true }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    Task { await appState.requestContactsAccess() }
                } label: {
                    Text("Allow Access to Contacts")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Sync mode

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How should we sync?")
                .font(.headline)
            ModeOption(mode: .twoWay, title: "Two-way (recommended)",
                       detail: "Changes on either side copy to the other.",
                       selection: $appState.settings.mode)
            ModeOption(mode: .iphoneToGoogle, title: "iPhone → Google",
                       detail: "Google is updated to match your iPhone. Google-side edits stay on Google.",
                       selection: $appState.settings.mode)
            ModeOption(mode: .googleToIphone, title: "Google → iPhone",
                       detail: "Your iPhone is updated to match Google. iPhone-side edits stay on the phone.",
                       selection: $appState.settings.mode)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Pieces

struct WarningCard: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.12)))
    }
}

private struct ModeOption: View {
    let mode: SyncMode
    let title: String
    let detail: String
    @Binding var selection: SyncMode

    var body: some View {
        Button {
            selection = mode
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selection == mode ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selection == mode ? Color.blue : Color.secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(selection == mode ? Color.blue.opacity(0.10) : Color(.secondarySystemBackground))
            )
        }
        .buttonStyle(.plain)
    }
}
