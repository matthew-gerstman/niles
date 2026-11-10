import SwiftUI
import NilesCore

/// Queue: the vertical proposal list, newest first — one native list row per
/// proposal with severity carried by a warning glyph, a one-line diff, and
/// relative time. Decisions arrive as swipe actions (leading Approve on the
/// right, trailing Deny on the left, row tap for the detail sheet); Undo is
/// a trailing swipe on executed rows that still offer it. Approve-all lives
/// in the toolbar behind a confirmation dialog. Destructive rows approve
/// with a standard tap everywhere (user decision Nov 9); severity is
/// signaled by the red warning symbol plus its label, never by color alone.
struct QueueScreen: View {
    var model: any QueueViewModel
    /// Injection seam for the chat's proposal deep link (same hermeticity
    /// pattern as `OpenQueueIntent.navigationTarget`): nil in previews — the
    /// consumption no-ops.
    var navigation: AppNavigation? = nil

    @State private var openDetail: NilesProposal?
    @State private var confirmApproveAll = false

    /// Approve all batches every staged proposal — destructive included.
    private var stagedCount: Int { model.proposals.filter(\.isPending).count }

    var body: some View {
        NavigationStack {
            List {
                if model.proposals.isEmpty {
                    emptyState
                } else {
                    Section {
                        ForEach(model.proposals) { proposal in
                            row(for: proposal)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Queue")
            .toolbar {
                if stagedCount > 0 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            confirmApproveAll = true
                        } label: {
                            Label("Approve All", systemImage: "checkmark.seal")
                        }
                        .disabled(model.isApprovingAll)
                    }
                }
            }
            .confirmationDialog(
                "Approve all staged proposals?",
                isPresented: $confirmApproveAll,
                titleVisibility: .visible
            ) {
                Button("Approve all \(stagedCount)") { model.approveAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every staged proposal is approved and executed — destructive ones included.")
            }
            .onAppear { openPendingProposalIfRequested() }
            // The chat's chip tap can land here before the store's poll has
            // surfaced the proposal; retry on the next refresh.
            .onChange(of: model.proposals) { _, _ in openPendingProposalIfRequested() }
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

    // MARK: - Rows

    /// The chat's proposal deep link: open the tapped proposal's detail once
    /// it is visible, then clear the pending context. A nil or unknown id is
    /// a no-op — the flag stays until the proposal shows up.
    private func openPendingProposalIfRequested() {
        guard let navigation, let id = navigation.pendingProposalId else { return }
        guard let proposal = model.proposals.first(where: { $0.id == id }) else { return }
        openDetail = proposal
        navigation.consumePendingProposal()
    }

    /// One standard list row: severity glyph, title, one-line diff, evidence
    /// tally, and a trailing status — a spinner while a decision or undo is
    /// in flight, otherwise the settled SF Symbol status label.
    private func row(for proposal: NilesProposal) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: proposal.isDestructive ? "exclamationmark.triangle" : "doc.text")
                .foregroundStyle(proposal.isDestructive ? Color.red : Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(proposal.title)
                    .font(.headline)
                Text(oneLineDiff(of: proposal))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                metadataLine(for: proposal)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                trailingStatus(for: proposal)
                Text(RelativeTime.label(for: proposal.createdAt))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { openDetail = proposal }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            trailingActions(for: proposal)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            leadingActions(for: proposal)
        }
    }

    /// Trailing (left) swipes: Deny (destructive role) on staged rows and
    /// Undo on executed rows that still offer it. Full swipe is disabled so
    /// a thumb slip can never deny.
    @ViewBuilder
    private func trailingActions(for proposal: NilesProposal) -> some View {
        let decision = model.decisionsInFlight[proposal.id]
        let undoState = model.undoStates[proposal.id]
        if proposal.isPending {
            Button(role: .destructive) {
                model.deny(proposal.id)
            } label: {
                Label("Deny", systemImage: "xmark.circle")
            }
            .disabled(decision != nil)
        } else if undoState != nil {
            Button {
                model.undo(proposal.id)
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(undoState == .inFlight)
        }
    }

    /// Leading (right) swipes: Approve (green tint) on staged rows. The
    /// former leading Details action is gone — the row tap already opens
    /// the detail sheet.
    @ViewBuilder
    private func leadingActions(for proposal: NilesProposal) -> some View {
        let decision = model.decisionsInFlight[proposal.id]
        if proposal.isPending {
            Button {
                model.approve(proposal.id)
            } label: {
                Label("Approve", systemImage: "checkmark.circle")
            }
            .tint(Color.green)
            .disabled(decision != nil)
        }
    }

    /// Severity label, evidence tally, and no-revert note as caption text —
    /// the words carry the meaning, the colors only reinforce it.
    @ViewBuilder
    private func metadataLine(for proposal: NilesProposal) -> some View {
        let undoState = model.undoStates[proposal.id]
        if proposal.isDestructive || !proposal.evidence.isEmpty || undoState == .notRevertable {
            HStack(spacing: 12) {
                if proposal.isDestructive {
                    Text("Destructive")
                        .font(.caption)
                        .foregroundStyle(Color.red)
                }
                if let tally = evidenceTally(of: proposal) {
                    Label(tally.text, systemImage: tally.symbol)
                        .font(.caption)
                        .foregroundStyle(tally.color)
                }
                if undoState == .notRevertable {
                    Text("No revert available for this change")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Trailing region status: a spinner while a decision or an undo round
    /// trips, "Undo conflicted" when the revert was refused, otherwise the
    /// settled state's SF Symbol label.
    @ViewBuilder
    private func trailingStatus(for proposal: NilesProposal) -> some View {
        let decision = model.decisionsInFlight[proposal.id]
        let undoState = model.undoStates[proposal.id]
        if decision != nil || undoState == .inFlight {
            ProgressView()
        } else if case .conflict = undoState {
            Label("Undo conflicted", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Color.orange)
        } else if let status = statusLabel(for: proposal.state) {
            Label(status.text, systemImage: status.symbol)
                .font(.caption)
                .foregroundStyle(status.color)
        }
    }

    // MARK: - Row pieces

    /// The first diff line stands in for the row's one-line summary; a
    /// proposal without diff lines falls back to its title.
    private func oneLineDiff(of proposal: NilesProposal) -> String {
        proposal.diff.first?.text ?? proposal.title
    }

    /// Settled state → SF Symbol + label. Staged and approved rows are still
    /// mid-decision, so they carry no settled status.
    private func statusLabel(for state: ProposalState) -> (text: String, symbol: String, color: Color)? {
        switch state {
        case .staged, .approved: return nil
        case .executed: return ("Executed", "checkmark.circle.fill", .green)
        case .denied: return ("Denied", "xmark.circle.fill", .red)
        case .expired: return ("Expired", "clock.badge.xmark", .orange)
        case .failed: return ("Failed", "xmark.octagon.fill", .red)
        }
    }

    /// "N of M checks confirmed" — the app's core trust signal. Green when
    /// the read-back agreed on every check, amber the moment it didn't.
    private func evidenceTally(of proposal: NilesProposal) -> (text: String, symbol: String, color: Color)? {
        guard !proposal.evidence.isEmpty else { return nil }
        let confirmed = proposal.evidence.filter(\.confirmed).count
        let allConfirmed = confirmed == proposal.evidence.count
        return (
            "\(confirmed) of \(proposal.evidence.count) checks confirmed",
            allConfirmed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
            allConfirmed ? Color.green : Color.orange
        )
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No proposals yet", systemImage: "tray")
        } description: {
            Text("When an agent wants to change your home, its request shows up here.")
        }
    }
}

#Preview("Queue") {
    QueueScreen(model: InMemoryNilesStore())
}

#Preview("Queue — conflicted undo") {
    let store = InMemoryNilesStore()
    store.undoStates["prop_8f50"] = .conflict([
        ProposalEvidence(
            claim: "Room “Studio” exists",
            observed: "No room named “Studio” exists — it was deleted after execution",
            confirmed: false
        ),
    ])
    return QueueScreen(model: store)
}

#Preview("Queue — empty") {
    struct EmptyStore: QueueViewModel {
        var proposals: [NilesProposal] { [] }
        var decisionsInFlight: [String: ProposalDecision] { [:] }
        var undoStates: [String: UndoState] { [:] }
        var isApprovingAll: Bool { false }
        func approve(_ id: String) {}
        func deny(_ id: String) {}
        func approveAll() {}
        func undo(_ id: String) {}
    }
    return QueueScreen(model: EmptyStore())
}
