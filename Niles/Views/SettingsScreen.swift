import SwiftUI

/// Settings: the server kill switch and endpoint info, the pairing challenge
/// (six-digit code, countdown, on-demand mint), paired agents with swipe-to
/// revoke, and connection info — all standard `Form` rows. The former QR code
/// machinery and token reveal are gone: the bearer token never renders in UI;
/// agents pair with the code instead.
struct SettingsScreen: View {
    var model: any DashboardViewModel & PairingViewModel

    /// The paired agent whose revoke confirmation is showing, if any.
    @State private var pendingRevoke: PairedAgentRow?

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                pairingSection
                pairedAgentsSection
                connectionSection
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                revokeTitle,
                isPresented: Binding(get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } }),
                titleVisibility: .visible
            ) {
                Button("Revoke", role: .destructive) {
                    if let agent = pendingRevoke {
                        Task { await model.revokeAgent(agent.id) }
                    }
                    pendingRevoke = nil
                }
                Button("Cancel", role: .cancel) { pendingRevoke = nil }
            } message: {
                Text("The agent will immediately lose access to this home. Its live session closes and it cannot reconnect without pairing again.")
            }
        }
    }

    /// Serving state as the kill-switch row; endpoint/sessions as value rows.
    private var serverSection: some View {
        Section {
            Toggle("Serving", isOn: Binding(
                get: { model.serverIsRunning },
                set: { model.setServerRunning($0) }
            ))
            LabeledContent("Endpoint", value: model.endpoint)
            LabeledContent("Bonjour", value: model.bonjourService)
            LabeledContent("Sessions", value: model.sessionsSummary)
            LabeledContent("Approved today", value: model.approvedTodayCount.formatted())
        } header: {
            Text("Server")
        } footer: {
            Text(model.serverIsRunning ? "Serving" : "Stopped")
        }
    }

    /// The six-digit challenge in system large type with a live countdown and
    /// an on-demand mint. A code is a challenge, not a secret — it expires in
    /// five minutes, works once, and dies after five wrong guesses.
    @ViewBuilder
    private var pairingSection: some View {
        Section {
            if let code = model.pairingCode, let expiresAt = model.codeExpiresAt {
                Text(code)
                    .font(.largeTitle.weight(.bold).monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .center)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    LabeledContent("Expires", value: Self.countdownText(expiresAt: expiresAt, now: context.date))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Code unavailable")
                    .foregroundStyle(.secondary)
            }
            Button("New code") {
                model.mintNewCode()
            }
        } header: {
            Text("Pairing")
        }
    }

    /// The countdown line: time remaining while live, a plain "Expired" once
    /// past. Pure, so the wording is directly testable.
    static func countdownText(expiresAt: Date, now: Date) -> String {
        let remaining = Int(expiresAt.timeIntervalSince(now))
        guard remaining > 0 else { return "Expired" }
        return String(format: "Expires in %d:%02d", remaining / 60, remaining % 60)
    }

    /// Paired credentials as standard rows; revoke rides the trailing swipe,
    /// confirmed by the dialog above.
    private var pairedAgentsSection: some View {
        Section {
            if model.pairedAgents.isEmpty {
                Text("No MCP agents are connected right now. Pair one with the code above.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.pairedAgents) { agent in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.name)
                        Text(agent.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Revoke", role: .destructive) {
                            pendingRevoke = agent
                        }
                    }
                }
            }
        } header: {
            Text("Paired Agents")
        }
    }

    private var connectionSection: some View {
        Section {
            LabeledContent("Endpoint", value: model.endpoint)
            LabeledContent("Transport", value: model.transportName)
        } header: {
            Text("Connection")
        } footer: {
            Text("Niles · HomeKit MCP proxy · \(model.homeName)")
        }
    }

    private var revokeTitle: String {
        guard let name = pendingRevoke?.name else { return "" }
        return "Revoke \(name)?"
    }
}

#Preview("Settings") {
    SettingsScreen(model: InMemoryNilesStore())
}
