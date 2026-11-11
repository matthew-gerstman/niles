import SwiftUI

/// One paired agent's detail, pushed from the Home tab's Paired Agents
/// section (UI pass 2): what the thing is (name, paired date, the endpoint
/// it talks to) and what it has been doing (one row per live session its
/// token created — client name, started, last accessed). Everything is read
/// from the store's existing session mapping; the token itself is never
/// rendered. Revoke rides the same confirmed flow as the list's swipe.
struct PairedAgentDetailScreen: View {
    let agent: PairedAgentRow
    var model: any PairingViewModel

    @State private var confirmRevoke = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("Agent") {
                LabeledContent("Name", value: agent.name)
                LabeledContent("Paired", value: pairedDate)
                LabeledContent("Endpoint", value: model.endpoint)
            }
            Section {
                if agent.sessions.isEmpty {
                    Text("No live sessions. The agent has not connected since the app started serving.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(agent.sessions) { session in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.clientName)
                            Text("Started \(Self.timestamp(session.startedAt)) · last accessed \(RelativeTime.label(for: session.lastAccessedAt))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Sessions")
            }
            Section {
                Button("Revoke", role: .destructive) {
                    confirmRevoke = true
                }
            }
        }
        .navigationTitle(agent.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Revoke \(agent.name)?",
            isPresented: $confirmRevoke,
            titleVisibility: .visible
        ) {
            Button("Revoke", role: .destructive) {
                Task {
                    await model.revokeAgent(agent.id)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The agent will immediately lose access to this home. Its live session closes and it cannot reconnect without pairing again.")
        }
    }

    private var pairedDate: String {
        agent.pairedAt.formatted(date: .abbreviated, time: .omitted)
    }

    /// Session rows show clock times, not relative ones: the detail view is
    /// where you read the timeline, not gauge recency.
    static func timestamp(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }
}

#Preview {
    NavigationStack {
        PairedAgentDetailScreen(
            agent: InMemoryNilesStore().pairedAgents[0],
            model: InMemoryNilesStore()
        )
    }
}
