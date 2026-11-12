import Foundation
import NilesCore
import Observation
import OSLog
import UIKit

/// The decision pipeline and the activity timeline: the `QueueViewModel` and
/// `ActivityViewModel` seams of the former monolithic `LiveNilesStore`, kept
/// together as one focused store (cleanup W3). They share one set of
/// bookkeeping — decisions in flight, undo conflicts and refusals, the
/// per-row failure the activity card renders — and one pipeline: every
/// decision, undo, and state transition observed by the poll lands here.
///
/// State is written in exactly two places: this store's own tap actions, and
/// `LiveNilesStore.refresh` — the single poll fan-out — through
/// `applyProposals`/`reloadActivity`.
@MainActor
@Observable
final class LiveQueueStore: QueueViewModel, ActivityViewModel {

    private(set) var proposals: [NilesProposal] = []
    /// Optimistic tap feedback: proposal id -> decision whose pipeline
    /// round-trip is still running. Set synchronously in the tap handler,
    /// cleared when the pipeline settles (or the decision fails).
    private(set) var decisionsInFlight: [String: ProposalDecision] = [:]
    /// Screenshot-fixture freeze (see `seedQueueFixtureIfRequested`): ids
    /// whose UI proposal state `refresh` must not remap from the store —
    /// the planted state has no live counterpart behind it.
    private(set) var frozenProposalIds: Set<String> = []
    /// Per-row failures from each proposal's most recent swipe decision,
    /// surfaced as a row-level note (the row is back in the Queue) until
    /// the next attempt or dismissal — never only a log line.
    private(set) var decisionFailures: [String: String] = [:]
    /// The activity timeline as of the last refresh, oldest first.
    private(set) var activityEvents: [ActivityEvent] = []
    /// True from the Approve-all tap until the whole batch settles — the
    /// batch button shows progress and cannot re-enter.
    private(set) var isApprovingAll = false
    /// Undo bookkeeping (Queue): per-row divergences recorded from the
    /// store's typed `undoConflict`, rows the store refused with
    /// `notRevertable`, and taps whose revert is still running. All
    /// in-memory, like the proposals themselves.
    private var undoConflicts: [String: [ProposalEvidence]] = [:]
    private var notRevertableIds: Set<String> = []
    private var undosInFlight: Set<String> = []
    /// Undo failures from each proposal's most recent tap, surfaced inline on
    /// the activity card until the next attempt or dismissal.
    private(set) var undoFailures: [String: ActivityUndoFailure] = [:]

    var pendingProposals: [NilesProposal] {
        proposals.filter(\\.isPending)
    }

    private let coordinator: ServerCoordinator
    /// The persistent activity timeline, appended to as decisions and state
    /// changes happen (see ActivityLog).
    private let activityLog: ActivityLog

    /// The composition root that owns this store and the shared poll loop.
    /// Weak: the root holds its stores strongly, and both live for the
    /// process lifetime — the reference is wired at the end of the root's
    /// init, before any tap can run.
    weak var root: LiveNilesStore?

    private let logger = Logger(subsystem: "com.gerstman.niles", category: "live-queue")

    init(coordinator: ServerCoordinator, activityLog: ActivityLog) {
        self.coordinator = coordinator
        self.activityLog = activityLog
    }

    // MARK: - QueueViewModel

    /// Approves and executes the staged operations; the result (state,
    /// evidence, error) appears on the card at the next refresh.
    func approve(_ id: String) {
        beginDecision(.approving, id: id)
        Task { await approveAndWait(id) }
    }

    func deny(_ id: String) {
        beginDecision(.denying, id: id)
        Task { await denyAndWait(id) }
    }

    /// Awaitable decision path — what the button handlers spawn; tests and
    /// this store's own tasks await it directly.
    func approveAndWait(_ id: String) async {
        await decide(approve: true, id: id)
    }

    func denyAndWait(_ id: String) async {
        await decide(approve: false, id: id)
    }

    /// Optimistic tap feedback, applied synchronously before the pipeline
    /// task is even spawned: the card's in-progress chip and disabled
    /// buttons render on the next frame and the haptic fires at the tap,
    /// so the pipeline round-trip can never make a tap look dead.
    /// `decide` clears the marker when the pipeline settles or fails.
    private func beginDecision(_ decision: ProposalDecision, id: String) {
        guard proposals.first(where: { $0.id == id })?.isPending == true else { return }
        decisionsInFlight[id] = decision
        // A fresh attempt clears the last failure, like undoFailures.
        decisionFailures[id] = nil
        let haptic = UINotificationFeedbackGenerator()
        haptic.prepare()
        haptic.notificationOccurred(decision == .approving ? .success : .warning)
    }

