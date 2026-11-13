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

    /// Compact single page: when set, Activity's timeline sections render
    /// below the Server section in THIS list — one scrolling page, Home
    /// above Activity — instead of Activity living in a second pane pinned
    /// to the other half of the screen. The wide layout passes nothing and
    /// keeps its separate Activity pane.
    var activityModel: (any ActivityViewModel)? = nil

    /// Inline-title pin for this pane's bar — set in the wide layout by
    /// widePane(); false (automatic) in the narrow layout. See ContentView.
    @Environment(\.widePaneInlineTitle) private var widePaneInlineTitle

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
    /// The paired agent whose revoke confirmation is showing, if any.
    @State private var pendingRevoke: PairedAgentRow?
    /// Set from the pairing prompt's tap until the "Copied" caption
    /// settles back to "Tap to copy".
    @State private var showCopied = false
    /// The in-flight "Copied" reset, cancelled by a re-tap so two quick
    /// copies never race the caption back to its rest state.
    @State private var copiedReset: Task<Void, Never>?
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
                    if let activityModel {
                        ActivitySections(model: activityModel)
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle("Home")
                // Shared bar modifier (see widePane): each
                // pane applies the inline pin widePane() publishes — pinned
                // in the wide layout, automatic (untouched) in the narrow
                // layout.
                .navigationBarTitleDisplayMode(widePaneInlineTitle ? .inline : .automatic)
                // Chat entry via navigationBarItems, not .toolbar: iOS 26
                // hoists topBarTrailing items into a scene-level glass layer
                // on iPad, which pins the button over the Activity pane and
                // opens a blank band above both panes' titles. A bar item
                // stays on the Home pane's own bar at title height.
                .navigationBarItems(trailing: chatEntryButton)
                // No explicit .contentMargins on the List: an explicit
                // horizontal scroll-content margin REPLACES the
                // safe-area-derived one, and on the Duo that is the 84 pt
                // sensor-housing/status-pillar clearance (device-measured —
                // with the margin set, cards rendered ~66 pt
                // under the pillar). The default grouped-list margins already
                // give the 20 pt gutters, and keeping margins off the stack
                // wrapper avoids the bar scroll-edge interference seen in the
                // wide layout.
                // Safe-area diagnostics: -UISafeAreaProbe overlays the
                // List's measured insets and boundary lines.
                .overlay(alignment: .bottomLeading) {
                    if SafeAreaProbe.active {
                        SafeAreaOverlay(label: "home.list", badgeAlignment: .topLeading)
                    }
                }
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
            // Queue exclusivity: the row set comes from the store layer's
            // `queueProposals` gate — undecided proposals only. A proposal
            // whose decision pipeline is running (the optimistic swipe
            // marker) or that any pipeline client has decided (approved,
            // denied, executed, expired, execution-failed) never renders
            // here. Activity owns decided and in-flight work; a failed
            // decision returns the row with its error note.
            let visible = model.queueProposals
            if visible.isEmpty {
                emptyQueueState
            } else {
                ForEach(visible) { proposal in
                    QueueListRow(
                        proposal: proposal, model: model,
                        onOpen: { openDetail = proposal }
                    )
                }
            }
        } header: {
            Text("Queue")
                .foregroundStyle(queueHighlight ? Color.primary : Color.secondary)
        }
        .id(ScrollTarget.queue)
    }

    /// The empty state: one quiet row — never a hero card.
    private var emptyQueueState: some View {
        HStack {
            Text("No proposals yet")
                .foregroundStyle(.secondary)
            Spacer()
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
        guard let rawTarget = LaunchArguments.uiHomeScroll,
              let target = ScrollTarget(rawValue: rawTarget) else { return }
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

    /// The Pairing section: the live code, visible again (PR #76 folded it
    /// into the prompt sentence; an agent being paired reads it off the
    /// screen), plus a Copy Prompt button carrying the exact sentence an
    /// agent needs — a small caption beside the code, not a full-width row
    /// stacked below it. Codes still expire and refresh every thirty minutes
    /// internally — the UI just no longer renders a countdown.
    @ViewBuilder
    private var pairingSection: some View {
        Section {
            if let code = model.pairingCode {
                // One row: the code with its copy prompt as a small caption
                // beside it, not a standard row stacked below.
                HStack(spacing: 8) {
                    Text(code)
                        .font(.system(.title2, design: .monospaced).weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        UIPasteboard.general.string = Self.pairingPrompt(address: model.endpoint, code: code)
                        copiedReset?.cancel()
                        withAnimation { showCopied = true }
                        copiedReset = Task {
                            try? await Task.sleep(for: .seconds(1.5)) // cancellation of a reset is a no-op
                            withAnimation { showCopied = false }
                        }
                    } label: {
                        Label(showCopied ? "Copied" : "Copy Prompt",
                              systemImage: showCopied ? "checkmark" : "doc.on.doc")
                            // The app-wide tint is white (NilesApp), so both
                            // the system accent and the inherited tint render
                            // the label white-on-white. Primary keeps the copy
                            // action visible; footnote keeps it caption-sized
                            // but still tappable.
                            .font(.footnote)
                            .foregroundStyle(.primary)
                    }
                    // Plain confines the tap target to the label (the row
                    // also holds the code text) and, unlike borderless,
                    // keeps .primary visible under the app-wide white tint.
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 4)
            } else {
                Text("Pairing code unavailable")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Pairing")
                .id(ScrollTarget.pairing)
        }
    }

    /// The exact prompt the user copies to an agent — the live endpoint and
    /// the code in one pasteable sentence. Pure, so the wording is directly
    /// testable.
    static func pairingPrompt(address: String, code: String) -> String {
        "I would like you to access the niles MCP at \(address). My pairing code is \(code)"
    }

    /// One line per credential paired since this launch — name left,
    /// paired-since time right-aligned. Credentials paired before launch
    /// stay off the list: they are not new pairings to review. Tapping
    /// opens the session detail; revoke rides the trailing swipe, confirmed
    /// by the dialog above.
    private var pairedAgentsSection: some View {
        Section {
            if model.pairedAgents.isEmpty {
                Text("No agents connected")
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
}

#Preview("Home") {
    HomeScreen(model: InMemoryNilesStore())
}
