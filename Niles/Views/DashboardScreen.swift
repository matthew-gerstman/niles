import SwiftUI

/// Dashboard: server state card, pending-changes summary, connected agents.
struct DashboardScreen: View {
    var model: any DashboardViewModel
    var onOpenApprovals: () -> Void = {}

    var body: some View {
        ScreenScaffold(title: "Niles", subtitle: "HomeKit MCP proxy · \(model.homeName)") {
            serverCard
            SectionHeader(title: "Pending approval")
            if model.pendingProposals.isEmpty {
                EmptyStateCard(text: "No changes waiting — agents can’t stage anything new without you seeing it.")
            } else {
                pendingCard
            }
            SectionHeader(title: "Connected agents")
            agentsCard
        }
    }

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

    /// Summary card for the pending queue; tapping it jumps to the Approvals tab.
    private var pendingCard: some View {
        Button(action: onOpenApprovals) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(model.pendingProposals.count) changes waiting")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(RelativeTime.label(for: model.pendingProposals.map(\.createdAt).max() ?? Date()))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                DiffLineList(lines: model.pendingProposals.flatMap(\.diff))
            }
            .card(accent: NilesTheme.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var agentsCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.connectedAgents.enumerated()), id: \.element.id) { index, agent in
                AgentRow(agent: agent)
                if index < model.connectedAgents.count - 1 {
                    Divider()
                }
            }
        }
        .card()
    }
}

/// Plain empty-state card shared by the dashboard and approvals queue.
struct EmptyStateCard: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .card()
    }
}

#Preview("Dashboard") {
    DashboardScreen(model: InMemoryNilesStore())
}