    private func decide(approve: Bool, id: String) async {
        guard let store = coordinator.proposalStore else {
            let verb = approve ? "approve" : "deny"
            logger.error("Cannot \\(verb, privacy: .public) \\(id, privacy: .public): no proposal store")
            // The decision did not land — hand the row back to the Queue
            // with a visible failure note, not only the log line.
            decisionsInFlight[id] = nil
            decisionFailures[id] = Self.decisionFailureMessage(
                approve: approve, reason: "the proposal store is unavailable"
            )
            return
        }
        do {
            if approve {
                _ = try await store.approve(id: id)
            } else {
                _ = try await store.deny(id: id)
            }
            await appendActivity(
                .decided,
                proposalId: id,
                title: proposals.first { $0.id == id }?.title ?? id,
                agentName: root?.agentName(for: id),
                decision: approve ? "approved" : "denied"
            )
        } catch {
            // Terminal-state violations and unknown ids are the expected
            // failures here. The decision did not land: drop the chip,
            // surface the failure as a row-level note (the swipe re-enables
            // and the row returns to the Queue), and let the next refresh
            // render the store's real state.
            logger.error("Decision failed for \\(id): \\(String(describing: error))")
            decisionsInFlight[id] = nil
            decisionFailures[id] = Self.decisionFailureMessage(
                approve: approve, reason: String(describing: error)
            )
        }
        await root?.refresh()
        // Settled either way: the refreshed state is authoritative.
        decisionsInFlight[id] = nil
    }

    /// Plain language for a failed decision tap — the row-level note. Pure,
    /// so the wording is pin-able. The row is back in the Queue either way;
    /// the wording never claims what did or didn't reach the home.
    static func decisionFailureMessage(approve: Bool, reason: String) -> String {
        let verb = approve ? "Approve" : "Deny"
        return "\\(verb) failed — the proposal is back in the queue. (\\(reason))"
    }

    func clearDecisionFailure(_ id: String) {
        decisionFailures[id] = nil
    }

    // MARK: - Screenshot fixture plants

    /// Screenshot fixtures only: plants an in-flight decision. The real
    /// pipeline settles in milliseconds on the fake home — too fast to
    /// capture — so the fixture renders the exact state a real swipe shows
    /// while the pipeline runs.
    func plantInFlightDecision(_ id: String, _ decision: ProposalDecision = .approving) {
        decisionsInFlight[id] = decision
    }

    /// Screenshot fixtures only: plants the store-driven in-flight shape —
    /// the proposal the pipeline has decided and is executing, its persisted
    /// state `approved`, with no local swipe marker — and freezes the row so
    /// the poll cannot remap the planted state out from under a capture.
    /// Returns the frozen proposal (for the caller's activity event), or
    /// nil when no such row exists.
    @discardableResult
    func plantApprovedInFlight(_ id: String) -> NilesProposal? {
        guard let index = proposals.firstIndex(where: { $0.id == id }) else { return nil }
        proposals[index].state = .approved
        frozenProposalIds.insert(id)
        return proposals[index]
    }

    /// Screenshot fixtures only: plants a failed decision's row-level note
    /// with the same wording a real failed tap produces.
    func plantDecisionFailure(_ id: String, approve: Bool, reason: String) {
        decisionFailures[id] = Self.decisionFailureMessage(approve: approve, reason: reason)
    }

    // MARK: - Undo and approve-all

    /// Undoes an executed proposal: its paired revert stages and executes
    /// immediately as a forward-only proposal — the Undo tap IS the
    /// approval. A conflicted revert throws and changes nothing; the row
    /// renders the typed `undoConflict` divergences inline until the next
    /// undo attempt on that row. A `notRevertable` refusal stops the row
    /// from offering Undo at all.
    func undo(_ id: String) {
        // Optimistic tap feedback, synchronous like the decision taps: the
        // row's Undoing… state renders before the pipeline task runs.
        guard let proposal = proposals.first(where: { $0.id == id }),
              Self.undoAvailable(for: proposal, proposals: proposals) else { return }
        undosInFlight.insert(id)
        undoConflicts[id] = nil
        Task { await undoAndWait(id) }
    }

