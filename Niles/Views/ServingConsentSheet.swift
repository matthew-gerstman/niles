import SwiftUI

/// The first-open serving consent sheet. Presented from the app root whenever
/// the persisted approval is `unset` — a fresh install's first open. Plain
/// language by design (spec: the user must understand what enabling means):
/// the app runs a local server so paired devices on this network can connect
/// and read or stage Home changes. Approve starts serving immediately, which
/// is the user action the iOS local-network permission prompt anchors to;
/// Not Now records denial and the sheet never returns (the Serving toggle in
/// the Home list's Server section is the only re-enable path).
///
/// Presentational only: every action routes through the store, so previews
/// and captures exercise the same state machine the app runs.
struct ServingConsentSheet: View {
    var dashboard: LiveDashboardStore

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "wifi.router")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.top, 32)

            Text("Allow Local Serving?")
                .font(.title2.bold())

            Text("Niles runs a local server on this network so paired devices — like your Mac — can connect, read your home's status, and stage changes for your approval. Nothing is shared until you pair a device, and you can turn serving off anytime from the Home screen.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Spacer()

            Button {
                dashboard.recordServingConsentApproved()
            } label: {
                Text("Approve Serving")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            // The app-wide white tint (NilesApp) would read as broken on a
            // button here the way it does on the Serving toggle; the system
            // green is the row's and this sheet's serving color.
            .tint(.green)

            Button {
                dashboard.recordServingConsentDenied()
            } label: {
                Text("Not Now")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 16)
    }
}

#Preview("First open") {
    ServingConsentSheet(dashboard: LiveDashboardStore(coordinator: ServerCoordinator()))
}

#Preview("Answered") {
    let dashboard = LiveDashboardStore(coordinator: ServerCoordinator())
    dashboard.recordServingConsentDenied()
    return ServingConsentSheet(dashboard: dashboard)
}
