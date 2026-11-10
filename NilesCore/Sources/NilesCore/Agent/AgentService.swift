import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Cumulative session usage across the agent's requests — the numbers the
/// Settings status surface shows (spec art_VrC0iUUA §Availability gate).
public struct AgentSessionUsage: Equatable, Sendable {
    public var requestCount: Int
    public var toolCallCount: Int
    /// Proposal ids the most recent request staged — a read-only run
    /// replaces the list with an empty one rather than accumulating.
    public var lastStagedProposalIds: [String]
    public var lastRunAt: Date?

    public init(
        requestCount: Int = 0,
        toolCallCount: Int = 0,
        lastStagedProposalIds: [String] = [],
        lastRunAt: Date? = nil
    ) {
        self.requestCount = requestCount
        self.toolCallCount = toolCallCount
        self.lastStagedProposalIds = lastStagedProposalIds
        self.lastRunAt = lastRunAt
    }
}

/// What one agent request produced, flattened for iOS 17-safe callers
/// (`NilesAgent.Outcome` lives inside an iOS 27-only type).
public struct AgentRunResult: Equatable, Sendable {
    public var summary: String
    public var stagedProposalIds: [String]

    public init(summary: String, stagedProposalIds: [String]) {
        self.summary = summary
        self.stagedProposalIds = stagedProposalIds
    }
}

/// The seam iOS 17 app code holds the agent through. `AgentService` is
/// iOS 27-only; app-layer stored properties reference this protocol so the
/// gate — not the type system — decides whether a runner exists.
public protocol AgentRunning: Sendable {
    var usage: AgentSessionUsage { get async }
    /// One natural-language request to completion. Throws only when the
    /// session itself fails; every tool-level failure is in-band in the
    /// result's summary (the registries never throw).
    func run(_ request: String) async throws -> AgentRunResult
}

#if canImport(FoundationModels)
/// The app-facing composition over the agent core: one `NilesAgent` per
/// request (which means one `LanguageModelSession` per request), built over
/// the live proposal store — reads snapshot the same HomeGraph the MCP
/// server reads, writes stage into the same store MCP clients stage into.
/// The Siri intent and the future in-app composer hand their string here
/// and nothing else (spec art_VrC0iUUA §Agent runner).
@available(iOS 27.0, *)
public actor AgentService: AgentRunning {

    public private(set) var usage = AgentSessionUsage()

    private let store: ProposalStore

    public init(store: ProposalStore) {
        self.store = store
    }

    public func run(_ request: String) async throws -> AgentRunResult {
        try await run(request, using: SystemLanguageModel())
    }

    /// The test seam, same shape as `NilesAgent.run(_:using:)`: scripted
    /// models drive the production path end to end with no on-device model.
    public func run(_ request: String, using model: any LanguageModel) async throws -> AgentRunResult {
        // A fresh dispatcher per request: the 12-call budget and the
        // staged-id log are per-request by construction, never leaked from
        // the previous session.
        let dispatcher = NilesToolDispatcher(
            reads: ReadToolRegistry(service: store.homeKit),
            writes: WriteToolRegistry(store: store)
        )
        let outcome = try await NilesAgent(dispatcher: dispatcher).run(request, using: model)
        let calls = await dispatcher.attemptedCalls

        usage = AgentSessionUsage(
            requestCount: usage.requestCount + 1,
            toolCallCount: usage.toolCallCount + calls.count,
            lastStagedProposalIds: outcome.stagedProposalIds,
            lastRunAt: Date()
        )
        return AgentRunResult(summary: outcome.summary, stagedProposalIds: outcome.stagedProposalIds)
    }
}
#endif
