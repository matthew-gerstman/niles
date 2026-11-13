import SwiftUI
import UIKit
import NilesCore

/// One queue row, shared by the Home tab's Queue section — severity glyph,
/// title, the batch's summary line and evidence tally when they say
/// something the title does not (single-op rows render title + status +
/// timestamp alone), and a trailing status (a spinner
/// while a decision or undo is in flight, otherwise the settled SF Symbol
/// status label). Decisions arrive as full swipe actions (leading Approve
/// on the right, trailing Deny on the left — the swipe itself is the
/// decision, no revealed-button tap and no confirmation step); partial
/// swipes still reveal the same buttons, and a row tap opens the detail
/// sheet. Undo is a trailing swipe on executed rows that still offer it.
/// Extracted from the former QueueScreen so the Home section renders the
/// exact same rows and semantics instead of duplicating them (spec
/// art_t2KGKOy3: reuse, don't re-implement).
struct QueueListRow: View {
    let proposal: NilesProposal
    var model: any QueueViewModel
    /// Opens the proposal's detail sheet — the row itself never decides
    /// where the detail lives, so the Home tab can present it as its own.
    let onOpen: () -> Void

    /// Swipe-out dismissal: the edge the decision's swipe came from. The
    /// row springs out the way the thumb was already moving — deny (a
    /// trailing-edge swipe) exits left, approve (a leading-edge swipe)
    /// exits right.
    private enum ExitDirection {
        case leading, trailing

        /// Far enough past the row's edge that the spring never settles
        /// visibly on screen, even mid-flight.
        var exitOffset: CGFloat {
            let clear = UIScreen.main.bounds.width * 1.2
            return self == .trailing ? -clear : clear
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var exit: ExitDirection?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: proposal.isDestructive ? "exclamationmark.triangle" : "doc.text")
                .foregroundStyle(proposal.isDestructive ? Color.red : .primary)
            VStack(alignment: .leading, spacing: 3) {
                Text(proposal.title)
                    .font(.headline)
                if let summary = summaryLine(of: proposal) {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                metadataLine(for: proposal)
                failureNote(for: proposal)
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
        .onTapGesture { onOpen() }
        .swipeActions(edge: .trailing, allowsFullSwipe: proposal.isPending) {
            trailingActions(for: proposal)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: proposal.isPending) {
            leadingActions(for: proposal)
        }
        // Spring-out dismissal, applied after the swipeActions modifiers so
        // the whole row — content and revealed buttons together — leaves in
        // one piece instead of exposing the action buttons underneath.
        .offset(x: exit?.exitOffset ?? 0)
        .opacity(exit == nil ? 1 : 0)
        .allowsHitTesting(exit == nil)
    }

    // MARK: - Swipes

    /// The dismissal handoff: spring the row out in the swipe's direction,
    /// then fire the decision so the optimistic removal (decisionsInFlight)
    /// filters the row and the List reflows the gap — inside withAnimation,
    /// so neighbors glide closed instead of jump-cutting. Reduced motion
    /// skips the spring and the removal entirely: the decision applies with
    /// no animation transaction at all.
    private func decide(_ direction: ExitDirection, _ decision: @escaping () -> Void) {
        guard exit == nil else { return }
        if reduceMotion {
            withAnimation(nil) { decision() }
            return
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            exit = direction
        }
        // The spring has essentially settled by the time the removal runs;
        // its own spring carries the reflow.
        Task {
            try? await Task.sleep(for: .milliseconds(420)) // a cancelled exit still fires the decision
            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                decision()
            }
        }
    }

