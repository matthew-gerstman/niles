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
    /// The same run, attributed to an entry point — the single-flight
    /// guard's busy error names it (spec art_rqDQF7Ic §2). Conformers that
    /// don't track attribution fall back to the unattributed run.
    func run(_ request: String, entryPoint: String) async throws -> AgentRunResult
    /// The entry point with a run in flight, if any. Surfaces that answer
    /// a submit in-band (the remote client's `agent_chat`) read this to
    /// refuse politely instead of racing the run guard.
    var activeEntryPoint: String? { get async }
}

extension AgentRunning {
    public func run(_ request: String, entryPoint: String) async throws -> AgentRunResult {
        try await run(request)
    }
    public var activeEntryPoint: String? {
        get async { nil }
    }
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

    /// The entry point whose run is in flight — the single-flight guard's
    /// error names it, and in-band refusers read it before submitting.
    public private(set) var activeEntryPoint: String?

    /// App-wide single-flight state (spec art_rqDQF7Ic §2): one run at a
    /// time across Siri, in-app chat, and remote MCP sessions, so rounds
    /// never interleave in one trace. Actor isolation makes the
    /// check-and-set atomic.
    private var runInFlight = false

    private let store: ProposalStore

    /// The per-run availability check. Production reads the live gate;
    /// tests inject a stub so recheck behavior is exercised without
    /// hardware that reports it.
    private let availability: @Sendable () -> AgentAvailability

    public init(store: ProposalStore) {
        self.store = store
        self.availability = { AgentAvailabilityGate.evaluate() }
    }

    /// The test seam: an injected availability closure stands in for the
    /// live gate.
    public init(store: ProposalStore, availability: @escaping @Sendable () -> AgentAvailability) {
        self.store = store
        self.availability = availability
    }

    public func run(_ request: String) async throws -> AgentRunResult {
        try await run(request, entryPoint: "Unattributed")
    }

    /// The single-flight entry: refuse before running when any entry point
    /// holds a run. The guard lives here — where Siri, chat, and the remote
    /// store all converge — so no surface can interleave rounds in a trace.
    public func run(_ request: String, entryPoint: String) async throws -> AgentRunResult {
        guard !runInFlight else {
            throw AgentRunError.busy(activeEntryPoint ?? "another entry point")
        }
        runInFlight = true
        activeEntryPoint = entryPoint
        defer {
            runInFlight = false
            activeEntryPoint = nil
        }
        return try await runChecked(request)
    }

    /// The run itself, unchanged by single-flight: availability recheck,
    /// trace logging, generation, run-end attribution.
    private func runChecked(_ request: String) async throws -> AgentRunResult {
        // Per-run recheck: feature entry evaluated the gate once, but the
        // on-device model's readiness changes at system level between runs
        // (settings, OS update, asset download state). Re-evaluate here —
        // once per run, never in a loop — so a stale runner refuses with
        // the typed reason instead of throwing a raw generation failure
        // (the "Resource (Local Model Asset) unavailable" report). The
        // scripted-model seam (`run(_:using:)`) stays unchecked: tests
        // drive it precisely to exercise the generation path itself.
        let availabilityState = availability()
        switch availabilityState {
        case .available:
            break
        case .unavailable(let reason):
            AgentRunTrace.logger.error(
                "Agent run refused: availability=unavailable(\(String(describing: reason), privacy: .public)) request: \(AgentRunTrace.truncated(request, to: 500), privacy: .public)"
            )
            await AgentRunTraceStore.shared.recordError(
                "Run refused — availability unavailable: \(String(describing: reason)) · request: \(AgentRunTrace.truncated(request, to: 500))"
            )
            throw AgentRunError.unavailable(reason)
        }
        // The entry point (Siri vs in-app chat) is known only by the
        // callers — they log it with the request text; this line adds the
        // per-run availability state.
        AgentRunTrace.logger.info(
            "Agent run start: availability=available request: \(AgentRunTrace.truncated(request, to: 500), privacy: .public)"
        )
        do {
            let result = try await run(request, using: SystemLanguageModel())
            AgentRunTrace.logger.info(
                "Agent run finished: summary (\(result.summary.count, privacy: .public) chars): \(AgentRunTrace.truncated(result.summary, to: 500), privacy: .public) stagedProposalIds=[\(result.stagedProposalIds.joined(separator: ","), privacy: .public)]"
            )
            await AgentRunTraceStore.shared.recordRunEnd(
                summary: "\(AgentRunTrace.truncated(result.summary, to: 500)) stagedProposalIds=[\(result.stagedProposalIds.joined(separator: ","))]"
            )
            return result
        } catch {
            // The mid-run chain itself is already logged in NilesAgent with
            // its asset probe; this line records the end result — the error
            // the caller actually receives, in its mapped form.
            AgentRunTrace.logger.error("Agent run failed: \(AgentRunTrace.reflectedErrorChain(error), privacy: .public)")
            await AgentRunTraceStore.shared.recordError(AgentRunTrace.reflectedErrorChain(error))
            throw error
        }
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
