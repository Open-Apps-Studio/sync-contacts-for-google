import SwiftUI

@main
struct ContactsSyncApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .tint(.blue)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        switch appState.phase {
        case .welcome:
            WelcomeView()
        case .connect:
            ConnectGoogleView()
        case .access:
            ContactsAccessView()
        case .preview:
            FirstSyncPreviewView()
        case .ready:
            NavigationStack {
                DashboardView()
                #if DEBUG
                    .background(demoScreenNavigation)
                #endif
            }
        }
    }

    #if DEBUG
    @ViewBuilder private var demoScreenNavigation: some View {
        switch RootView.demoScreenArg {
        case "settings": NavigationLink("", destination: SettingsView(), isActive: .constant(true))
        case "health": NavigationLink("", destination: SyncHealthView(), isActive: .constant(true))
        case "backups": NavigationLink("", destination: BackupsView(), isActive: .constant(true))
        case "activity": NavigationLink("", destination: ActivityLogView(), isActive: .constant(true))
        default: EmptyView()
        }
    }
    #endif
}

#if DEBUG
/// Simulator-only: `-demoScreen settings|health|backups|activity` opens that screen
/// at launch so each can be visually verified without tap tooling. Never in release.
extension RootView {
    static var demoScreenArg: String? {
        guard let idx = ProcessInfo.processInfo.arguments.firstIndex(of: "-demoScreen"),
              idx + 1 < ProcessInfo.processInfo.arguments.count else { return nil }
        return ProcessInfo.processInfo.arguments[idx + 1]
    }
}
#endif
