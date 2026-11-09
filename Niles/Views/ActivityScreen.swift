import SwiftUI
import NilesCore

/// The Activity timeline: the persistent event log grouped by recency,
/// entries tappable into detail cards. Recent executed cards offer Undo when
/// a conflict-free paired revert exists; undone entries stay marked UNDONE.
struct ActivityScreen: View {
    var model: any ActivityViewModel

    @State private var openDetail: ActivityTimeline.Row?
    /// Screenshot hook: `-UIActivityOpenDetail` presents the newest entry's
    /// detail card on launch, so per-card captures need no UI automation.
    @State private var autoOpenedDetail = false

    var body: some View {
        ScreenScaffold(title: "Activity", subtitle: "Everything that happened, in order") {
            let rows = ActivityTimeline.rows(events: model.activityEvents, proposals: model.proposals)
            if rows.isEmpty {
                EmptyStateCard(
                    text: "Proposals will appear here as they are staged, decided, and executed."
                )
            } else {
                ForEach(ActivityTimeline.sections(rows: rows)) { section in
                    SectionHeader(title: section.title)
                    ForEach(section.rows) { row in
                        ActivityCard(
                            row: row,
                            failure: model.undoFailures[row.event.proposalId],
                            onOpenDetail: { openDetail = row },
                            onUndo: { model.undo(row.event.proposalId) },
                            onDismissFailure: { model.clearUndoFailure(row.event.proposalId) }
                        )
                    }
                }
            }
        }
        .sheet(item: $openDetail) { row in
            // Rebuild the row from the model so the card reflects undo taps
            // and refreshed evidence, like the approvals sheet does.
            if let fresh = ActivityTimeline.rows(
                events: model.activityEvents, proposals: model.proposals
            ).first(where: { $0.event.id == row.event.id }) {
                ActivityDetailCard(
                    row: fresh,
                    failure: model.undoFailures[fresh.event.proposalId],
                    onUndo: { model.undo(fresh.event.proposalId) },
                    onDismissFailure: { model.clearUndoFailure(fresh.event.proposalId) }
                )
            }
        }
        .task {
            if !autoOpenedDetail,
               ProcessInfo.processInfo.arguments.contains("-UIActivityOpenDetail"),
               let newest = ActivityTimeline.rows(
                   events: model.activityEvents, proposals: model.proposals
               ).first {
                openDetail = newest
                autoOpenedDetail = true
            }
        }
    }
}

/// One timeline entry: verdict chip, title, tool line, outcome detail, and —
/// on recent executed cards — the Undo button. A conflict from the last Undo
/// tap renders inline until dismissed or retried.
struct ActivityCard: View {
    let row: ActivityTimeline.Row
    var failure: ActivityUndoFailure?
    var onOpenDetail: () -> Void = {}
    var onUndo: () -> Void = {}
    var onDismissFailure: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VerdictChip(verdict: row.verdict)
                Spacer()
                Text(RelativeTime.label(for: row.event.at))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Text(row.event.proposalTitle)
                .font(.system(size: 15, weight: .bold))
            ToolChip(text: row.toolLine)
            if let agent = row.event.agentName {
                Text("by \(agent)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            if let detail = row.event.detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            if let failure {
                UndoFailureBlock(failure: failure, onDismiss: onDismissFailure)
            }
            if row.verdict == .undone, !row.revertEvidence.isEmpty {
                let confirmed = row.revertEvidence.filter(\.confirmed).count
                Text("Revert confirmed: \(confirmed) of \(row.revertEvidence.count) checks")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NilesTheme.good)
            }
            if row.undoAvailable {
                ActionButton(title: "Undo", style: .ghost, action: onUndo)
                    .padding(.top, 2)
            }
        }
        .card(accent: row.verdict == .failed ? NilesTheme.destructive : NilesTheme.accent)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpenDetail)
    }
}

/// The verdict chip: EXECUTED / DENIED / STAGED / EXPIRED / UNDONE / FAILED /
/// APPROVED, colored per the token rules (red reserved for denial and failure).
struct VerdictChip: View {
    let verdict: ActivityTimeline.Verdict

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private var label: String {
        switch verdict {
        case .staged: "STAGED"
        case .approved: "APPROVED"
        case .denied: "DENIED"
        case .executed: "EXECUTED"
        case .failed: "FAILED"
        case .expired: "EXPIRED"
        case .undone: "UNDONE"
        }
    }

