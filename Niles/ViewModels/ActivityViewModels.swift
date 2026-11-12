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
    /// Proposal id -> decision in flight; an entry renders that proposal's
    /// group as a processing row (Denying…/Executing…) — decided-in-progress.
    var decisionsInFlight: [String: ProposalDecision] { get }
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
    /// `.denying` / `.executing` never come from an event — they overlay a
    /// group whose decision is still in flight (see `groups`).
    enum Verdict: Equatable {
        case staged, approved, denied, executed, failed, expired, undone
        case denying, executing
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

    /// One lifecycle entry inside a proposal group: the event plus the
    /// verdict it renders as (a decided event inherits its decision, an
    /// executed one may be a failure).
    struct EventEntry: Equatable {
        let event: ActivityEvent
        let verdict: Verdict
    }

    /// One rendered proposal card: all of a proposal's events collapsed into
    /// a single row. `state` is the furthest lifecycle state reached (an
    /// undone proposal stays Undone; an executed failure stays Failed);
    /// `latestAt` is the newest event's timestamp; `events` is newest first.
    struct Group: Identifiable, Equatable {
        let proposalId: String
        let title: String
        let state: Verdict
        let latestAt: Date
        let events: [EventEntry]
        /// The MCP tool name when the live proposal is in memory — plumbing,
        /// rendered only in the detail sheet's secondary section.
        let toolName: String?
        let undoAvailable: Bool
        /// The most recent executed event's structured read-back.
        let evidence: [ProposalEvidence]
        /// For `.undone` groups: the revert's own read-back evidence.
        let revertEvidence: [ProposalEvidence]
        /// For `.undone` groups: the live revert proposal's title ("Undo — …").
        let revertTitle: String?

        var id: String { proposalId }
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

    /// Collapses the per-event timeline into one group per proposal, newest
    /// proposal first (by its most recent event). A pure view-layer grouping
    /// over the same persisted events `rows` renders individually.
    ///
    /// `decisionsInFlight` overlays the processing state: a swipe decision
    /// whose pipeline is still running renders as Denying…/Executing… —
    /// decided-in-progress — instead of the proposal's last settled event.
    /// A proposal the store has already moved into execution (`approved`,
    /// no local swipe marker — any pipeline client can drive that
    /// transition) renders Executing… for the same reason.
    static func groups(
        events: [ActivityEvent],
        proposals: [NilesProposal],
        decisionsInFlight: [String: ProposalDecision] = [:],
        now: Date = Date()
    ) -> [Group] {
        let rows = Self.rows(events: events, proposals: proposals)
        var order: [String] = []
        var byProposal: [String: [Row]] = [:]
        for row in rows {
            let id = row.event.proposalId
            if byProposal[id] == nil { order.append(id) }
            byProposal[id, default: []].append(row)
        }
        // An in-flight decision always renders even if the log holds no
        // event for the proposal yet — a processing row must never vanish
        // between the swipe and the pipeline's first event.
        for id in decisionsInFlight.keys where byProposal[id] == nil {
            order.append(id)
            byProposal[id] = []
        }
        return order.map { id in
            let eventRows = byProposal[id]!
            let newest = eventRows.first
            let proposal = proposals.first { $0.id == id }
            let tool = proposal?.tool
            // The most recent execution carries the read-back that counts.
            let executedRow = eventRows.first { $0.event.kind == .executed }
            let undoneRow = eventRows.first { $0.event.kind == .undone }
            let state: Verdict
            if let decision = decisionsInFlight[id] {
                // Approve runs the execution pipeline; deny is a decision
                // alone — hence the two processing names.
                state = decision == .approving ? .executing : .denying
            } else if proposal?.state == .approved {
                // Store-driven in-flight: the pipeline has decided the
                // proposal and execution is still running (any pipeline
                // client — a relaunch mid-execution included; the poll
                // surfaces the persisted `approved` state). Same processing
                // treatment as a swipe in flight; the Queue hides the row
                // for the same reason.
                state = .executing
            } else {
                state = mergedVerdict(eventRows.map(\.verdict))
            }
            return Group(
                proposalId: id,
                title: newest?.event.proposalTitle ?? proposal?.title ?? id,
                state: state,
                latestAt: newest?.event.at ?? now,
                events: eventRows.map { EventEntry(event: $0.event, verdict: $0.verdict) },
                toolName: tool,
                undoAvailable: executedRow.map {
                    undoAvailability(event: $0.event, events: events, proposals: proposals)
                } ?? false,
                evidence: executedRow?.event.evidence ?? [],
                revertEvidence: undoneRow?.revertEvidence ?? [],
                revertTitle: undoneRow?.revertTitle
            )
        }
    }

    /// The furthest state a proposal's events reached. Undo dominates (the
    /// last word on a change), then failure, then execution, then the
    /// decision, then expiry, then bare staging.
    private static func mergedVerdict(_ verdicts: [Verdict]) -> Verdict {
        for state in [Verdict.undone, .failed, .executed, .denied, .approved, .expired] {
            if verdicts.contains(state) { return state }
        }
        return .staged
    }

    /// Plain language for an execution's read-back. The raw tally
    /// ("1 of 1 checks confirmed") is plumbing; a person is told what was
    /// actually done — the home was re-read and compared — with the count
    /// only as context. Returns nil when there is nothing to report.
    static func evidenceSummary(_ evidence: [ProposalEvidence]) -> String? {
        guard !evidence.isEmpty else { return nil }
        let confirmed = evidence.filter(\.confirmed).count
        let total = evidence.count
        let totalChecks = total == 1 ? "1 check" : "\(total) checks"
        let notRun = evidence.filter(\.notRun).count
        if confirmed == total {
            return "Re-read the home after execution; state matched expectations (\(totalChecks))."
        }
        let notRunNote = notRun == 0 ? ""
            : notRun == 1 ? " 1 entry never ran — the batch aborted first."
            : " \(notRun) entries never ran — the batch aborted first."
        if confirmed == 0 {
            return "Re-read the home after execution; the home did not match expectations.\(notRunNote)"
        }
        let confirmedChecks = confirmed == 1 ? "1 check" : "\(confirmed) checks"
        return "Re-read the home after execution; \(confirmedChecks) of \(totalChecks) matched expectations.\(notRunNote)"
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
        guard !proposals.contains(where: { $0.revertsProposalId == event.proposalId }) else { return false }
        guard !events.contains(where: { $0.kind == .undone && $0.proposalId == event.proposalId }) else { return false }
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
