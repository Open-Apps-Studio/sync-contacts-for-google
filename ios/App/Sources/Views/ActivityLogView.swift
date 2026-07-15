import SwiftUI
import SyncEngine

struct ActivityLogView: View {
    @EnvironmentObject private var appState: AppState

    private enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case added = "Added"
        case updated = "Updated"
        case deleted = "Deleted"
        case conflicts = "Conflicts"

        var id: String { rawValue }

        var kinds: Set<ActivityKind>? {
            switch self {
            case .all: return nil
            case .added: return [.addedToGoogle, .addedToiPhone]
            case .updated: return [.updatedOnGoogle, .updatedOniPhone]
            case .deleted: return [.deletedFromGoogle, .deletedFromiPhone]
            case .conflicts: return [.conflictResolved, .merged]
            }
        }
    }

    @State private var filter: Filter = .all

    private var filtered: [ActivityEvent] {
        guard let kinds = filter.kinds else { return appState.recentActivity }
        return appState.recentActivity.filter { kinds.contains($0.kind) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Filter.allCases) { option in
                        Button {
                            filter = option
                        } label: {
                            Text(option.rawValue)
                                .font(.subheadline.weight(.medium))
                                .padding(.vertical, 6)
                                .padding(.horizontal, 14)
                                .background(
                                    Capsule().fill(filter == option
                                                   ? Color.blue
                                                   : Color(.secondarySystemBackground))
                                )
                                .foregroundStyle(filter == option ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            if filtered.isEmpty {
                Spacer()
                Image(systemName: "tray")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(filter == .all
                     ? "No activity yet — it appears here after your first sync."
                     : "Nothing in this category yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
                    .padding(.horizontal, 32)
                Spacer()
            } else {
                List(filtered) { event in
                    ActivityRow(event: event)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { appState.refreshActivity() }
    }
}