    private var color: Color {
        switch verdict {
        case .staged: NilesTheme.accent
        case .approved: NilesTheme.good
        case .denied: NilesTheme.destructive
        case .executed: NilesTheme.good
        case .failed: NilesTheme.destructive
        case .expired: Color.primary.opacity(0.45)
        case .undone: Color.primary.opacity(0.45)
        }
    }
}

/// The inline undo-conflict block: the typed reason nothing was applied, plus
/// the store's structured divergences (what moved in the home, per check).
struct UndoFailureBlock: View {
    let failure: ActivityUndoFailure
    var onDismiss: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(failure.message)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NilesTheme.destructive)
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            ForEach(Array(failure.divergences.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 6) {
                    Text("✗")
                        .foregroundStyle(NilesTheme.destructive)
                    Text("\(item.claim) — \(item.observed)")
                }
                .font(.system(size: 12))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NilesTheme.destructive.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The detail card behind a tapped entry: verdict chip, tool line, the event's
/// outcome, structured read-back evidence — and for undone entries, the
/// revert's own evidence linked to the original proposal.
struct ActivityDetailCard: View {
    let row: ActivityTimeline.Row
    var failure: ActivityUndoFailure?
    var onUndo: () -> Void = {}
    var onDismissFailure: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.event.proposalTitle)
                    .font(.system(size: 18, weight: .bold))
                Spacer()
                VerdictChip(verdict: row.verdict)
            }
            ToolChip(text: "\(row.toolLine) · \(row.event.agentName ?? \"unknown agent\")")
            Text(row.event.at.formatted(date: .abbreviated, time: .standard))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if let detail = row.event.detail {
                Text(detail)
                    .font(.system(size: 13))
            }
            if row.verdict == .undone {
                // The revert's own read-back, linked to the original: the
                // undo's evidence lives on the revert, not the undone event.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reverted by \(row.revertTitle ?? "a paired revert").")
                        .font(.system(size: 12, weight: .semibold))
                    if row.revertEvidence.isEmpty {
                        Text("The revert's read-back is available while its proposal is in memory.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        EvidenceRows(evidence: row.revertEvidence)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            if !row.event.evidence.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    let confirmed = row.event.evidence.filter(\.confirmed).count
                    Text("Read-back evidence: \(confirmed) of \(row.event.evidence.count) checks confirmed against the live home.")
                        .font(.system(size: 12, weight: .semibold))
                    EvidenceRows(evidence: row.event.evidence)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            if let failure {
                UndoFailureBlock(failure: failure, onDismiss: onDismissFailure)
            }
            HStack(spacing: 8) {
                if row.undoAvailable {
                    ActionButton(title: "Undo", style: .primary, action: onUndo)
                }
                ActionButton(title: "Close", style: .ghost) { dismiss() }
            }
            .padding(.top, 4)
            Spacer()
        }
        .padding(20)
        .presentationDetents([.medium, .large])
    }
}

/// The ✓/✗ claim-observed rows every evidence block shares.
private struct EvidenceRows: View {
    let evidence: [ProposalEvidence]

    var body: some View {
        ForEach(Array(evidence.enumerated()), id: \.offset) { _, item in
            HStack(alignment: .top, spacing: 6) {
                Text(item.confirmed ? "✓" : "✗")
                    .foregroundStyle(item.confirmed ? NilesTheme.good : NilesTheme.destructive)
                Text("\(item.claim) — \(item.observed)")
            }
            .font(.system(size: 12))
        }
    }
}

// MARK: - Previews and the screenshot fixture

/// In-memory fixture behind the Activity previews and the screenshot hook
/// (`-UIActivityFixtures` launches the app on it): one afternoon's log with
/// every verdict, an undo, and an unrevertable scene execution.
@MainActor
@Observable
final class FixtureActivityStore: ActivityViewModel {
    let activityEvents: [ActivityEvent]
    let proposals: [NilesProposal]
    var undoFailures: [String: ActivityUndoFailure] = [:]

    func undo(_ id: String) {}
    func clearUndoFailure(_ id: String) { undoFailures[id] = nil }

