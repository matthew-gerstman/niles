import Foundation
import NilesCore
import Testing
@testable import Niles

/// The in-app chat's transcript model and send path on the live store
/// (spec art_AL0RolQe): every send composes through `AgentRunning` exactly
/// as Siri does — one run at a time, summary verbatim, staged ids carried
/// verbatim, failures rendered as failed turns, and an unavailable gate
/// disabling the composer instead of degrading.
@MainActor
struct ChatViewModelTests {

    /// A per-test temp log — same isolation as AgentStatusTests.
    private func isolatedActivityLog() -> ActivityLog {
        ActivityLog(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("niles-activity-\(UUID().uuidString)", isDirectory: true))
    }

    private func makeStore(
        runner: (any AgentRunning)? = nil,
        availability: AgentAvailability? = nil
    ) -> LiveNilesStore {
        let coordinator = ServerCoordinator(homeKitService: FakeHomeKitService(graph: .demoFixture))
        return LiveNilesStore(
            coordinator: coordinator,
            notifier: .disabled,
            activityLog: isolatedActivityLog(),
            agentRunner: runner,
            agentAvailability: availability
        )
    }

    // MARK: - Send stages through the pipeline

    @Test
    func sendStagesThroughTheRealProposalStoreAndResolvesVerbatim() async throws {
        let coordinator = ServerCoordinator(homeKitService: FakeHomeKitService(graph: .demoFixture))
        let proposalStore = try #require(coordinator.proposalStore)
        let store = LiveNilesStore(
            coordinator: coordinator,
            notifier: .disabled,
            activityLog: isolatedActivityLog(),
            agentRunner: StagingRunner(store: proposalStore)
        )

        await store.send("create a Movie Time scene")

        // The transcript: the user row optimistically, then the agent row
        // carrying the result verbatim.
        #expect(store.entries.count == 2)
        #expect(store.entries[0].role == .user)
        #expect(store.entries[0].text == "create a Movie Time scene")
        #expect(store.entries[1].role == .agent)
        #expect(store.entries[1].state == .done)

        let proposals = await proposalStore.allProposals()
        #expect(proposals.count == 1)
        let staged = try #require(proposals.first)
        #expect(store.entries[1].text == "Staged 1 proposal: \(staged.title).")
        #expect(store.entries[1].stagedProposalIds == [staged.id])

        // Nothing on the chat path approved or executed: the proposal is
        // still waiting for the human in the Queue.
        #expect(staged.state == .staged)

        // The run settled: the composer re-enables.
        #expect(store.canSend)
    }

    // MARK: - One run at a time

    @Test
    func composerDisablesWhileRunningAndConcurrentSendsAreIgnored() async throws {
        let runner = PausingRunner()
        let store = makeStore(runner: runner)

        let first = Task { await store.send("first request") }

        // Deterministic: wait for the run to actually enter `run(_:)`, then
        // the in-flight flag is set and the composer is locked.
        await runner.waitUntilStarted(count: 1)
        #expect(!store.canSend)
        #expect(store.entries.count == 2)
        #expect(store.entries[0].role == .user)
        #expect(store.entries[0].text == "first request")
        #expect(store.entries[1].role == .agent)
        #expect(store.entries[1].state == .running)

        // A send while a run is in flight is a no-op — not a queued run.
        await store.send("second request")
        #expect(store.entries.count == 2, "one user turn and one in-flight agent turn")
        #expect(store.entries[1].state == .running)
        #expect(await runner.startedCount == 1, "the concurrent send composed no second run")

        // Settling the run re-enables the composer and resolves the turn.
        await runner.release()
        await first.value
        #expect(store.entries[1].state == .done)
        #expect(store.canSend)
    }

    // MARK: - Failure shape

    @Test
    func sessionFailureRendersAFailedTurnAndReenablesTheComposer() async throws {
        let store = makeStore(runner: ThrowingRunner())

        await store.send("make a scene")

        #expect(store.entries.count == 2)
        let agentEntry = store.entries[1]
        #expect(agentEntry.role == .agent)
        guard case .failed(let message) = agentEntry.state else {
            Issue.record("expected a failed turn, got \(agentEntry.state)")
            return
        }
        // The same copy path the Siri dialog uses — never a silent drop.
        #expect(message.contains("couldn't complete"))
        #expect(agentEntry.stagedProposalIds.isEmpty)
        // The composer re-enables after the failure.
        #expect(store.canSend)
    }

    // MARK: - Availability

    @Test
    func unavailableGateDisablesTheComposerAndIgnoresSends() async throws {
        let store = makeStore(
            availability: .unavailable(.appleIntelligenceNotEnabled)
        )

        #expect(store.agentRunner == nil)
        #expect(!store.canSend)

        await store.send("anything at all")
        #expect(store.entries.isEmpty, "a send on an unavailable gate composes nothing")
    }

    @Test
    func unavailableStateCarriesTheGateReasonVerbatimWithSettings() {
        let store = makeStore(availability: .unavailable(.needsIOS27))

        // The chat screen renders the same reason copy Settings shows —
        // one wording, already pinned per gate state in AgentStatusTests.
        #expect(
            SettingsScreen.agentFooterText(store.agentAvailability)
                == SettingsScreen.agentFooterText(.unavailable(.needsIOS27))
        )
        #expect(!SettingsScreen.agentFooterText(store.agentAvailability).isEmpty)
        #expect(!store.canSend)
    }
}
