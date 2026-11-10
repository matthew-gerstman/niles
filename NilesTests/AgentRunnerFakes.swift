import Foundation
import NilesCore

/// Shared fakes of `AgentRunning` for app-target tests — the Siri routing
/// suite and the chat view-model suite drive the same seams.

/// Records the routed prompt and returns a canned result.
actor ScriptedRunner: AgentRunning {
    let result: AgentRunResult
    private(set) var lastPrompt: String?
    private(set) var runCount = 0

    init(result: AgentRunResult) { self.result = result }

    var usage: AgentSessionUsage { AgentSessionUsage() }

    func run(_ request: String) async throws -> AgentRunResult {
        lastPrompt = request
        runCount += 1
        return result
    }
}

/// A runner whose session fails — the surface must carry the error, never
/// swallow it.
actor ThrowingRunner: AgentRunning {
    struct SessionFailure: Error {}

    var usage: AgentSessionUsage { AgentSessionUsage() }
    func run(_ request: String) async throws -> AgentRunResult { throw SessionFailure() }
}

/// Holds every run open until the test releases it, so tests can observe
/// the in-flight window (composer state, ignored concurrent sends)
/// deterministically instead of racing two sends against each other.
actor PausingRunner: AgentRunning {
    private var pending: [CheckedContinuation<Void, Never>] = []
    private(set) var startedCount = 0

    var usage: AgentSessionUsage { AgentSessionUsage() }

    func run(_ request: String) async throws -> AgentRunResult {
        startedCount += 1
        await withCheckedContinuation { pending.append($0) }
        return AgentRunResult(
            summary: "Staged 1 proposal for review in Niles.",
            stagedProposalIds: ["prop-paused"]
        )
    }

    /// Settles once `count` runs have been entered — deterministic because
    /// the send path enters `run` synchronously before its first await.
    func waitUntilStarted(count: Int) async {
        while startedCount < count {
            await Task.yield()
        }
    }

    func release() {
        pending.forEach { $0.resume() }
        pending.removeAll()
    }
}

/// Stages one write exactly the way the agent's write tools do — through
/// `ProposalStore.stage`, the only write path this layer can reach.
actor StagingRunner: AgentRunning {
    let store: ProposalStore
    init(store: ProposalStore) { self.store = store }

    var usage: AgentSessionUsage { AgentSessionUsage() }
    func run(_ request: String) async throws -> AgentRunResult {
        let proposal = try await store.stage(
            tool: "create",
            arguments: [
                "kind": .string("scene"),
                "homeId": .string("home-1"),
                "name": .string("Movie Time"),
                "actions": .array([.object([
                    "accessoryId": .string("acc-1"),
                    "characteristic": .string("Brightness"),
                    "value": .int(30),
                ])]),
            ]
        )
        return AgentRunResult(
            summary: "Staged 1 proposal: \(proposal.title).",
            stagedProposalIds: [proposal.id]
        )
    }
}
