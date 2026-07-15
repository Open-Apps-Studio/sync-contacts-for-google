import SwiftUI
import SyncEngine

struct BackupsView: View {
    @EnvironmentObject private var appState: AppState

    @State private var snapshots: [SnapshotInfo] = []

    var body: some View {
        List {
            if snapshots.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "shield.checkered")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("No backups yet")
                            .font(.headline)
                        Text("Before any sync that changes or removes contacts, a backup of the affected contacts is saved here automatically.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            } else {
                Section {
                    ForEach(snapshots) { snapshot in
                        NavigationLink {
                            SnapshotDetailView(snapshot: snapshot)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(snapshot.date, format: .dateTime.day().month().year().hour().minute())
                                    .font(.subheadline.weight(.medium))
                                Text("\(snapshot.localCount) iPhone · \(snapshot.remoteCount) Google · \(snapshot.reason)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("Backups keep the last 10 pre-sync snapshots of contacts that were about to change.")
                }
            }
        }
        .navigationTitle("Backups")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            snapshots = appState.snapshots.listSnapshots()
        }
    }
}

private struct SnapshotDetailView: View {
    @EnvironmentObject private var appState: AppState
    let snapshot: SnapshotInfo

    var body: some View {
        List {
            Section("Export") {
                ShareLink(item: appState.snapshots.exportURL(forSnapshot: snapshot.id, side: .local)) {
                    Label("Export iPhone contacts (.vcf) — \(snapshot.localCount)",
                          systemImage: "square.and.arrow.up")
                }
                ShareLink(item: appState.snapshots.exportURL(forSnapshot: snapshot.id, side: .remote)) {
                    Label("Export Google contacts (.vcf) — \(snapshot.remoteCount)",
                          systemImage: "square.and.arrow.up")
                }
            }

            Section {
                Button("Restore this backup") {}
                    .disabled(true)
            } footer: {
                Text("In-app restore is coming in a future version. For now, export the .vcf file and import it into the Contacts app or Google Contacts to restore.")
            }
        }
        .navigationTitle(Text(snapshot.date, format: .dateTime.day().month().hour().minute()))
        .navigationBarTitleDisplayMode(.inline)
    }
}
