import SwiftUI

/// Queue: the vertical proposal list, newest first — one row per proposal
/// with its severity chip and one-line diff, inline Deny/Approve on staged
/// rows, and Undo on executed rows whose paired revert still applies.
/// Destructive rows approve with a standard tap everywhere (user decision
/// Nov 9); severity is signaled by the red accent edge, the chip, and the
/// destructive copy. Tapping a row opens the detail sheet with the full diff
/// and structured read-back evidence.
struct QueueScreen: View {
    var model: any QueueViewModel

    @State private var openDetail: NilesProposal?

    /// Approve all batches every staged proposal — destructive included.
    private var stagedCount: Int { model.proposals.filter(\.isPending).count }

    var body: some View {
        ScreenScaffold(title: "Queue", subtitle: "Nothing changes until you approve it") {
            if stagedCount > 0 {
                ActionButton(
                    title: model.isApprovingAll ? "Approving…" : "Approve all \(stagedCount)",
                    style: .primary
                ) {
                    model.approveAll()
                }
                .disabled(model.isApprovingAll)
                .padding(.bottom, 12)
            }
            if model.proposals.isEmpty {
                EmptyStateCard(text: "No proposals yet. When an agent wants to change your home, its request shows up here.")
            } else {
                ForEach(model.proposals) { proposal in
                    QueueRow(
                        proposal: proposal,
                        decision: model.decisionsInFlight[proposal.id],
                        undoState: model.undoStates[proposal.id],
                        onOpenDetail: { openDetail = proposal },
                        onApprove: { model.approve(proposal.id) },
                        onDeny: { model.deny(proposal.id) },
                        onUndo: { model.undo(proposal.id) }
                    )
                }
            }
        }
        .sheet(item: $openDetail) { snapshot in
            // Re-read from the model so the sheet reflects decisions made on the row.
            if let proposal = model.proposals.first(where: { $0.id == snapshot.id }) {
                ProposalDetailSheet(
                    proposal: proposal,
                    onApprove: { model.approve(proposal.id) },
                    onDeny: { model.deny(proposal.id) }
                )
            }
        }
    }
}

/// One Queue row. Staged rows carry the severity chip, a one-line diff, and
/// inline Deny/Approve; terminal rows carry a status chip; executed rows
/// whose paired revert still applies carry Undo — a conflicted undo renders
/// its divergences inline. While a decision's pipeline round-trip is still
/// running, `decision` shows an in-progress chip and disables the buttons
/// before the verdict state lands.
struct QueueRow: View {
    let proposal: NilesProposal
    var decision: ProposalDecision?
    var undoState: UndoState?
    var onOpenDetail: () -> Void = {}
    var onApprove: () -> Void = {}
    var onDeny: () -> Void = {}
    var onUndo: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                SeverityChip(isDestructive: proposal.isDestructive)
                Spacer()
                Text(RelativeTime.label(for: proposal.createdAt))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Text(proposal.title)
                .font(.system(size: 15, weight: .bold))
            Text(oneLineDiff)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let tally = evidenceTally {
                Text(tally)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            switch rowState {
            case .deciding:
                buttons
            case .undoable:
                HStack(spacing: 8) {
                    ActionButton(title: "Undo", style: .ghost, action: onUndo)
                        .disabled(undoState == .inFlight)
                    if undoState == .inFlight {
                        Text("Undoing…")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                if case .conflict(let divergences) = undoState {
                    UndoConflictBlock(divergences: divergences)
                }
                if undoState == .notRevertable {
                    Text("No revert available for this change")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            case .settled:
                if let chip = statusChip {
                    Text(chip.text)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(chip.color)
                }
            }
        }
        .card(accent: proposal.isDestructive ? NilesTheme.destructive : NilesTheme.accent)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpenDetail)
    }

    // MARK: - Row pieces

    private enum RowState { case deciding, undoable, settled }

    /// Staged rows decide (with in-flight feedback), executed rows that still
    /// offer Undo undo, and everything else renders its settled chip.
    private var rowState: RowState {
        if proposal.isPending || decision != nil { return .deciding }
        if undoState != nil { return .undoable }
        return .settled
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 8) {
            ActionButton(title: "Approve", style: .primary, action: onApprove)
                .disabled(!proposal.isPending || decision != nil)
            ActionButton(title: "Deny", style: .ghost, action: onDeny)
                .disabled(!proposal.isPending || decision != nil)
        }
        .padding(.top, 2)
        if let chip = inFlightChip {
            Text(chip.text)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(chip.color)
        }
    }

    /// The first diff line stands in for the row's one-line summary; a
    /// proposal without diff lines falls back to its planned summary.
    private var oneLineDiff: String {
        proposal.diff.first?.text ?? proposal.summary
    }

    private var evidenceTally: String? {
        guard !proposal.evidence.isEmpty else { return nil }
        let confirmed = proposal.evidence.filter(\.confirmed).count
        return "\(confirmed) of \(proposal.evidence.count) checks confirmed"
    }

    private var inFlightChip: (text: String, color: Color)? {
        switch decision {
        case .approving: return ("Approving…", NilesTheme.accent)
        case .denying: return ("Denying…", NilesTheme.destructive)
        case nil: return nil
        }
    }

    private var statusChip: (text: String, color: Color)? {
        switch proposal.state {
        case .staged, .approved: return nil
        case .executed: return ("Executed", NilesTheme.good)
        case .denied: return ("Denied", NilesTheme.destructive)
        case .expired: return ("Expired", NilesTheme.warn)
        case .failed: return ("Failed", NilesTheme.destructive)
        }
    }
}

/// Severity at a glance, matching the mockup's chips: red for destructive
/// rows, neutral for everything else — the edge color carries the same signal.
private struct SeverityChip: View {
    let isDestructive: Bool

    var body: some View {
        Text(isDestructive ? "Destructive" : "Standard")
            .font(.system(size: 11, weight: .bold))
            .tracking(0.3)
            .textCase(.uppercase)
            .foregroundStyle(isDestructive ? NilesTheme.destructive : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                (isDestructive ? NilesTheme.destructive : Color.primary).opacity(0.08),
                in: Capsule()
            )
    }
}

/// The typed undo-conflict error, rendered inline: what execution produced,
/// what the home shows now, per divergence. Nothing was changed.
private struct UndoConflictBlock: View {
    let divergences: [ProposalEvidence]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Can't undo — the home changed since this ran")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(NilesTheme.destructive)
            ForEach(Array(divergences.enumerated()), id: \.offset) { _, divergence in
                HStack(alignment: .top, spacing: 6) {
                    Text("✗")
                        .foregroundStyle(NilesTheme.destructive)
                    Text("\(divergence.claim) — \(divergence.observed)")
                        .font(.system(size: 12))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NilesTheme.destructive.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
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
