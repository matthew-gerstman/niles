import SwiftUI
import NilesCore

/// The Home tab (three-tab IA, spec art_t2KGKOy3): the proposal Queue
/// first, then the former Settings sections — Server, Pairing, and Paired
/// Agents (same bindings, same revoke confirm flow). The list ends at
/// Paired Agents; the on-device agent, diagnostics, connection, and
/// home-graph sections are gone from here, and neither the Queue nor the
/// Server section carries a footer anymore.
struct HomeScreen: View {
    var model: any DashboardViewModel & PairingViewModel & AgentStatusViewModel & QueueViewModel & HomeGraphViewModel

    /// The shared navigation signal: proposal deep links from the chat open
    /// the detail sheet here, and the queue request scrolls to the Queue
    /// section (the deep link used to land on the Queue tab).
    @State private var navigation = AppNavigation.shared
    @State private var openDetail: NilesProposal?
    /// The collapsed empty state: one quiet row that expands the explainer
    /// on tap — never a hero card.
    @State private var showEmptyExplainer = false
    /// The paired agent whose revoke confirmation is showing, if any.
    @State private var pendingRevoke: PairedAgentRow?
    /// The proposal whose deny confirmation is showing, if any. Owned here —
    /// not by the row — because a full-swipe destructive action tears the
    /// row's own state down before a row-local dialog could present.
    @State private var pendingDeny: NilesProposal?
    /// Brief highlight of the Queue section when a deep link lands on it.
    @State private var queueHighlight = false

    /// Scroll target for the Queue section — attached to the section so a
    /// deep link can scroll it into view.
    private enum ScrollTarget { case queue }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    queueSection
                    serverSection
                    pairingSection
                    pairedAgentsSection
                }
                .listStyle(.insetGrouped)
                .navigationTitle("Home")
                .onAppear {
                    consumeScrollRequest(proxy)
                    openPendingProposalIfRequested()
                }
                // The chat's chip tap can land here before the store's poll
                // has surfaced the proposal; retry on the next refresh.
                .onChange(of: model.proposals) { _, _ in openPendingProposalIfRequested() }
                // Deep link from OpenQueueIntent while the app is already
                // running: ContentView selects this tab; this scrolls to the
                // Queue section (and opens a riding proposal, if any).
                .onChange(of: navigation.scrollToQueuePending) { _, pending in
                    if pending { consumeScrollRequest(proxy) }
                    openPendingProposalIfRequested()
                }
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
            .confirmationDialog(
                denyTitle,
                isPresented: Binding(get: { pendingDeny != nil }, set: { if !$0 { pendingDeny = nil } }),
                titleVisibility: .visible
            ) {
                Button("Deny", role: .destructive) {
                    if let proposal = pendingDeny {
                        model.deny(proposal.id)
                    }
                    pendingDeny = nil
                }
                Button("Cancel", role: .cancel) { pendingDeny = nil }
            } message: {
                Text("Nothing is applied and the proposal cannot be recalled by the agent. It can stage the change again.")
            }
            .sheet(item: $openDetail) { snapshot in
                // Re-read from the model so the sheet reflects decisions made on the row.
                if let proposal = model.proposals.first(where: { $0.id == snapshot.id }) {
                    ProposalDetailSheet(
                        proposal: proposal,
                        undoState: model.undoStates[proposal.id],
                        onApprove: { model.approve(proposal.id) },
                        onDeny: { model.deny(proposal.id) },
                        onUndo: { model.undo(proposal.id) }
                    )
                }
            }
        }
    }

    // MARK: - Queue

    private var queueSection: some View {
        Section {
            if model.proposals.isEmpty {
                emptyQueueState
            } else {
                ForEach(model.proposals) { proposal in
                    QueueListRow(
                        proposal: proposal, model: model,
                        onOpen: { openDetail = proposal },
                        onRequestDeny: { pendingDeny = $0 }
                    )
                }
            }
        } header: {
            Text("Queue")
                .foregroundStyle(queueHighlight ? Color.primary : Color.secondary)
        }
        .id(ScrollTarget.queue)
    }

    /// The collapsed empty state: one quiet row that expands the explainer
    /// on tap. No proposal has ever needed a hero card here.
    private var emptyQueueState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation { showEmptyExplainer.toggle() }
            } label: {
                HStack {
                    Text("No proposals yet")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: showEmptyExplainer ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            if showEmptyExplainer {
                Text("When an agent wants to change your home — via Siri or Ask Niles — its request shows up here for your approval.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The chat's proposal deep link: open the tapped proposal's detail once
    /// it is visible, then clear the pending context. A nil or unknown id is
    /// a no-op — the flag stays until the proposal shows up.
    private func openPendingProposalIfRequested() {
        guard let id = navigation.pendingProposalId else { return }
        guard let proposal = model.proposals.first(where: { $0.id == id }) else { return }
        openDetail = proposal
        navigation.consumePendingProposal()
    }

    /// A queue request arrived (Siri deep link or a chat chip): scroll the
    /// Queue section into view and flash its header, then clear the signal.
    private func consumeScrollRequest(_ proxy: ScrollViewProxy) {
        guard navigation.scrollToQueuePending else { return }
        withAnimation {
            proxy.scrollTo(ScrollTarget.queue, anchor: .top)
            queueHighlight = true
        }
        navigation.consumeScrollToQueue()
        // The flash lasts a beat, then the header returns to its quiet color.
        Task {
            try? await Task.sleep(for: .seconds(1.2)) // cancellation of a flash is a no-op
            withAnimation { queueHighlight = false }
        }
    }

    // MARK: - Settings sections (moved verbatim from SettingsScreen)

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
        } header: {
            Text("Server")
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
                    NavigationLink {
                        PairedAgentDetailScreen(agent: agent, model: model)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.name)
                            Text(agent.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
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

    /// Footer text for the on-device agent: it states what is missing and
    /// nothing else — no fallback is ever implied, per the spec's
    /// no-degraded-mode invariant. Shared with the chat toolbar's status
    /// row. Pure, so the wording is directly testable.
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

    private var revokeTitle: String {
        guard let name = pendingRevoke?.name else { return "" }
        return "Revoke \(name)?"
    }

    private var denyTitle: String {
        guard let proposal = pendingDeny else { return "" }
        return "Deny “\(proposal.title)”?"
    }
}

#Preview("Home") {
    HomeScreen(model: InMemoryNilesStore())
}
