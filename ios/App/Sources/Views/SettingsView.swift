import SwiftUI
import SyncEngine

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    @State private var showDisconnectConfirm = false
    @State private var showDeleteConfirm = false

    var body: some View {
        Form {
            Section {
                Picker("Sync direction", selection: $appState.settings.mode) {
                    Text("Two-way").tag(SyncMode.twoWay)
                    Text("iPhone → Google").tag(SyncMode.iphoneToGoogle)
                    Text("Google → iPhone").tag(SyncMode.googleToIphone)
                }
            } footer: {
                Text(modeFootnote)
            }

            Section {
                Toggle("Automatic sync", isOn: $appState.settings.automaticSync)
                Toggle("Sync deletions", isOn: $appState.settings.syncDeletions)
                Toggle("Sync photos", isOn: $appState.settings.syncPhotos)
            } footer: {
                Text("With automatic sync off, contacts only sync when you open the app and tap Sync Now. With deletions off, removing a contact on one side leaves it on the other.")
            }

            Section {
                NavigationLink {
                    SyncHealthView()
                } label: {
                    Label("Sync Health", systemImage: "waveform.path.ecg")
                }
                NavigationLink {
                    BackupsView()
                } label: {
                    Label("Backups", systemImage: "shield.checkered")
                }
                NavigationLink {
                    ActivityLogView()
                } label: {
                    Label("Activity log", systemImage: "list.bullet.rectangle")
                }
            }

            Section {
                Button("Disconnect Google", role: .destructive) {
                    showDisconnectConfirm = true
                }
                Button("Delete all app data", role: .destructive) {
                    showDeleteConfirm = true
                }
            } footer: {
                Text("Disconnecting stops syncing and signs out of Google. Your contacts stay untouched on both sides.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Disconnect Google?",
            isPresented: $showDisconnectConfirm,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                Task { await appState.disconnect() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Syncing stops and the Google sign-in is revoked. All contacts stay exactly where they are.")
        }
        .confirmationDialog(
            "Delete all app data?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete everything", role: .destructive) {
                Task { await appState.deleteAllAppData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the Google sign-in, sync history, backups, and settings from this phone. Your contacts on the iPhone and on Google are not touched.")
        }
    }

    private var modeFootnote: String {
        switch appState.settings.mode {
        case .twoWay:
            return "Changes on either side copy to the other. Recommended for most people."
        case .iphoneToGoogle:
            return "Google is updated to match your iPhone. Edits made on Google won't come back to the phone."
        case .googleToIphone:
            return "Your iPhone is updated to match Google. Edits made on the phone won't go up to Google."
        }
    }
}
