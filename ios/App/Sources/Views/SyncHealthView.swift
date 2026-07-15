import SwiftUI
import UserNotifications

struct SyncHealthView: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var backgroundRefreshStatus = UIApplication.shared.backgroundRefreshStatus
    @State private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var lastWake = AppState.lastBackgroundWake

    var body: some View {
        List {
            Section {
                HealthRow(
                    title: "Background App Refresh",
                    ok: backgroundRefreshStatus == .available,
                    value: backgroundRefreshLabel,
                    hint: backgroundRefreshStatus == .available
                        ? nil
                        : "Turn on Settings › General › Background App Refresh so iOS can run syncs for you.")
                HealthRow(
                    title: "Low Power Mode",
                    ok: !lowPowerMode,
                    value: lowPowerMode ? "On" : "Off",
                    hint: lowPowerMode
                        ? "iOS pauses most background work in Low Power Mode. Syncs still run when you open the app."
                        : nil)
                HealthRow(
                    title: "Notifications",
                    ok: notificationStatus != .denied,
                    value: notificationLabel,
                    hint: notificationStatus == .denied
                        ? "Background sync works without notifications, but alerts about sync problems won't show."
                        : nil)
                HealthRow(
                    title: "Last background wake",
                    ok: lastWake != nil,
                    value: lastWakeLabel,
                    hint: lastWake == nil
                        ? "iOS hasn't woken the app in the background yet. This is normal in the first day or two."
                        : nil)
            }

            Section {
                Text("iOS decides when apps run in the background, based on how you use your phone, battery level, and network. That means background syncs happen on iOS's schedule, not a fixed timer — usually several times a day. Opening the app always syncs immediately.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Sync Health")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                Task { await refresh() }
            }
        }
    }

    private func refresh() async {
        backgroundRefreshStatus = UIApplication.shared.backgroundRefreshStatus
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        lastWake = AppState.lastBackgroundWake
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationStatus = settings.authorizationStatus
    }

    private var backgroundRefreshLabel: String {
        switch backgroundRefreshStatus {
        case .available: return "On"
        case .denied: return "Off"
        case .restricted: return "Restricted"
        @unknown default: return "Unknown"
        }
    }

    private var notificationLabel: String {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral: return "Allowed"
        case .denied: return "Off"
        case .notDetermined: return "Not asked"
        @unknown default: return "Unknown"
        }
    }

    private var lastWakeLabel: String {
        guard let lastWake else { return "Not yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let when = formatter.localizedString(for: lastWake.date, relativeTo: Date())
        return "\(when) · \(lastWake.source)"
    }
}

private struct HealthRow: View {
    let title: String
    let ok: Bool
    let value: String
    let hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? Color.green : Color.orange)
                Text(title)
                    .font(.subheadline)
                Spacer()
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 28)
            }
        }
        .padding(.vertical, 2)
    }
}
