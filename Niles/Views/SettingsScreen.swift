import SwiftUI

/// Settings: the server control card (kill switch, endpoint, sessions), the
/// pairing card (six-digit code, countdown, paired agents with revoke), and
/// connection info. The former QR code and token reveal are gone — the bearer
/// token never renders in UI; agents pair with the code instead.
struct SettingsScreen: View {
    var model: any DashboardViewModel & PairingViewModel

    /// The paired agent whose revoke confirmation is showing, if any.
    @State private var pendingRevoke: PairedAgentRow?

    var body: some View {
        ScreenScaffold(title: "Settings", subtitle: "Niles · HomeKit MCP proxy · \(model.homeName)") {
            serverCard
            SectionHeader(title: "Pairing")
            pairingCard
            SectionHeader(title: "Paired agents")
            if model.pairedAgents.isEmpty {
                EmptyStateCard(text: "No MCP agents are connected right now. Pair one with the code above.")
            } else {
                agentsCard
            }
            SectionHeader(title: "Connection")
            connectionCard
        }
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

    /// Serving state, the kill switch, and the endpoint/sessions key-value rows.
    private var serverCard: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 8) {
                    Circle()
                        .fill(model.serverIsRunning ? NilesTheme.good : Color.secondary)
                        .frame(width: 9, height: 9)
                    Text(model.serverIsRunning ? "Serving" : "Stopped")
                        .font(.system(size: 15, weight: .bold))
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { model.serverIsRunning },
                    set: { model.setServerRunning($0) }
                ))
                .labelsHidden()
                .tint(NilesTheme.accent)
            }
            .padding(.bottom, 10)
            KeyValueList(rows: [
                KeyValueRow(key: "Endpoint", value: model.endpoint),
                KeyValueRow(key: "Bonjour", value: model.bonjourService),
                KeyValueRow(key: "Sessions", value: model.sessionsSummary),
                KeyValueRow(key: "Approved today", value: "\(model.approvedTodayCount)"),
            ])
        }
        .card()
    }

    /// The pairing card: the six-digit challenge in large type with a live
    /// countdown, and an on-demand mint. A code is a challenge, not a secret —
    /// it expires in five minutes, works once, and dies after five wrong guesses.
    @ViewBuilder
    private var pairingCard: some View {
        VStack(spacing: 10) {
            if let code = model.pairingCode, let expiresAt = model.codeExpiresAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: 6) {
                        Text(code)
                            .font(.system(size: 44, weight: .bold, design: .monospaced))
                            .monospacedDigit()
                        Text(Self.countdownText(expiresAt: expiresAt, now: context.date))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Code unavailable")
                    .font(.system(size: 15))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 18)
            }
            ActionButton(title: "New code", style: .ghost) {
                model.mintNewCode()
            }
        }
        .frame(maxWidth: .infinity)
        .card()
    }

    /// The countdown line under the code: time remaining while live, a plain
    /// "Expired" once past (a fresh code mints at the next refresh). Pure, so
    /// the wording is directly testable.
    static func countdownText(expiresAt: Date, now: Date) -> String {
        let remaining = Int(expiresAt.timeIntervalSince(now))
        guard remaining > 0 else { return "Expired" }
        return String(format: "Expires in %d:%02d", remaining / 60, remaining % 60)
    }

    private var revokeTitle: String {
        guard let name = pendingRevoke?.name else { return "" }
        return "Revoke \(name)?"
    }

    private var agentsCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.pairedAgents.enumerated()), id: \.element.id) { index, agent in
                PairedAgentRowView(agent: agent) {
                    pendingRevoke = agent
                }
                if index < model.pairedAgents.count - 1 {
                    Divider()
                }
            }
        }
        .card()
    }

    private var connectionCard: some View {
        KeyValueList(rows: [
            KeyValueRow(key: "URL", value: model.endpoint),
            KeyValueRow(key: "Transport", value: model.transportName),
        ])
        .card()
    }
}

/// One paired credential: name, paired date, last-seen session, and the
/// destructive Revoke action.
private struct PairedAgentRowView: View {
    let agent: PairedAgentRow
    let onRevoke: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(.system(size: 15, weight: .semibold))
                Text(agent.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Revoke", action: onRevoke)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NilesTheme.destructive)
                .buttonStyle(.plain)
        }
        .padding(.vertical, 10)
    }
}

#Preview("Settings") {
    SettingsScreen(model: InMemoryNilesStore())
}
