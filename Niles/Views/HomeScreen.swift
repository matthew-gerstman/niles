import SwiftUI
import UIKit
import NilesCore

/// The Home tab (three-tab IA, spec art_t2KGKOy3): the proposal Queue
/// first, then the former Settings sections — Pairing (a tap-to-copy
/// agent prompt carrying the live code), Paired Agents (one line per
/// agent paired since launch), and Server (same bindings, same revoke
/// confirm flow, minus the Sessions row). The list ends at
/// Server; the on-device agent, diagnostics, connection, and home-graph
/// sections are gone from here, and neither the Queue nor the Server
/// section carries a footer anymore.
struct HomeScreen: View {
    var model: any DashboardViewModel & PairingViewModel & AgentStatusViewModel & QueueViewModel & HomeGraphViewModel

    /// Wide-layout chat entry: when set, a trailing toolbar button on
    /// Home's navigation bar opens the gated agent chat as a sheet (the
    /// wide layout has no Niles tab). The tab layout passes nothing and
    /// keeps chat on its own tab.
    var chatEntry: (() -> Void)? = nil

    /// Trailing bar item: the wide-layout chat entry button, or nothing
    /// when chat lives on its own tab. Extracted as a ViewBuilder property —
    /// an immediately-invoked closure here typechecks as `()`, not a View.
    @ViewBuilder
    private var chatEntryButton: some View {
        if let chatEntry {
            Button(action: chatEntry) {
                Label("Niles", systemImage: "sparkles")
            }
        }
    }

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
    /// Set from the pairing prompt's tap until the "Copied" caption
    /// settles back to "Tap to copy".
    @State private var showCopied = false
    /// The in-flight "Copied" reset, cancelled by a re-tap so two quick
    /// copies never race the caption back to its rest state.
    @State private var copiedReset: Task<Void, Never>?
    /// The proposal whose deny confirmation is showing, if any. Owned here —
    /// not by the row — because a full-swipe destructive action tears the
    /// row's own state down before a row-local dialog could present.
    @State private var pendingDeny: NilesProposal?
    /// Brief highlight of the Queue section when a deep link lands on it.
    @State private var queueHighlight = false

    /// Sections addressable by scroll — deep links target Queue, the
    /// `-UIHomeScroll` screenshot hook targets any of them.
    private enum ScrollTarget: String {
        case queue, pairing, agents, server
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    queueSection
                    pairingSection
                    pairedAgentsSection
                    serverSection
                }
                .listStyle(.insetGrouped)
                .navigationTitle("Home")
                // Chat entry via navigationBarItems, not .toolbar: iOS 26
                // hoists topBarTrailing items into a scene-level glass layer
                // on iPad, which pins the button over the Activity pane and
                // opens a blank band above both panes' titles. A bar item
                // stays on the Home pane's own bar at title height.
                .navigationBarItems(trailing: chatEntryButton)
                .onAppear {
                    consumeScrollRequest(proxy)
                    openPendingProposalIfRequested()
                    applyHomeScrollFixtureIfRequested(proxy)
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

    /// Screenshot hook: `-UIHomeScroll <section>` scrolls the Home list to a
    /// section on launch — per-section captures need no UI automation (same
    /// family as `-UITabSelect`). No-op without the flag.
    private func applyHomeScrollFixtureIfRequested(_ proxy: ScrollViewProxy) {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-UIHomeScroll"), i + 1 < args.count,
              let target = ScrollTarget(rawValue: args[i + 1]) else { return }
        // A scrollTo before the first layout is a no-op; give the List a beat.
        Task {
            try? await Task.sleep(for: .seconds(0.8)) // a cancelled capture scroll is fine to skip
            proxy.scrollTo(target, anchor: .top)
        }
    }

    // MARK: - Settings sections (moved verbatim from SettingsScreen)

    /// Serving state as the standard kill-switch row; endpoint as a value
    /// row. The toggle restores the system green: UI pass 2's app-wide
    /// white tint reads as broken on a switch, so this row opts back in.
    private var serverSection: some View {
        Section {
            Toggle("Serving", isOn: Binding(
                get: { model.serverIsRunning },
                set: { model.setServerRunning($0) }
            ))
            .tint(.green)
            LabeledContent("Endpoint", value: model.endpoint)
            LabeledContent("Bonjour", value: model.bonjourService)
        } header: {
            Text("Server")
                .id(ScrollTarget.server)
        }
    }

    /// The pairing prompt as one tap-to-copy row: the full sentence the
    /// user pastes to an agent, with the live code substituted. A code is a
    /// challenge, not a secret — it expires in thirty minutes, works once,
    /// and dies after five wrong guesses. There is no manual mint: the
    /// store mints a fresh code whenever refresh finds none live, so the
    /// prompt always carries a valid challenge.
    @ViewBuilder
    private var pairingSection: some View {
        Section {
            if let code = model.pairingCode, let expiresAt = model.codeExpiresAt {
                Button {
                    UIPasteboard.general.string = Self.pairingPrompt(code: code)
                    copiedReset?.cancel()
                    withAnimation { showCopied = true }
                    copiedReset = Task {
                        try? await Task.sleep(for: .seconds(1.5)) // cancellation of a reset is a no-op
                        withAnimation { showCopied = false }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Self.pairingPrompt(code: code))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(showCopied ? "Copied" : "Tap to copy")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    LabeledContent("Expires", value: Self.countdownText(expiresAt: expiresAt, now: context.date))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Pairing code unavailable")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Pairing")
                .id(ScrollTarget.pairing)
        }
    }

    /// The exact prompt the user copies to an agent — the how-to link and
    /// the live code in one pasteable sentence. Pure, so the wording is
    /// directly testable.
    static func pairingPrompt(code: String) -> String {
        "I would like you to access the niles MCP. You can see how to do this "
            + "from https://github.com/matthew-gerstman/niles . The pairing code is \(code)."
    }

    /// The countdown line: time remaining while live, a plain "Expired" once
    /// past (a beat the store's auto-mint erases on its next refresh). Pure,
    /// so the wording is directly testable.
    static func countdownText(expiresAt: Date, now: Date) -> String {
        let remaining = Int(expiresAt.timeIntervalSince(now))
        guard remaining > 0 else { return "Expired" }
        return String(format: "Expires in %d:%02d", remaining / 60, remaining % 60)
    }

    /// One line per credential paired since this launch — name left,
    /// paired-since time right-aligned. Credentials paired before launch
    /// stay off the list: they are not new pairings to review. Tapping
    /// opens the session detail; revoke rides the trailing swipe, confirmed
    /// by the dialog above.
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
                        HStack {
                            Text(agent.name)
                            Spacer()
                            Text(Self.pairedSinceText(agent.pairedAt))
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
                .id(ScrollTarget.agents)
        }
    }

    /// The right-aligned paired-since caption — a time of day only, since
    /// the list never shows agents paired before today's launch. Pure, so
    /// the wording is directly testable.
    static func pairedSinceText(_ pairedAt: Date) -> String {
        "paired \(pairedAt.formatted(date: .omitted, time: .shortened))"
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
