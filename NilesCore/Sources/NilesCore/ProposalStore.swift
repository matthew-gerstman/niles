import Foundation
import MCP

/// Errors raised along the proposal pipeline. Every case is reportable to the
/// agent in-band; validation failures carry per-action details.
public enum ProposalStoreError: Error, Equatable, Sendable {
    case unknownTool(String)
    case invalidArguments(String)
    case validationFailed([String])
    case proposalNotFound(String)
    case proposalNotPending(id: String, state: ProposalState)
    case homeReadFailed(String)
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
    public typealias PlanFunction = @Sendable (String, [String: MCP.Value]?, HomeGraph) throws -> Plan

    /// The writing service this store executes approved operations against —
    /// also the read surface for in-band tools, so one service is the single
    /// authority for what the graph looks like before and after approval.
    public let homeKit: any HomeKitWriting
    private let planWith: PlanFunction
    private let now: @Sendable () -> Date
    private let lifetime: TimeInterval

    /// Oldest first; `proposals()` renders newest first, like the mockup queue.
    private var proposals: [Proposal] = []
    /// The operations behind each staged proposal — the execution detail the
    /// envelope intentionally omits. Cleared once terminal.
    private var operations: [String: [HomeKitOperation]] = [:]

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
        lifetime: TimeInterval = 24 * 60 * 60
    ) {
        self.homeKit = homeKit
        self.planWith = planWith
        self.now = now
        self.lifetime = lifetime
    }

    // MARK: - Staging

    /// Plans and stores one proposal for a write-tool call. Invalid requests
    /// throw before a proposal exists — the human never sees them.
    public func stage(tool: String, arguments: [String: MCP.Value]?) async throws -> Proposal {
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
        expireSweep()
        if let pending = pendingMatch(of: plan) { return pending }

        let timestamp = now()
        let proposal = Proposal(
            id: Self.newId(),
            tool: plan.tool,
            title: plan.title,
            summary: plan.summary,
            isDestructive: plan.isDestructive,
            entries: plan.entries,
            card: plan.card,
            validation: plan.validation,
            createdAt: timestamp,
            expiresAt: timestamp.addingTimeInterval(lifetime)
        )
        proposals.append(proposal)
        operations[proposal.id] = plan.operations
        return proposal
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
    public func approve(id: String) async throws -> Proposal {
        try await decide(id: id, to: .approved) { [homeKit] proposal, operations in
            var updated = proposal
            // perform returns the created object's id per operation. Threading
            // those ids into evidence collection matches created rooms,
            // scenes, groups, and triggers by id — name matching is only the
            // fallback — so a same-named pre-existing object cannot
            // false-confirm a creation.
            var createdIds = [String?](repeating: nil, count: operations.count)
            do {
                for (index, operation) in operations.enumerated() {
                    createdIds[index] = try await homeKit.perform(operation)
                }
                let fresh = try await homeKit.snapshot()
                updated.evidence = ProposalEvidenceCollector.collect(
                    operations: operations, createdIds: createdIds, graph: fresh
                )
                updated.state = .executed
            } catch {
                // The HomeKit failure is recorded verbatim; evidence from
                // whatever did apply is still read back so the human and the
                // agent see the same story. If even the read-back fails, the
                // error line stands alone — and empty evidence is itself the
                // honest observation.
                if let fresh = try? await homeKit.snapshot() {
                    updated.evidence = ProposalEvidenceCollector.collect(
                        operations: operations, createdIds: createdIds, graph: fresh
                    )
                }
                updated.error = String(describing: error)
                updated.state = .failed
            }
            return updated
        }
    }

    /// Denies a staged proposal. Nothing ever executes — matching the
    /// HomeKitSync rule the spec adopts — and denial is terminal.
    @discardableResult
    public func deny(id: String) async throws -> Proposal {
        try await decide(id: id, to: .denied) { proposal, _ in proposal }
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
        return updated
    }

    /// Marks every staged proposal past its TTL as `.expired` (a legal
    /// `staged -> expired` transition) and drops its operations.
    private func expireSweep() {
        let current = now()
        for index in proposals.indices
        where proposals[index].state == .staged && proposals[index].expiresAt <= current {
            proposals[index].state = .expired
            operations[proposals[index].id] = nil
        }
    }

    private func pendingMatch(of plan: Plan) -> Proposal? {
        proposals.first { pending in
            pending.state == .staged
                && pending.tool == plan.tool
                && operations[pending.id] == plan.operations
        }
    }

    /// `prop_` + 12 hex characters, e.g. `prop_8f2a01b3c4d5`.
    static func newId() -> String {
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "prop_\(hex.prefix(12))"
    }
}
