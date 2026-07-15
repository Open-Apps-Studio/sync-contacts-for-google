import SwiftUI
import SyncEngine

struct DashboardView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        List {
            if appState.isDemoMode {
                demoBanner
            }

            heroSection

            if case .pausedDeletionGuard(let localDeletes, let remoteDeletes) = appState.syncState {
                deletionGuardSection(pending: localDeletes + remoteDeletes)
            }

            if appState.syncState == .pausedQuota {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "clock.badge.checkmark")
                            .foregroundStyle(.blue)
                        Text("Google limits daily updates — the rest finish automatically tomorrow.")
                            .font(.subheadline)
                    }
                }
            }

            accountSection
            activitySection
        }
        .navigationTitle("Contacts Sync")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .refreshable {
            await appState.runSync()
        }
        .onAppear {
            appState.refreshActivity()
            appState.refreshContactsAuthStatus()
        }
    }

    // MARK: - Demo banner

    private var demoBanner: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label("Preview mode — this is sample data", systemImage: "eye")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("Connect your Google account to sync your real iPhone and Google contacts.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    appState.exitDemoMode(startConnect: true)
                } label: {
                    Text("Connect Google")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Hero status

    private enum HeroStatus {
        case syncing, attention, inSync
    }

    private var heroStatus: HeroStatus {
        if appState.isSyncing { return .syncing }
        switch appState.syncState {
        case .pausedDeletionGuard: return .attention
        default: break
        }
        if appState.lastErrorMessage != nil { return .attention }
        if !appState.contactsAccessGranted { return .attention }
        return .inSync
    }

    private var heroSection: some View {
        Section {
            VStack(spacing: 10) {
                switch heroStatus {
                case .syncing:
                    ProgressView()
                        .controlSize(.large)
                    Text("Syncing…")
                        .font(.title3.weight(.semibold))
                case .attention:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.orange)
                    Text("Attention needed")
                        .font(.title3.weight(.semibold))
                    if let message = attentionMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                case .inSync:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.green)
                    Text("In sync")
                        .font(.title3.weight(.semibold))
                }

                if let date = appState.lastSyncDate {
                    (Text("Last synced ") + Text(date, style: .relative) + Text(" ago · \(appState.contactCount) contacts"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No completed sync yet")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await appState.runSync() }
                } label: {
                    Text("Sync Now")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.isSyncing)
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .listRowSeparator(.hidden)
    }

    private var attentionMessage: String? {
        if case .pausedDeletionGuard = appState.syncState {
            return "This sync is waiting for your confirmation below."
        }
        if !appState.contactsAccessGranted {
            return "Contacts access was turned off. Re-enable it in Settings to keep syncing."
        }
        return appState.lastErrorMessage
    }

    // MARK: - Deletion guard

    private func deletionGuardSection(pending: Int) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.title3)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("This sync wants to remove \(pending) contact\(pending == 1 ? "" : "s")")
                            .font(.subheadline.weight(.semibold))
                        Text("That's more than usual, so we paused to check with you. A backup was already saved on this phone.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 12) {
                    Button(role: .destructive) {
                        Task { await appState.confirmDeletions() }
                    } label: {
                        Text("Remove them")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task { await appState.rejectDeletions() }
                    } label: {
                        Text("Keep them")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .disabled(appState.isSyncing)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        Section("Account") {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle")
                    .font(.title2)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.connectionEmail ?? "Google account")
                        .font(.subheadline.weight(.medium))
                    Text(appState.settings.mode.displayName)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Recent activity

    private var activitySection: some View {
        Section("Recent activity") {
            if appState.recentActivity.isEmpty {
                Text("Nothing yet — activity shows up here after your first sync.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appState.recentActivity.prefix(3)) { event in
                    ActivityRow(event: event)
                }
                NavigationLink("View all") {
                    ActivityLogView()
                }
                .font(.subheadline)
            }
        }
    }
}

// MARK: - Shared bits

extension SyncMode {
    var displayName: String {
        switch self {
        case .twoWay: return "Two-way sync"
        case .iphoneToGoogle: return "iPhone → Google"
        case .googleToIphone: return "Google → iPhone"
        }
    }
}

struct ActivityRow: View {
    let event: ActivityEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.kind.symbol)
                .foregroundStyle(event.kind.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.summary)
                    .font(.subheadline)
                if let detail = event.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(event.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

extension ActivityKind {
    var symbol: String {
        switch self {
        case .addedToGoogle, .addedToiPhone: return "plus.circle.fill"
        case .updatedOnGoogle, .updatedOniPhone: return "pencil.circle.fill"
        case .deletedFromGoogle, .deletedFromiPhone: return "minus.circle.fill"
        case .merged: return "arrow.triangle.merge"
        case .conflictResolved: return "arrow.triangle.branch"
        case .snapshotCreated, .snapshotRestored: return "shield.checkered"
        case .syncStarted: return "arrow.triangle.2.circlepath"
        case .syncCompleted: return "checkmark.circle.fill"
        case .syncFailed: return "xmark.circle.fill"
        case .syncPaused: return "pause.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .addedToGoogle, .addedToiPhone: return .green
        case .updatedOnGoogle, .updatedOniPhone: return .blue
        case .deletedFromGoogle, .deletedFromiPhone: return .red
        case .merged, .conflictResolved: return .purple
        case .snapshotCreated, .snapshotRestored: return .teal
        case .syncStarted: return .secondary
        case .syncCompleted: return .green
        case .syncFailed: return .red
        case .syncPaused: return .orange
        }
    }
}
