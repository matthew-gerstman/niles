import Foundation
import NilesCore
import Observation

/// One inline failure from an Undo tap. A conflicted revert carries the
/// typed `undoConflict` divergences — what moved in the home since the
/// original was applied; every other failure (lost revert plan, unknown id,
/// an unreadable home) renders its message with no divergence rows.
struct ActivityUndoFailure: Equatable {
    let message: String
    let divergences: [ProposalEvidence]
}

/// The Activity tab observes this protocol, never the concrete store — the
/// same discipline every screen in the rebuild keeps. The live store fills
/// it from the persistent ActivityLog and the proposal store; previews and
/// the screenshot fixture fill it from fixtures.
@MainActor
protocol ActivityViewModel: Observable {
    /// The persistent timeline, oldest first (append order).
    var activityEvents: [ActivityEvent] { get }
    var proposals: [NilesProposal] { get }
    /// Proposal id -> the failure from that proposal's most recent Undo tap,
    /// surfaced inline until the next attempt or dismissal.
    var undoFailures: [String: ActivityUndoFailure] { get }
    /// Applies the paired revert immediately — the tap IS the approval.
    func undo(_ id: String)
    func clearUndoFailure(_ id: String)
}

/// Pure construction of the timeline from the two public read models the
/// store publishes — the event log and the live proposals. No actor, no
/// polling: everything here is a named function over immutable inputs, which
/// is what the view-model tests exercise.
enum ActivityTimeline {

    /// The verdict chip an event renders as. A decided event inherits its
    /// decision; an executed one is a failure when execution recorded one.
    enum Verdict: Equatable {
        case staged, approved, denied, executed, failed, expired, undone
    }

    /// One rendered timeline entry.
    struct Row: Identifiable, Equatable {
        let event: ActivityEvent
        let verdict: Verdict
        /// `tool · prop_xxx` when the tool is known from the live proposal;
        /// the id alone after a relaunch, which wipes in-memory proposals.
        let toolLine: String
        /// True only for recent executed cards whose conflict-free paired
        /// revert still exists (see `undoAvailability`).
        let undoAvailable: Bool
        /// For `.undone` rows: the revert proposal's own read-back evidence,
        /// found through the live revert's link to the original.
        let revertEvidence: [ProposalEvidence]
        /// For `.undone` rows: the live revert proposal's title ("Undo — …").
        let revertTitle: String?

        var id: String { event.id }
    }

    /// A recency bucket of rows, newest first ("Today", "Yesterday", …).
    struct Section: Identifiable, Equatable {
        let title: String
        let rows: [Row]
        var id: String { title }
    }

    /// Builds timeline rows from the log (append order) — output is newest
    /// first, the direction the timeline renders.
    static func rows(events: [ActivityEvent], proposals: [NilesProposal]) -> [Row] {
        events
            .sorted { $0.at > $1.at }
            .map { event in
                let proposal = proposals.first { $0.id == event.proposalId }
                var revertEvidence: [ProposalEvidence] = []
                var revertTitle: String?
                if event.kind == .undone, let revert = proposals.first(where: { $0.revertsProposalId == event.proposalId }) {
                    revertTitle = revert.title
                    // The revert's own evidence is on its executed event —
                    // the undo is only honest if the revert actually applied.
                    revertEvidence = executedEvent(of: revert.id, in: events)?.evidence ?? []
                }
                return Row(
                    event: event,
                    verdict: verdict(of: event, proposal: proposal),
                    toolLine: toolLine(of: event, proposal: proposal),
                    undoAvailable: undoAvailability(event: event, events: events, proposals: proposals),
                    revertEvidence: revertEvidence,
                    revertTitle: revertTitle
                )
            }
    }

    /// Groups rows by recency and orders the buckets themselves.
    static func sections(rows: [Row], calendar: Calendar = .current, now: Date = Date()) -> [Section] {
        var buckets: [(title: String, rows: [Row])] = []
        for row in rows {
            let title = Self.bucket(of: row.event.at, calendar: calendar, now: now)
            if let index = buckets.firstIndex(where: { $0.title == title }) {
                buckets[index].rows.append(row)
            } else {
                buckets.append((title, [row]))
            }
        }
        return buckets.map { Section(title: $0.title, rows: $0.rows) }
    }

    /// Whether a card offers Undo. Every gate is checkable from the public
    /// read models — the store keeps its revert plans private, so "conflict-
    /// free" is enforced at tap time (a conflict surfaces inline); what the
    /// UI can and must know first:
    /// - only `.executed` events ever offer Undo;
    /// - the executed proposal must still exist in memory with its revert
    ///   plan — a relaunch wipes both, so history entries offer nothing;
    /// - an already-undone change (a live revert proposal, or an `.undone`
    ///   event in the log) never offers Undo — there is no undo of an undo;
    /// - scene execution has no meaningful inverse (spec) — never Undo.
    static func undoAvailability(
        event: ActivityEvent,
        events: [ActivityEvent],
        proposals: [NilesProposal]
    ) -> Bool {
        guard event.kind == .executed else { return false }
        guard let proposal = proposals.first(where: { $0.id == event.proposalId }),
              proposal.state == .executed,
              proposal.revertsProposalId == nil else { return false }
        guard !proposals.contains { $0.revertsProposalId == event.proposalId } else { return false }
        guard !events.contains { $0.kind == .undone && $0.proposalId == event.proposalId } else { return false }
        guard proposal.tool != "execute_scene" else { return false }
        return true
    }

    // MARK: - Row mapping

    private static func verdict(of event: ActivityEvent, proposal: NilesProposal?) -> Verdict {
        switch event.kind {
        case .staged: return .staged
        case .decided: return event.decision == "denied" ? .denied : .approved
        case .expired: return .expired
        case .undone: return .undone
        case .executed:
            if proposal?.state == .failed { return .failed }
            // After a relaunch the proposal is gone; the execution outcome
            // line ("Failed — …") is the surviving record.
            if event.detail?.hasPrefix("Failed") == true { return .failed }
            return .executed
        }
    }

    private static func toolLine(of event: ActivityEvent, proposal: NilesProposal?) -> String {
        guard let tool = proposal?.tool else { return event.proposalId }
        return "\(tool) · \(event.proposalId)"
    }

    private static func executedEvent(of proposalId: String, in events: [ActivityEvent]) -> ActivityEvent? {
        events.last { $0.proposalId == proposalId && $0.kind == .executed }
    }

    private static func bucket(of date: Date, calendar: Calendar, now: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now), date >= weekAgo {
            return "This Week"
        }
        return "Earlier"
    }
}