    func undoAndWait(_ id: String) async {
        guard let store = coordinator.proposalStore else {
            logger.error("Cannot undo \\(id, privacy: .public): no proposal store")
            return
        }
        undosInFlight.insert(id)
        undoConflicts[id] = nil
        defer { undosInFlight.remove(id) }
        // A fresh tap clears the last failure before it runs.
        undoFailures[id] = nil
        do {
            let revert = try await store.undo(proposalId: id)
            await appendActivity(
                .undone,
                proposalId: id,
                title: proposals.first { $0.id == id }?.title ?? id,
                agentName: root?.agentName(for: id),
                detail: "Reverted — \\(revert.title)"
            )
        } catch let error as ProposalStoreError {
            switch error {
            case .undoConflict(_, let divergences):
                // The home diverged from what execution produced. Nothing
                // was applied; the row names the divergence inline.
                undoConflicts[id] = divergences
            case .notRevertable:
                // No paired revert exists (unrevertable operation, lost undo
                // coverage, or a spent plan): the affordance goes away.
                notRevertableIds.insert(id)
            case .proposalNotFound, .proposalNotPending, .homeReadFailed:
                logger.error("Undo failed for \\(id, privacy: .public): \\(String(describing: error))")
            case .unknownTool, .invalidArguments, .validationFailed:
                // Unreachable from undo — staging errors surface to agents,
                // not to this tap path. Never silently swallowed: logged.
                logger.error("Undo failed for \\(id, privacy: .public): \\(String(describing: error))")
            }
            // The typed failure surfaces inline on the activity card too —
            // a conflict names the divergences; nothing was applied either way.
            undoFailures[id] = Self.undoFailure(for: error)
        } catch {
            logger.error("Undo failed for \\(id, privacy: .public): \\(String(describing: error))")
            // The typed failure surfaces inline on the card — a conflict
            // names the divergences; nothing was applied either way.
            undoFailures[id] = Self.undoFailure(for: error)
        }
        await root?.refresh()
    }

    /// Whether an executed proposal still offers Undo — pure so the
    /// affordance rules are directly testable:
    /// - only executed rows offer it (staged rows decide; terminal rows are
    ///   history);
    /// - unrevertable operations never offer it — `RevertPlanBuilder` (the
    ///   authority) builds no revert for scene execution, identify, unblock,
    ///   or accessory removal, so the store would refuse with
    ///   `notRevertable`;
    /// - an EXECUTED revert child means the row is already undone and there
    ///   is no undo of an undo. A failed revert child does not count: the
    ///   store keeps the original's revert plan when its revert fails, so
    ///   Undo still applies.
    static func undoAvailable(for proposal: NilesProposal, proposals: [NilesProposal]) -> Bool {
        guard proposal.state == .executed else { return false }
        guard !unrevertableTools.contains(proposal.tool) else { return false }
        return !proposals.contains { child in
            child.revertsProposalId == proposal.id && child.state == .executed
        }
    }

    /// The staged verbs whose operations have no meaningful inverse. Mirrors
    /// `RevertPlanBuilder`'s unrevertable operation set (the only source of
    /// truth for revertability); if a new unrevertable operation lands in the
    /// store, add its tool here — until then the tap surfaces the store's
    /// typed `notRevertable` and the row stops offering Undo.
    private static let unrevertableTools: Set<String> = [
        "execute_scene", "identify_accessory", "unblock_accessory", "remove_accessory",
    ]

    /// Per-row Undo affordance state: the availability rules above, overlaid
    /// with this session's tap bookkeeping (in flight, divergences, refusals).
    var undoStates: [String: UndoState] {
        var states: [String: UndoState] = [:]
        for proposal in proposals {
            guard Self.undoAvailable(for: proposal, proposals: proposals) else { continue }
            if undosInFlight.contains(proposal.id) {
                states[proposal.id] = .inFlight
            } else if let divergences = undoConflicts[proposal.id] {
                states[proposal.id] = .conflict(divergences)
            } else if notRevertableIds.contains(proposal.id) {
                states[proposal.id] = .notRevertable
            } else {
                states[proposal.id] = .idle
            }
        }
        return states
    }

