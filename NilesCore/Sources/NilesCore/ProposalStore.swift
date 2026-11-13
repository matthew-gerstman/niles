import Foundation

/// Errors raised along the proposal pipeline. Every case is reportable to the
/// agent in-band; validation failures carry per-action details.
public enum ProposalStoreError: Error, Equatable, Sendable {
    case unknownTool(String)
    case invalidArguments(String)
    case validationFailed([String])
    case proposalNotFound(String)
    case proposalNotPending(id: String, state: ProposalState)
    case homeReadFailed(String)
    /// The executed record has no paired revert — an operation without a
    /// meaningful inverse (scene execution), a proposal that never executed,
    /// or one already undone.
    case notRevertable(id: String)
    /// The home has diverged from what execution produced, so the paired
    /// revert can no longer be applied safely. The divergences name what
    /// moved; nothing was changed.
    case undoConflict(id: String, divergences: [ProposalEvidence])
}

/// The staging, approval, and expiry machine at the heart of the spec.
///
/// Agents stage through `stage(tool:arguments:)`; every accepted request
/// becomes exactly one proposal — planning collapses a declarative request to
/// minimal operations and one review card. Nothing here or in any write tool
/// touches HomeKit until `approve(id:)` runs the staged operations, and
/// denied or expired proposals never run anything.
///
/// Expiry is lazy: the store only exists while the app is foregrounded, so
/// there is no timer to run — every read and decision first sweeps staged
/// proposals whose 24-hour TTL has passed into `.expired`.
public actor ProposalStore {
    /// Plans one write-tool request against the current graph. Throws
    /// `ProposalStoreError.validationFailed` before any proposal exists.
    /// Arguments are domain-typed — MCP clients' wire arguments decode at
    /// the registry boundary, and app-layer callers build these directly
    /// (cleanup W1).
    public typealias PlanFunction = @Sendable (String, [String: ToolArgument]?, HomeGraph) throws -> Plan

    /// The writing service this store executes approved operations against —
    /// also the read surface for in-band tools, so one service is the single
    /// authority for what the graph looks like before and after approval.
    public let homeKit: any HomeKitWriting
    private let planWith: PlanFunction
    private let now: @Sendable () -> Date
    private let lifetime: TimeInterval

    /// Oldest first; `proposals()` renders newest first, like the mockup queue.
    private var proposals: [Proposal] = []
    /// The most operations one `stage_batch` call may stage — beyond this
    /// the review card stops being one legible decision, and the error names
    /// the limit instead of staging a card nobody reads.
    public static let batchLimit = 20
    /// The operations behind each staged proposal — the execution detail the
    /// envelope intentionally omits. Cleared once terminal.
    private var operations: [String: [HomeKitOperation]] = [:]
    /// The paired revert captured at execution time for each executed
    /// proposal that can be undone. Persisted alongside the proposals, so
    /// undo survives a relaunch.
    private var revertPlans: [String: RevertPlan] = [:]

    /// Write-through persistence for the store's state. Nil keeps everything
    /// in-memory — tests, previews, and the pipeline's own unit seams.
    private let persistence: ProposalStoreFile?
    /// Staged proposals the load-time sweep expired. The app layer takes
    /// them once to record their activity events — the poll diff never saw
    /// the expiry, it happened while the app was dead.
    private var expiredAtLoad: [Proposal] = []
    /// The one launch-time revalidation pass over reloaded staged proposals.
    private var hasRevalidated = false

    /// Decision serialization: one decision's HomeKit operations and its
    /// read-back run as a unit, and the next decision (including a second
    /// tap on another card) waits its turn. Without this, actor reentrancy
    /// lets a later decision execute between an earlier decision's
    /// operations and its read-back snapshot — device QA F3: approving a
    /// zone delete while a zone-membership move was mid-execution made the
    /// move's read-back report "Zone not found after execution" for a zone
    /// the move had successfully joined.
    private var isDeciding = false
    private var decisionWaiters: [CheckedContinuation<Void, Never>] = []

    /// Enters the decision critical section, waiting fairly behind any
    /// decision already running. Ownership passes at resume: the waiter
    /// returns with `isDeciding` still true, so no third decision can
    /// steal the gate between handoffs.
    private func beginDecision() async {
        if isDeciding {
            await withCheckedContinuation { decisionWaiters.append($0) }
            return
        }
        isDeciding = true
    }

    private func endDecision() {
        if let next = decisionWaiters.first {
            decisionWaiters.removeFirst().resume()
        } else {
            isDeciding = false
        }
    }

    public init(
        homeKit: any HomeKitWriting,
        planWith: @escaping PlanFunction,
        now: @escaping @Sendable () -> Date = { Date() },
        lifetime: TimeInterval = 24 * 60 * 60,
        persistence: ProposalStoreFile? = nil
    ) {
        self.homeKit = homeKit
        self.planWith = planWith
        self.now = now
        self.lifetime = lifetime
        self.persistence = persistence
        // Load before the first actor method can run: the disk read makes
        // no HomeKit call, and staged/decided history must be in place
        // before the server accepts a staging or decision call. The expiry
        // sweep runs here too — a proposal staged before a relaunch that is
        // already past its TTL comes back expired, stamped with this
        // sweep's instant (the app layer records its activity event).
        if let persistence {
            var state = persistence.load()
            let current = now()
            var expired: [Proposal] = []
            for index in state.proposals.indices
            where state.proposals[index].state == .staged
                && state.proposals[index].expiresAt <= current {
                state.proposals[index].state = .expired
                expired.append(state.proposals[index])
            }
            if !expired.isEmpty {
                persistence.persist(state)
            }
            proposals = state.proposals
            operations = state.operations
            revertPlans = state.revertPlans
            expiredAtLoad = expired
        }
    }

    // MARK: - Staging

    /// Plans and stores one proposal for a write-tool call. Invalid requests
    /// throw before a proposal exists — the human never sees them.
    public func stage(tool: String, arguments: [String: ToolArgument]?) async throws -> Proposal {
        let graph: HomeGraph
        do {
            graph = try await homeKit.snapshot()
        } catch {
            throw ProposalStoreError.homeReadFailed(String(describing: error))
        }
        let plan = try planWith(tool, arguments, graph)
        return stage(plan: plan)
    }

    /// Stores an already-planned change as one proposal. Retrying a request
    /// whose plan matches a pending proposal returns that proposal unchanged
    /// (the spec's dedupe) instead of stacking duplicate cards.
    @discardableResult
    public func stage(plan: Plan) -> Proposal {
        stage(plan: plan, expiresAt: now().addingTimeInterval(lifetime))
    }

    /// Fixture seam for launch-argument QA: stages with an explicit expiry
    /// instant, so a fixture can seed a proposal that is staged on disk but
    /// already past its TTL when the app relaunches — exactly what the
    /// load-time sweep exists for. Normal staging computes the expiry from
    /// the store's lifetime.
    @discardableResult
    public func stage(plan: Plan, expiresAt: Date) -> Proposal {
        expireSweep()
        if let pending = pendingMatch(of: plan) { return pending }

        let proposal = Proposal(
            id: Self.newId(),
            tool: plan.tool,
            title: plan.title,
            summary: plan.summary,
            isDestructive: plan.isDestructive,
            entries: plan.entries,
            card: plan.card,
            validation: plan.validation,
            createdAt: now(),
            expiresAt: expiresAt
        )
        proposals.append(proposal)
        operations[proposal.id] = plan.operations
        persistSnapshot()
        return proposal
    }

    /// Stages many write-tool operations as ONE proposal — one review card,
    /// one notification, one approval (Blueprint art_iN2CYQKa). Every member
    /// names a staged write tool with its normal arguments, and every member
    /// plans against a single graph snapshot through the same per-tool
    /// planning the individual tools call.
    ///
    /// All-or-nothing planning: every member plans before anything stages.
    /// Any failure — unknown object, bad value, unknown tool — rejects the
    /// whole batch with per-entry errors and no proposal exists, matching
    /// `stage(tool:arguments:)`'s eager validation. Members carrying
    /// `set_trigger_state` are rejected outright: enabling or disarming an
    /// automation is always its own proposal and its own approval (the
    /// create/arm firewall). Approval runs the merged operations in order
    /// through the ordinary forward-only executor; a partial failure records
    /// which applied. Dedupe and persistence ride `stage(plan:)` unchanged.
    public func stageBatch(_ operations: [BatchOperation]) async throws -> Proposal {
        guard !operations.isEmpty else {
            throw ProposalStoreError.invalidArguments(
                "stage_batch requires at least one operation — an empty batch stages nothing."
            )
        }
        guard operations.count <= Self.batchLimit else {
            throw ProposalStoreError.invalidArguments(
                "A batch is limited to \(Self.batchLimit) operations (got \(operations.count)) — split the request into batches of \(Self.batchLimit) or fewer."
            )
        }
        if let armIndex = operations.firstIndex(where: { $0.tool == "set_trigger_state" }) {
            throw ProposalStoreError.validationFailed([
                "Operation \(armIndex + 1) (set_trigger_state) is not a valid batch member — enabling or disarming an automation is always its own proposal and its own approval (the create/arm firewall). Stage it separately."
            ])
        }
        let graph: HomeGraph
        do {
            graph = try await homeKit.snapshot()
        } catch {
            throw ProposalStoreError.homeReadFailed(String(describing: error))
        }
        var plans: [Plan] = []
        plans.reserveCapacity(operations.count)
        var failures: [String] = []
        for (index, operation) in operations.enumerated() {
            do {
                plans.append(try planWith(operation.tool, operation.arguments, graph))
            } catch {
                failures.append("Operation \(index + 1) (\(operation.tool)): \(Self.planningFailureMessage(error))")
            }
        }
        guard failures.isEmpty else {
            throw ProposalStoreError.validationFailed(failures)
        }
        return stage(plan: Self.merge(plans))
    }

    // MARK: - Reading

    /// All proposals, newest first. Terminal proposals stay listed: the
    /// approvals screen shows history and evidence alongside the queue.
    public func allProposals() -> [Proposal] {
        expireSweep()
        return proposals.reversed()
    }

    /// One proposal by id; throws `proposalNotFound` for unknown ids.
    public func proposal(id: String) throws -> Proposal {
        expireSweep()
        guard let proposal = proposals.first(where: { $0.id == id }) else {
            throw ProposalStoreError.proposalNotFound(id)
        }
        return proposal
    }

    // MARK: - Human decision

    /// Approves and executes. The staged operations run in order against
    /// HomeKit; afterwards a fresh graph is read back and evidence attached.
    ///
    /// HomeKit operations are not transactional (spec risk: "all-or-nothing
    /// by explicit policy"). Niles' policy is forward-only: a mid-list
    /// failure marks the proposal `.failed`, records the HomeKit error, and
    /// reads back whatever did apply so the human and the agent see the same
    /// story. Rejected-at-approval failures leave the home untouched.
    ///
    /// `memberRestore` is revert-only: the members returned to an object
    /// this execution re-creates, applied against the fresh id the re-create
    /// returns, inside the same forward-only run and read back by the same
    /// evidence.
    public func approve(id: String, memberRestore: MemberRestore? = nil) async throws -> Proposal {
        // The pre-execution state a revert would restore, captured at
        // execution time — before the first operation runs. A read failure
        // costs undo coverage, never execution.
        let preGraph = try? await homeKit.snapshot()
        var executedOperations: [HomeKitOperation] = []
        var recordedCreatedIds: [String?] = []
        let approved = try await decide(id: id, to: .approved) { [homeKit] proposal, operations in
            executedOperations = operations
            var updated = proposal
            // perform returns the created object's id per operation. Threading
            // those ids into evidence collection matches created rooms,
            // scenes, groups, and triggers by id — name matching is only the
            // fallback — so a same-named pre-existing object cannot
            // false-confirm a creation.
            var createdIds = [String?](repeating: nil, count: operations.count)
            var allOperations = operations
            // Per-entry applied marker: true the moment an entry's perform
            // returns. Graph-only evidence cannot tell executed from
            // never-attempted, so a forward-only abort stamps every entry
            // after the first unrun one as not-run instead of letting its
            // read-back read confirmed (Duo QA: identifies in an aborted
            // batch showed "✓ confirmed" without ever running).
            var ranFlags = [Bool](repeating: false, count: operations.count)
            var failureMessage: String?
            do {
                for (index, operation) in operations.enumerated() {
                    do {
                        createdIds[index] = try await homeKit.perform(operation)
                        ranFlags[index] = true
                    } catch {
                        failureMessage = HomeKitErrorNarrative.describe(error)
                        throw error
                    }
                }
                if let restore = memberRestore, let createdId = createdIds.compactMap({ $0 }).first {
                    let restoreOperations = restore.operations(createdId: createdId)
                    var restoreFlags = [Bool](repeating: false, count: restoreOperations.count)
                    for (index, restoreOperation) in restoreOperations.enumerated() {
                        do {
                            _ = try await homeKit.perform(restoreOperation)
                            restoreFlags[index] = true
                        } catch {
                            failureMessage = HomeKitErrorNarrative.describe(error)
                            throw error
                        }
                    }
                    // The restore rides in the same execution and the same
                    // read-back: each member's return is confirmed like any
                    // other operation.
                    allOperations += restoreOperations
                    createdIds += [String?](repeating: nil, count: restoreOperations.count)
                    ranFlags += restoreFlags
                }
                let fresh = try await homeKit.snapshot()
                updated.evidence = ProposalEvidenceCollector.collect(
                    operations: allOperations, createdIds: createdIds, graph: fresh,
                    ranFlags: ranFlags, failureMessage: failureMessage
                )
                updated.state = .executed
            } catch {
                // The HomeKit failure is recorded verbatim; evidence from
                // whatever did apply is still read back so the human and the
                // agent see the same story — with every unreached entry
                // marked not-run rather than confirmed off the graph alone.
                // If even the read-back fails, the error line stands alone —
                // and empty evidence is itself the honest observation.
                if let fresh = try? await homeKit.snapshot() {
                    updated.evidence = ProposalEvidenceCollector.collect(
                        operations: allOperations, createdIds: createdIds, graph: fresh,
                        ranFlags: ranFlags, failureMessage: failureMessage
                    )
                }
                updated.error = HomeKitErrorNarrative.describe(error)
                updated.state = .failed
            }
            recordedCreatedIds = createdIds
            return updated
        }
        // Only a clean execution offers undo: a failed one applied an
        // unknown prefix of its operations, and no plan can honestly
        // describe the partial state. Both snapshots read, the paired
        // revert is built and kept for the undo flow.
        if approved.state == .executed, let preGraph,
           let postGraph = try? await homeKit.snapshot(),
           let plan = RevertPlanBuilder.plan(
               operations: executedOperations, createdIds: recordedCreatedIds,
               preGraph: preGraph, postGraph: postGraph
           ) {
            revertPlans[id] = plan
            persistSnapshot()
        }
        return approved
    }

    /// Denies a staged proposal. Nothing ever executes — matching the
    /// HomeKitSync rule the spec adopts — and denial is terminal.
    @discardableResult
    public func deny(id: String) async throws -> Proposal {
        try await decide(id: id, to: .denied) { proposal, _ in proposal }
    }

    // MARK: - Undo and batch approval

    /// Undoes an executed proposal: its paired revert stages as a normal
    /// forward-only proposal and executes immediately — the Undo tap IS the
    /// approval. Execution never rewinds; the revert is a new set of
    /// operations with its own read-back evidence, linked to the original
    /// through the proposal's `revertsProposalId`.
    ///
    /// The current home must still match what execution produced — objects
    /// still exist where required, values still equal the recorded
    /// post-state, membership unchanged. A diverged home throws
    /// `undoConflict` naming what moved, and applies nothing. Records with
    /// no meaningful inverse (scene execution), proposals that never
    /// executed, and already-undone proposals throw `notRevertable`; there
    /// is no undo of an undo.
    @discardableResult
    public func undo(proposalId: String) async throws -> Proposal {
        guard let original = proposals.first(where: { $0.id == proposalId }) else {
            throw ProposalStoreError.proposalNotFound(proposalId)
        }
        guard original.state == .executed, let plan = revertPlans[proposalId] else {
            throw ProposalStoreError.notRevertable(id: proposalId)
        }
        let current: HomeGraph
        do {
            current = try await homeKit.snapshot()
        } catch {
            throw ProposalStoreError.homeReadFailed(String(describing: error))
        }
        let divergences = plan.conflicts(in: current)
        guard divergences.isEmpty else {
            throw ProposalStoreError.undoConflict(id: proposalId, divergences: divergences)
        }
        let revert = stage(plan: Plan(
            tool: original.tool,
            title: "Undo — \(original.title)",
            summary: "Restores the home to how it was before “\(original.title)” was applied.",
            isDestructive: plan.operations.contains { Self.isDestructiveOperation($0) },
            operations: plan.operations,
            entries: [],
            card: [ProposalCardLine(.note, "Reverts “\(original.title)” — applying the paired inverse.")]
        ))
        if let index = proposals.firstIndex(where: { $0.id == revert.id }) {
            proposals[index].revertsProposalId = proposalId
        }
        let executed = try await approve(id: revert.id, memberRestore: plan.memberRestore)
        if executed.state == .executed {
            // The revert applied: the original is now undone and its plan
            // is spent — no undo of an undo. The revert's own plan (if any
            // was captured) is dropped too; undoing a revert is not offered.
            revertPlans[proposalId] = nil
            revertPlans[revert.id] = nil
            persistSnapshot()
        }
        return executed
    }

    /// Approves and executes every staged proposal immediately — destructive
    /// included. Execution stays sequential and forward-only: each proposal
    /// runs to its own terminal state (a mid-batch HomeKit failure marks
    /// that proposal `.failed` while the rest still run). Undo afterwards is
    /// per-item, each with its own conflict check.
    @discardableResult
    public func approveAll() async throws -> [Proposal] {
        expireSweep()
        let ids = proposals.filter { $0.state == .staged }.map(\.id)
        var executed: [Proposal] = []
        for id in ids {
            executed.append(try await approve(id: id))
        }
        return executed
    }

    /// The delete operations — a revert containing any of these is itself
    /// destructive severity on the queue card.
    private static func isDestructiveOperation(_ operation: HomeKitOperation) -> Bool {
        switch operation {
        case .removeRoom, .removeZone, .removeActionSet, .removeServiceGroup, .removeTrigger, .removeAccessory:
            true
        default:
            false
        }
    }

    // MARK: - Internals

    private func decide(
        id: String,
        to next: ProposalState,
        execute: (Proposal, [HomeKitOperation]) async -> Proposal
    ) async throws -> Proposal {
        await beginDecision()
        defer { endDecision() }
        expireSweep()
        guard let index = proposals.firstIndex(where: { $0.id == id }) else {
            throw ProposalStoreError.proposalNotFound(id)
        }
        guard proposals[index].state.canTransition(to: next) else {
            throw ProposalStoreError.proposalNotPending(id: id, state: proposals[index].state)
        }
        // Reserve the transition before the await: a second decide for the
        // same proposal while execution is suspended fails the
        // canTransition check instead of double-executing.
        proposals[index].state = next
        let updated = await execute(proposals[index], operations[id] ?? [])
        proposals[index] = updated
        operations[id] = nil
        persistSnapshot()
        return updated
    }

    /// Marks every staged proposal past its TTL as `.expired` (a legal
    /// `staged -> expired` transition) and drops its operations. A sweep
    /// that changed something is a mutation batch — the new state persists.
    private func expireSweep() {
        let current = now()
        var expiredAny = false
        for index in proposals.indices
        where proposals[index].state == .staged && proposals[index].expiresAt <= current {
            proposals[index].state = .expired
            operations[proposals[index].id] = nil
            expiredAny = true
        }
        if expiredAny {
            persistSnapshot()
        }
    }

    private func pendingMatch(of plan: Plan) -> Proposal? {
        proposals.first { pending in
            pending.state == .staged
                && pending.tool == plan.tool
                && operations[pending.id] == plan.operations
        }
    }

    // MARK: - Launch reload

    /// Revalidates proposals loaded from disk against the current home,
    /// before the server accepts a staging or decision call. One graph read
    /// at launch — the load itself (init) makes none. Every staged proposal
    /// whose target object has vanished from the home stays in the Queue,
    /// marked with the named reason on the same error channel execution
    /// failures use; it is never dropped and never auto-executed. The human
    /// still decides — and approval re-checks against the live graph, so a
    /// stale flag can never let an operation through. Idempotent.
    public func revalidateAtLaunch() async {
        guard !hasRevalidated else { return }
        hasRevalidated = true
        guard proposals.contains(where: { $0.state == .staged }) else { return }
        let graph: HomeGraph
        do {
            graph = try await homeKit.snapshot()
        } catch {
            // An unreadable home leaves every staged proposal unflagged and
            // staged; the next approval still validates against the graph.
            NSLog("ProposalStore: launch revalidation skipped, home read failed: \(error)")
            return
        }
        for index in proposals.indices where proposals[index].state == .staged {
            if let reason = Self.missingTargetReason(for: proposals[index], in: graph) {
                proposals[index].error = reason
            }
        }
        persistSnapshot()
    }

    /// The reason a reloaded staged proposal can no longer be approved: its
    /// first diffed object (every operation but a create must resolve
    /// against the live graph) is gone from the home. Names the object the
    /// way execution's error record does.
    static func missingTargetReason(for proposal: Proposal, in graph: HomeGraph) -> String? {
        for entry in proposal.entries {
            guard entry.op != .create, !entry.object.id.isEmpty else { continue }
            guard !Self.exists(entry.object, in: graph) else { continue }
            let name = entry.object.name ?? entry.object.id
            return "\(entry.object.kind.rawValue.capitalized) “\(name)” no longer exists in the home — approving this change would fail."
        }
        return nil
    }

    private static func exists(_ object: ProposalObjectRef, in graph: HomeGraph) -> Bool {
        let home = graph.homes.first
        switch object.kind {
        case .room: return home?.rooms.contains { $0.id == object.id } ?? false
        case .zone: return home?.zones.contains { $0.id == object.id } ?? false
        case .scene: return home?.scenes.contains { $0.id == object.id } ?? false
        case .serviceGroup: return home?.serviceGroups.contains { $0.id == object.id } ?? false
        case .accessory: return home?.rooms.contains { $0.accessories.contains { $0.id == object.id } } ?? false
        case .trigger: return home?.triggers.contains { $0.id == object.id } ?? false
        }
    }

    /// The staged proposals the load-time sweep expired, for the app layer
    /// to record as activity; taken once.
    public func takeProposalsExpiredAtLoad() -> [Proposal] {
        defer { expiredAtLoad = [] }
        return expiredAtLoad
    }

    /// Rewrites the persisted state after a mutation batch. Write failures
    /// are logged by the file, never thrown — the in-memory store stays
    /// authoritative for the session.
    private func persistSnapshot() {
        guard let persistence else { return }
        persistence.persist(ProposalPersistedState(
            proposals: proposals,
            operations: operations,
            revertPlans: revertPlans
        ))
    }

    /// `prop_` + 12 hex characters, e.g. `prop_8f2a01b3c4d5`.
    static func newId() -> String {
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "prop_\(hex.prefix(12))"
    }
}
