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
                agentSection
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

    /// The on-device agent (spec art_VrC0iUUA §Availability gate): what the
    /// gate decided, and — when it passed — session usage. No run entry
    /// lives here; requests arrive via Siri, and this surface states
    /// whether the agent can run at all. When the gate fails, the footer
    /// names the exact reason and no row invites a request.
    private var agentSection: some View {
        Section {
            LabeledContent("Status", value: Self.agentStatusLabel(model.agentAvailability))
            if case .available = model.agentAvailability {
                LabeledContent("Requests", value: model.agentUsage.requestCount.formatted())
                LabeledContent("Tool calls", value: model.agentUsage.toolCallCount.formatted())
                if !model.agentUsage.lastStagedProposalIds.isEmpty {
                    LabeledContent("Last staged", value: model.agentUsage.lastStagedProposalIds.joined(separator: ", "))
                }
            }
        } header: {
            Text("On-Device Agent")
        } footer: {
            Text(Self.agentFooterText(model.agentAvailability))
        }
    }

    /// Status row text, one label per gate state. Pure, so the wording is
    /// directly testable.
    static func agentStatusLabel(_ availability: AgentAvailability) -> String {
        switch availability {
        case .available: return "Available"
        case .unavailable(.needsIOS27): return "Needs iOS 27"
        case .unavailable(.deviceNotEligible): return "Device not eligible"
        case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence off"
        case .unavailable(.modelNotReady): return "Model not ready"
        case .unavailable(.unknown): return "Unavailable"
        }
    }

    /// The footer states what is missing and nothing else — no fallback is
    /// ever implied, per the spec's no-degraded-mode invariant. Pure.
    static func agentFooterText(_ availability: AgentAvailability) -> String {
        switch availability {
        case .available:
            return "Ask Niles by voice via Siri. Every change becomes a proposal awaiting your approval in the Queue — nothing applies until you approve it."
        case .unavailable(.needsIOS27):
            return "The on-device agent needs iOS 27 or later. Update your iPhone to use it."
        case .unavailable(.deviceNotEligible):
            return "The on-device agent needs Apple Intelligence hardware, which this device does not have."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in Settings to use the on-device agent."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still downloading the on-device model. Check back soon."
        case .unavailable(.unknown):
            return "The on-device agent is unavailable on this device."
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
