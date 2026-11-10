import Foundation
import NilesCore

/// The process-wide store. A background App Intent launches the app process
/// without foregrounding the UI, so the Siri entry point and the app's screens
/// must observe the same store — one instance, built here and handed to
/// `NilesApp` as its state.
@MainActor
enum AppEnvironment {
    static let shared: LiveNilesStore = {
        let coordinator = ServerCoordinator(homeKitService: makeHomeKitService())
        return LiveNilesStore(
            coordinator: coordinator,
            notifier: .shared,
            agentRunner: chatFixtureRunnerIfRequested(proposalStore: coordinator.proposalStore)
        )
    }()

    /// The service the pipeline stages and executes against. The simulator has
    /// no HomeKit database, so it runs the fake executor over the demo fixture;
    /// a real device reads the shared home database. (Device-side execution of
    /// staged operations is not implemented yet — approvals record an explicit
    /// failure there until the adapter's write half lands.)
    static func makeHomeKitService() -> any HomeKitWriting {
        #if targetEnvironment(simulator)
        FakeHomeKitService(graph: .demoFixture)
        #else
        DeviceHomeKitService()
        #endif
    }

    /// Simulator QA fixture (`-UIChatFixtures`, same family as
    /// `-UISeedQueue`): stands in for the Foundation Models runner so the
    /// chat flow is dogfoodable on machines without Apple Intelligence —
    /// the real gate would report the agent unavailable there. The fixture
    /// run stages a real proposal through the real `ProposalStore` (the
    /// human gate is unchanged) and reports it the way `AgentService` does.
    /// No-op without the launch argument.
    private static func chatFixtureRunnerIfRequested(
        proposalStore: ProposalStore?
    ) -> (any AgentRunning)? {
        guard ProcessInfo.processInfo.arguments.contains("-UIChatFixtures"),
              let proposalStore else { return nil }
        return ChatFixtureRunner(store: proposalStore)
    }
}

/// The `-UIChatFixtures` stand-in runner: a short hold (so the running state
/// renders — ProgressView row, disabled composer), then a stage through the
/// store's real write path with an `AgentService`-shaped result.
private struct ChatFixtureRunner: AgentRunning {
    let store: ProposalStore

    var usage: AgentSessionUsage { AgentSessionUsage() }

    func run(_ request: String) async throws -> AgentRunResult {
        try await Task.sleep(for: .seconds(2))
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