    /// The card's inline failure from an Undo tap, mapped from the typed
    /// store error. Pure, so tests can pin the wording per error kind.
    static func undoFailure(for error: Error) -> ActivityUndoFailure {
        guard let storeError = error as? ProposalStoreError else {
            return ActivityUndoFailure(message: "Undo failed — nothing was changed.", divergences: [])
        }
        switch storeError {
        case .undoConflict(_, let divergences):
            return ActivityUndoFailure(
                message: "Undo blocked — the home has changed since this was applied. Nothing was changed.",
                divergences: divergences
            )
        case .notRevertable:
            return ActivityUndoFailure(
                message: "Undo is no longer available for this change — nothing was changed.",
                divergences: []
            )
        case .homeReadFailed:
            return ActivityUndoFailure(
                message: "Undo failed — the home could not be read. Nothing was changed.",
                divergences: []
            )
        default:
            return ActivityUndoFailure(
                message: "Undo failed — nothing was changed. (\\(storeError))",
                divergences: []
            )
        }
    }

    func clearUndoFailure(_ id: String) {
        undoFailures[id] = nil
    }

    /// Approves and executes every staged proposal immediately —
    /// destructive included. Undo afterwards is per-item, each with its
    /// own conflict check.
    func approveAll() {
        guard let store = coordinator.proposalStore else {
            logger.error("Cannot approve all: no proposal store")
            return
        }
        let stagedIds = beginApproveAllBatch()
        guard !stagedIds.isEmpty else { return }
        Task { await approveAllBatch(on: store, clearing: stagedIds) }
    }

    /// Awaitable batch path — what the tap task spawns; tests await it
    /// directly.
    func approveAllAndWait() async {
        guard let store = coordinator.proposalStore else {
            logger.error("Cannot approve all: no proposal store")
            return
        }
        let stagedIds = beginApproveAllBatch()
        guard !stagedIds.isEmpty else { return }
        await approveAllBatch(on: store, clearing: stagedIds)
    }

    /// Optimistic batch feedback, applied synchronously before the pipeline
    /// task is even spawned — same contract as the single tap: every staged
    /// row shows its in-progress chip on the next frame, one success haptic
    /// fires for the whole batch, and the button cannot re-enter while the
    /// batch runs. Returns the staged ids whose chips must settle.
    @discardableResult
    private func beginApproveAllBatch() -> [String] {
        let stagedIds = proposals.filter(\\.isPending).map(\\.id)
        guard !stagedIds.isEmpty else { return stagedIds }
        for id in stagedIds {
            decisionsInFlight[id] = .approving
        }
        isApprovingAll = true
        let haptic = UINotificationFeedbackGenerator()
        haptic.prepare()
        haptic.notificationOccurred(.success)
        return stagedIds
    }

    private func approveAllBatch(on store: ProposalStore, clearing stagedIds: [String]) async {
        defer { isApprovingAll = false }
        do {
            let executed = try await store.approveAll()
            for proposal in executed {
                await appendActivity(
                    .decided,
                    proposalId: proposal.id,
                    title: proposals.first { $0.id == proposal.id }?.title ?? proposal.id,
                    agentName: root?.agentName(for: proposal.id),
                    decision: "approved"
                )
            }
        } catch {
            logger.error("Approve all failed: \\(String(describing: error))")
        }
        await root?.refresh()
        // Settled: the refreshed states are authoritative.
        for id in stagedIds {
            decisionsInFlight[id] = nil
        }
    }

    // MARK: - Activity

    /// Appends one event to the persistent activity log and mirrors it into
    /// `activityEvents`. Append failures are logged by the log itself, never
    /// thrown — the timeline must not take a decision down with it.
    /// Internal: the poll fan-out appends the transitions it observes.
    func appendActivity(
        _ kind: ActivityEvent.Kind,
        proposalId: String,
        title: String,
        agentName: String?,
        decision: String? = nil,
        detail: String? = nil,
        evidence: [ProposalEvidence] = []
    ) async {
        await activityLog.append(ActivityEvent(
            at: Date(),
            kind: kind,
            proposalId: proposalId,
            proposalTitle: title,
            agentName: agentName,
            decision: decision,
            detail: detail,
            evidence: evidence
        ))
        activityEvents = await activityLog.allEvents()
    }

    // MARK: - Poll fan-out (called only by LiveNilesStore.refresh)

    /// The refreshed queue rows, mapped by the composition root.
    func applyProposals(_ refreshed: [NilesProposal]) {
        proposals = refreshed
    }

    /// Re-reads the timeline mirror after the fan-out's appends.
    func reloadActivity() async {
        activityEvents = await activityLog.allEvents()
    }
}
