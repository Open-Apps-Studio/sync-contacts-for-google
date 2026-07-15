import SwiftUI
import SyncEngine

struct FirstSyncPreviewView: View {
    @EnvironmentObject private var appState: AppState

    private enum Stage: Equatable {
        case loading
        case loaded
        case failed(String)
        case syncing
        case quotaPaused
    }

    @State private var stage: Stage = .loading
    @State private var preview = AppState.PreviewCounts()

    var body: some View {
        VStack(spacing: 0) {
            switch stage {
            case .loading:
                Spacer()
                ProgressView()
                    .controlSize(.large)
                Text("Comparing your iPhone and Google contacts…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 16)
                Spacer()

            case .failed(let message):
                Spacer()
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)
                Text("Couldn't build the preview")
                    .font(.headline)
                    .padding(.top, 12)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("Try Again") {
                    stage = .loading
                    Task { await load() }
                }
                .buttonStyle(.bordered)
                .padding(.top, 16)
                Spacer()

            case .syncing:
                Spacer()
                ProgressView()
                    .controlSize(.large)
                Text("Running your first sync…")
                    .font(.headline)
                    .padding(.top, 16)
                Text("You can keep using your phone — this finishes on its own.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()

            case .quotaPaused:
                Spacer()
                Image(systemName: "clock.badge.checkmark")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)
                Text("Great start — the rest finish tomorrow")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
                Text("Google limits daily updates — the rest finish automatically tomorrow. No action needed.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button {
                    appState.finishOnboarding()
                } label: {
                    Text("Go to Dashboard")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 24)
                .padding(.top, 24)
                Spacer()

            case .loaded:
                loadedBody
            }
        }
        .task { await load() }
    }

    // MARK: - Loaded preview

    private var loadedBody: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    Text("Here's what the first sync will do")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .padding(.top, 24)

                    Text("\(preview.localTotal) contacts on this iPhone · \(preview.remoteTotal) on Google")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    PreviewCard(symbol: "icloud.and.arrow.up",
                                tint: .blue,
                                title: "Added to Google: \(preview.addedToGoogle)",
                                subtitle: "iPhone contacts Google doesn't have yet",
                                names: preview.addedToGoogleNames)
                    PreviewCard(symbol: "iphone.and.arrow.forward",
                                tint: .green,
                                title: "Added to iPhone: \(preview.addedToiPhone)",
                                subtitle: "Google contacts your iPhone doesn't have yet",
                                names: preview.addedToiPhoneNames)
                    PreviewCard(symbol: "arrow.triangle.merge",
                                tint: .purple,
                                title: "Merged: \(preview.merged) matches",
                                subtitle: "Same person on both sides — combined, never duplicated",
                                names: preview.mergedNames)

                    HStack(spacing: 8) {
                        Image(systemName: "shield.checkered")
                            .foregroundStyle(.blue)
                        Text("A backup is saved on this phone before we start.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            Button {
                Task { await startFirstSync() }
            } label: {
                Text("Start Sync")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Actions

    private func load() async {
        stage = .loading
        do {
            preview = try await appState.buildPreview()
            stage = .loaded
        } catch {
            stage = .failed(AppState.friendlyMessage(for: error))
        }
    }

    private func startFirstSync() async {
        stage = .syncing
        let summary = await appState.runSync(isFirstSync: true)
        if summary?.paused == .remoteQuotaExhausted {
            stage = .quotaPaused
        } else if summary != nil {
            appState.finishOnboarding()
        } else {
            stage = .failed(appState.lastErrorMessage ?? "Something went wrong. Please try again.")
        }
    }
}

// MARK: - Expandable summary card

private struct PreviewCard: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    let names: [String]

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard !names.isEmpty else { return }
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: symbol)
                        .font(.title3)
                        .foregroundStyle(tint)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer()
                    if !names.isEmpty {
                        Image(systemName: "chevron.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                }
                .padding(14)
            }
            .buttonStyle(.plain)

            if expanded {
                Divider().padding(.horizontal, 14)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(names.prefix(50).enumerated()), id: \.offset) { _, name in
                        Text(name)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if names.count > 50 {
                        Text("…and \(names.count - 50) more")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
    }
}