    /// Trailing (left) swipes: Deny (destructive role) on staged rows and
    /// Undo on executed rows that still offer it. A full swipe completes
    /// the denial in one gesture — the user's direction (2026-11-12): the
    /// swipe IS the decision, with no revealed-button tap and no
    /// confirmation step, replacing the earlier "a thumb slip can never
    /// deny" stance. Partial swipes still reveal a Deny button that denies
    /// immediately on tap.
    @ViewBuilder
    private func trailingActions(for proposal: NilesProposal) -> some View {
        let decision = model.decisionsInFlight[proposal.id]
        let undoState = model.undoStates[proposal.id]
        if proposal.isPending {
            Button(role: .destructive) {
                decide(.trailing) { model.deny(proposal.id) }
            } label: {
                Label("Deny", systemImage: "xmark.circle")
            }
            .tint(.red) // destructive red; the app-wide .tint(.white) otherwise overrides the role
            .disabled(decision != nil)
        } else if undoState != nil {
            Button {
                model.undo(proposal.id)
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            // Orange: a reversal, not a deletion — caution without destructive red.
            .tint(.orange)
            .disabled(undoState == .inFlight)
        }
    }

    /// Leading (right) swipes: Approve (green tint) on staged rows. The row
    /// tap opens the detail sheet — nothing else rides the leading edge.
    @ViewBuilder
    private func leadingActions(for proposal: NilesProposal) -> some View {
        let decision = model.decisionsInFlight[proposal.id]
        if proposal.isPending {
            Button {
                decide(.leading) { model.approve(proposal.id) }
            } label: {
                Label("Approve", systemImage: "checkmark.circle")
            }
            .tint(Color.green)
            .disabled(decision != nil)
        }
    }

    // MARK: - Row pieces

    /// Severity label, evidence tally, launch-revalidation flag, and
    /// no-revert note as caption text — the words carry the meaning, the
    /// colors only reinforce it.
    @ViewBuilder
    private func metadataLine(for proposal: NilesProposal) -> some View {
        let undoState = model.undoStates[proposal.id]
        if proposal.isDestructive || !proposal.evidence.isEmpty || undoState == .notRevertable
            || proposal.staleReason != nil {
            HStack(spacing: 12) {
                if proposal.isDestructive {
                    Text("Destructive")
                        .font(.caption)
                        .foregroundStyle(Color.red)
                }
                if let staleReason = proposal.staleReason {
                    Label(staleReason, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Color.orange)
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

    /// A failed decision's row-level note (tap to dismiss): the failure is
    /// visible on the row itself, not only in the log — and the row is back
    /// in the Queue with its swipe re-enabled.
    @ViewBuilder
    private func failureNote(for proposal: NilesProposal) -> some View {
        if let failure = model.decisionFailures[proposal.id] {
            Button {
                model.clearDecisionFailure(proposal.id)
            } label: {
                Label(failure, systemImage: "exclamationmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(Color.red)
            }
            .buttonStyle(.plain)
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

    /// The row's summary line: the first diff line of a batch, which
    /// describes the batch's first operation — something its title
    /// ("Batch: 2 changes") does not. A single-op proposal's first diff
    /// line merely restates the title ("Scene “Starlight” · created…"
    /// under Create scene “Starlight”), so the row renders title + status
    /// + timestamp with nothing duplicative (Matthew, 2026-11-12). A
    /// batch with no diff lines renders nothing rather than the title
    /// twice.
    private func summaryLine(of proposal: NilesProposal) -> String? {
        guard proposal.isBatch, let first = proposal.diff.first else { return nil }
        return first.text
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
    /// the read-back agreed on every check, amber the moment it didn't. An
    /// aborted batch's unreached entries are called out separately — they
    /// never ran, so they are not failed checks. One fully-confirmed check
    /// is the ordinary outcome and restates the obvious on the row, so the
    /// tally only renders when there is more than one check or any check
    /// did not confirm (2026-11-12 declutter).
    private func evidenceTally(of proposal: NilesProposal) -> (text: String, symbol: String, color: Color)? {
        guard !proposal.evidence.isEmpty else { return nil }
        let confirmed = proposal.evidence.filter(\.confirmed).count
        let allConfirmed = confirmed == proposal.evidence.count
        guard proposal.evidence.count > 1 || !allConfirmed else { return nil }
        var text = "\(confirmed) of \(proposal.evidence.count) checks confirmed"
        let notRun = proposal.evidence.filter(\.notRun).count
        if notRun > 0 {
            text += " · \(notRun) not run"
        }
        return (
            text,
            allConfirmed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
            allConfirmed ? Color.green : Color.orange
        )
    }
}
