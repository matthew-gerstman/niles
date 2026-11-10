import Foundation
import MCP
import NilesCore
import Testing
@testable import Niles

/// The Siri entry point's routing core: the prompt reaches the agent runner
/// untouched, the outcome surfaces as the dialog, an unavailable or failing
/// session is reported honestly — and nothing on this path can approve or
/// execute. None of it needs the App Intents runtime.
@MainActor
struct AskNilesIntentTests {

    /// Stands in for `AgentService`: records the routed prompt and returns a
    /// canned result.
    private actor ScriptedRunner: AgentRunning {
        let result: AgentRunResult
        private(set) var lastPrompt: String?

        init(result: AgentRunResult) { self.result = result }

        var usage: AgentSessionUsage { AgentSessionUsage() }

        func run(_ request: String) async throws -> AgentRunResult {
            lastPrompt = request
            return result
        }
    }

    /// A runner whose session fails — the dialog must carry the error, never
    /// swallow it.
    private actor ThrowingRunner: AgentRunning {
        struct SessionFailure: Error {}

        var usage: AgentSessionUsage { AgentSessionUsage() }
        func run(_ request: String) async throws -> AgentRunResult { throw SessionFailure() }
    }

    /// Stages one write exactly the way the agent's write tools do — through
    /// `ProposalStore.stage`, the only write path this layer can reach.
    private actor StagingRunner: AgentRunning {
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

    // MARK: - Routing and outcome surfacing

    @Test
    func promptRoutesToRunnerAndSummarySurfacesVerbatim() async throws {
        let runner = ScriptedRunner(result: AgentRunResult(
            summary: "Staged 1 proposal for review in Niles: \u{201C}Movie Time\u{201D}.",
            stagedProposalIds: ["prop-1"]
        ))

        let outcome = await AskNilesRouter(runner: runner).run(
            "make a scene that sets all living room lights to 30%"
        )

        #expect(await runner.lastPrompt == "make a scene that sets all living room lights to 30%")
        #expect(outcome.dialog == "Staged 1 proposal for review in Niles: \u{201C}Movie Time\u{201D}.")
        #expect(outcome.stagedProposalIds == ["prop-1"])
    }

    // MARK: - Availability and failure shapes

    @Test
    func unavailableRunnerReportsTheGateWithoutRouting() async {
        let outcome = await AskNilesRouter(runner: nil).run("anything at all")
        #expect(outcome.dialog == AskNilesRouter.unavailableOutcome.dialog)
        #expect(outcome.stagedProposalIds.isEmpty)
    }

    @Test
    func sessionFailureSurfacesInTheDialog() async {
        let outcome = await AskNilesRouter(runner: ThrowingRunner()).run("make a scene")
        #expect(outcome.dialog.contains("couldn't complete"))
        #expect(outcome.stagedProposalIds.isEmpty)
    }

    // MARK: - The human gate

    @Test
    func routedStagingLeavesProposalsAwaitingHumanApproval() async throws {
        // The real pipeline over the fake home — the same wiring a simulator
        // background run uses.
        let coordinator = ServerCoordinator(homeKitService: FakeHomeKitService(graph: .demoFixture))
        let store = try #require(coordinator.proposalStore)

        let outcome = await AskNilesRouter(runner: StagingRunner(store: store))
            .run("create a Movie Time scene")

        #expect(outcome.stagedProposalIds.count == 1)
        let proposals = await store.allProposals()
        #expect(proposals.count == 1)
        // Nothing on the routed path approved or executed: the proposal is
        // still waiting for the human in the Queue.
        #expect(proposals.allSatisfy { $0.state == .staged })
    }

    // MARK: - Queue deep link

    @Test
    func openQueueIntentRequestsTheQueueTab() async throws {
        // The bundle runs hosted in the real app, where the live ContentView
        // observes and consumes `AppNavigation.shared` — performing against
        // the shared singleton races the UI. A fresh target nothing observes
        // makes the assertion hermetic.
        let navigation = AppNavigation()
        let original = OpenQueueIntent.navigationTarget
        OpenQueueIntent.navigationTarget = navigation
        defer { OpenQueueIntent.navigationTarget = original }

        _ = try await OpenQueueIntent().perform()

        #expect(navigation.queueSelectionPending)
    }
}
