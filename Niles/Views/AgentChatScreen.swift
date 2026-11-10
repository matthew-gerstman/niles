import NilesCore
import SwiftUI

/// The in-app agent chat (spec art_AL0RolQe): a typed surface over the same
/// `AgentRunning` seam Siri composes through. Every message is one
/// independent run — it can stage proposals, never approve or execute them;
/// the Queue stays the only review boundary. All-native system components
/// per the locked decision: no theme tokens, no custom bubbles, Dynamic Type
/// text styles and system colors throughout.
struct AgentChatScreen: View {
    /// The chat observes the transcript (`ChatViewModel`), the gate
    /// (`AgentStatusViewModel`), and the proposal live state that chips ride
    /// (`QueueViewModel` — refreshed by the store's existing 1-second poll;
    /// no `ProposalStore` changes).
    var model: any ChatViewModel & AgentStatusViewModel & QueueViewModel

    @State private var draft = ""
    @State private var navigation = AppNavigation.shared
    @FocusState private var composerFocused: Bool

    /// Haptic triggers: one count per outcome, so a resolved turn buzzes
    /// success and a failed turn buzzes error exactly once.
    private var resolvedTurnCount: Int {
        model.entries.filter { $0.role == .agent && $0.state == .done }.count
    }
    private var failedTurnCount: Int {
        model.entries.filter { entry in
            if case .failed = entry.state { return true }
            return false
        }.count
    }

    var body: some View {
        Group {
            if case .unavailable(let reason) = model.agentAvailability {
                unavailableState(reason)
            } else {
                transcript
            }
        }
        .navigationTitle("Ask Niles")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The trace viewer is one tap from the chat: the buffer mirrors
            // exactly the runs this screen produces.
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    AgentTraceScreen()
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                }
                .accessibilityLabel("Agent Trace")
            }
        }
        .safeAreaInset(edge: .bottom) { composerBar }
        .sensoryFeedback(.success, trigger: resolvedTurnCount)
        .sensoryFeedback(.error, trigger: failedTurnCount)
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcript: some View {
        if model.entries.isEmpty {
            // Centered: the empty state has nothing to anchor to the bottom.
            ContentUnavailableView {
                Label("Ask Niles", systemImage: "sparkles")
            } description: {
                Text("Requests stage proposals for your review — nothing changes until you approve in the Queue.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            transcriptList
        }
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(model.entries) { entry in
                        row(for: entry)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: model.entries.count) { _, _ in scrollToLast(proxy) }
            .onAppear { scrollToLast(proxy) }
        }
    }

    private func scrollToLast(_ proxy: ScrollViewProxy) {
        guard let last = model.entries.last else { return }
        withAnimation {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    /// User and agent turns: differentiated by alignment and system text
    /// color — no hand-drawn bubbles (locked decision).
    @ViewBuilder
    private func row(for entry: ChatEntry) -> some View {
        switch entry.role {
        case .user:
            HStack(alignment: .firstTextBaseline) {
                Spacer(minLength: 44)
                Text(entry.text)
                    .font(.body)
                    .foregroundStyle(.tint)
                    .textSelection(.enabled)
            }
        case .agent:
            VStack(alignment: .leading, spacing: 10) {
                switch entry.state {
                case .running:
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Working on the home graph…")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                case .done:
                    Text(entry.text)
                        .font(.body)
                        .textSelection(.enabled)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                if !entry.stagedProposalIds.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(entry.stagedProposalIds, id: \.self) { id in
                            chip(for: id)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Proposal chips

    /// One staged proposal of this turn: a native row that deep-links into
    /// the Queue with that proposal as context. Live state rides the store's
    /// existing poll — this view only reads it.
    private func chip(for id: String) -> some View {
        let proposal = model.proposals.first { $0.id == id }
        return Button {
            navigation.requestQueue(proposalId: id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: AgentChatChip.symbol(for: proposal?.state))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(proposal?.title ?? "Proposal")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(AgentChatChip.stateLabel(for: proposal?.state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Proposal \(proposal?.title ?? "") — \(AgentChatChip.stateLabel(for: proposal?.state)). Opens the Queue.")
    }

    // MARK: - States

    /// The gate failed: the same reason copy Settings shows, and a composer
    /// that stays disabled — no degraded fallback (spec: availability).
    private func unavailableState(_ reason: AgentAvailability.Reason) -> some View {
        ContentUnavailableView {
            Label("Niles' agent isn't available", systemImage: "sparkles")
        } description: {
            Text(SettingsScreen.agentFooterText(.unavailable(reason)))
        }
    }

    /// The composer: a vertical-axis system text field plus a send button,
    /// anchored above the tab bar as a bottom safe-area inset. (The
    /// `.bottomBar` toolbar placement renders underneath iOS 26's floating
    /// tab bar, so taps meant for the composer hit the tab bar; a safe-area
    /// inset is equally native and sits above both tab bar and keyboard.)
    /// Disabled while a run is in flight or the gate failed.
    private var composerBar: some View {
        HStack(spacing: 12) {
            TextField("Ask Niles to dim the living room tonight…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .submitLabel(.send)
                .focused($composerFocused)
                .disabled(!model.canSend)
                .accessibilityIdentifier("chat-composer")
            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .accessibilityLabel("Send")
            .accessibilityIdentifier("chat-send")
            .disabled(!model.canSend || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.canSend, !text.isEmpty else { return }
        draft = ""
        composerFocused = false
        Task { await model.send(text) }
    }
}

/// Pure chip mapping for a proposal's live state — system symbol and label
/// per `ProposalState`. Internal so the unit suite pins the wording.
enum AgentChatChip {
    static func stateLabel(for state: ProposalState?) -> String {
        switch state {
        case .staged: "Staged — awaiting your review"
        case .approved: "Approved"
        case .executed: "Executed"
        case .denied: "Denied"
        case .expired: "Expired"
        case .failed: "Failed"
        case nil: "Staged — awaiting your review"
        }
    }

    static func symbol(for state: ProposalState?) -> String {
        switch state {
        case .staged: "doc.text"
        case .approved: "checkmark.circle"
        case .executed: "checkmark.seal.fill"
        case .denied: "xmark.circle"
        case .expired: "clock.badge.exclamationmark"
        case .failed: "exclamationmark.triangle"
        case nil: "doc.text"
        }
    }
}

#Preview("Empty") {
    NavigationStack {
        AgentChatScreen(model: InMemoryNilesStore())
    }
}

#Preview("Unavailable") {
    let store = InMemoryNilesStore()
    store.agentAvailability = .unavailable(.appleIntelligenceNotEnabled)
    return NavigationStack {
        AgentChatScreen(model: store)
    }
}