    init(now: Date = Date()) {
        let minute: TimeInterval = 60
        let hour: TimeInterval = 60 * minute
        func evidence(_ claim: String) -> [ProposalEvidence] {
            [ProposalEvidence(claim: claim, observed: "\(claim) — confirmed on the live home", confirmed: true)]
        }

        proposals = [
            NilesProposal(
                id: "prop_fix_staged",
                tool: "set_zone_rooms",
                title: "Move Office into Upstairs",
                agentName: "Claude Code",
                createdAt: now.addingTimeInterval(-2 * minute),
                isDestructive: false,
                evidence: [],
                diff: [ProposalDiffLine(.add, "+ Upstairs · add room “Office”")],
                state: .staged
            ),
            NilesProposal(
                id: "prop_fix_undone",
                tool: "create_room",
                title: "Create room “Studio”",
                agentName: "Claude Code",
                createdAt: now.addingTimeInterval(-70 * minute),
                isDestructive: false,
                evidence: evidence("Room “Studio” exists"),
                diff: [ProposalDiffLine(.add, "+ Room “Studio”")],
                state: .executed
            ),
            NilesProposal(
                id: "prop_fix_undone_revert",
                tool: "create_room",
                title: "Undo — Create room “Studio”",
                agentName: "Claude Code",
                createdAt: now.addingTimeInterval(-45 * minute),
                isDestructive: false,
                evidence: evidence("No room prop_fix_undone remains"),
                diff: [ProposalDiffLine(.remove, "− Room “Studio”")],
                state: .executed,
                revertsProposalId: "prop_fix_undone"
            ),
            NilesProposal(
                id: "prop_fix_executed",
                tool: "rename_room",
                title: "Rename “Kitchen” to “Cookery”",
                agentName: "Obvious Agent",
                createdAt: now.addingTimeInterval(-25 * minute),
                isDestructive: false,
                evidence: evidence("Room room-2 is named “Cookery”"),
                diff: [ProposalDiffLine(.plain, "Kitchen → Cookery")],
                state: .executed
            ),
        ]

        activityEvents = [
            ActivityEvent(
                at: now.addingTimeInterval(-2 * minute), kind: .staged,
                proposalId: "prop_fix_staged", proposalTitle: "Move Office into Upstairs",
                agentName: "Claude Code"
            ),
            ActivityEvent(
                at: now.addingTimeInterval(-25 * minute), kind: .executed,
                proposalId: "prop_fix_executed", proposalTitle: "Rename “Kitchen” to “Cookery”",
                agentName: "Obvious Agent", detail: "1 of 1 checks confirmed",
                evidence: evidence("Room room-2 is named “Cookery”")
            ),
            ActivityEvent(
                at: now.addingTimeInterval(-25 * minute, ), kind: .decided,
                proposalId: "prop_fix_executed", proposalTitle: "Rename “Kitchen” to “Cookery”",
                agentName: "Obvious Agent", decision: "approved"
            ),
            ActivityEvent(
                at: now.addingTimeInterval(-45 * minute), kind: .executed,
                proposalId: "prop_fix_undone_revert", proposalTitle: "Undo — Create room “Studio”",
                agentName: "Claude Code", detail: "1 of 1 checks confirmed — revert of “Create room “Studio””",
                evidence: evidence("No room prop_fix_undone remains")
            ),
            ActivityEvent(
                at: now.addingTimeInterval(-46 * minute), kind: .undone,
                proposalId: "prop_fix_undone", proposalTitle: "Create room “Studio”",
                agentName: "Claude Code", detail: "Reverted — Undo — Create room “Studio”"
            ),
            ActivityEvent(
                at: now.addingTimeInterval(-70 * minute), kind: .executed,
                proposalId: "prop_fix_undone", proposalTitle: "Create room “Studio”",
                agentName: "Claude Code", detail: "1 of 1 checks confirmed",
                evidence: evidence("Room “Studio” exists")
            ),
            ActivityEvent(
                at: now.addingTimeInterval(-70 * minute), kind: .decided,
                proposalId: "prop_fix_undone", proposalTitle: "Create room “Studio”",
                agentName: "Claude Code", decision: "approved"
            ),
            ActivityEvent(
                at: now.addingTimeInterval(-5 * hour), kind: .executed,
                proposalId: "prop_fix_scene", proposalTitle: "Run scene “Good Morning”",
                agentName: "Claude Code", detail: "1 of 1 checks confirmed"
            ),
            ActivityEvent(
                at: now.addingTimeInterval(-26 * hour), kind: .expired,
                proposalId: "prop_fix_expired", proposalTitle: "Delete room “Storage”",
                agentName: "Obvious Agent", detail: "Expired after 24 hours — never executed"
            ),
        ]
    }
}

#Preview("Activity") {
    ActivityScreen(model: FixtureActivityStore())
}
