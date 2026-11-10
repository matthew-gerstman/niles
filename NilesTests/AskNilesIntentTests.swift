import Foundation
import MCP
import NilesCore
import Testing
@testable import Niles

/// The Siri entry point's routing core: the prompt reaches the agent runner
/// untouched, the outcome surfaces as the dialog, an unavailable or failing
/// session is reported honestly — and nothing on this path can approve or
/// execute. None of it needs the App Intents runtime.
/// The `AgentRunning` fakes live in `AgentRunnerFakes.swift`, shared with
/// the chat view-model suite.
@MainActor
struct AskNilesIntentTests {

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
