import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.blue)
                .padding(.bottom, 16)

            Text("Contacts Sync\nfor Google")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)

            Text("Keep your iPhone and Google contacts identical, automatically.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.horizontal, 32)

            VStack(alignment: .leading, spacing: 24) {
                BenefitRow(symbol: "arrow.triangle.2.circlepath",
                           title: "Two-way sync in the background",
                           detail: "Add or edit a contact anywhere — it shows up everywhere.")
                BenefitRow(symbol: "lock.shield",
                           title: "Private — contacts go straight from your phone to Google",
                           detail: "No middleman servers ever see your address book.")
                BenefitRow(symbol: "infinity",
                           title: "Your whole address book",
                           detail: "Every feature works across your entire contact list.")
            }
            .padding(.top, 40)
            .padding(.horizontal, 28)

            Spacer()

            Button {
                appState.phase = .connect
            } label: {
                Text("Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            Button("Preview the app first") {
                appState.enterDemoMode()
            }
            .font(.subheadline)
            .padding(.bottom, 24)
        }
    }
}

private struct BenefitRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
