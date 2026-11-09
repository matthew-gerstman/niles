import Foundation
import MCP
import NilesCore
import Testing
@testable import Niles

private struct QueueTestTimeout: Error {}

/// Waits (on the main actor) until `condition` holds or the timeout expires.
@MainActor
private func waitUntil(
    timeout: TimeInterval = 5,
    _ condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { throw QueueTestTimeout() }
        try await Task.sleep(for: .milliseconds(50))
    }
}

/// Queue view-model acceptance (PR3): the undo affordance rules, the
/// optimistic Approve-all batch feedback, and the typed conflict-error
/// rendering for a diverged home. The live tests drive the real pipeline
/// over the fake home, exactly as the Queue screen does.
@MainActor
struct QueueViewModelTests {

    private func isolatedActivityLog() -> ActivityLog {
        ActivityLog(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("niles-activity-\(UUID().uuidString)", isDirectory: true))
    }

    private func makeStore(_ fake: FakeHomeKitService) -> (LiveNilesStore, ServerCoordinator) {
        let coordinator = ServerCoordinator(
            tokenStore: StaticTokenStore(token: "test-token"),
            homeKitService: fake
        )
        let store = LiveNilesStore(
            coordinator: coordinator,
            notifier: .disabled,
            activityLog: isolatedActivityLog()
        )
        return (store, coordinator)
    }

    /// Stages through the same registry the transport serves and returns the
    /// staged proposal id.
    private func stage(
        _ store: LiveNilesStore,
        _ coordinator: ServerCoordinator,
        _ name: String,
        _ arguments: [String: MCP.Value]
    ) async -> String? {
        guard let proposalStore = coordinator.proposalStore else { return nil }
        let response = await WriteToolRegistry(store: proposalStore).call(name: name, arguments: arguments)
        if response.isError == true { return nil }
        await store.refresh()
        return store.pendingProposals.first { $0.tool == name }?.id
    }

    // MARK: - Undo availability (pure derivation)

    private func proposal(
        id: String,
        tool: String = "create_room",
        state: ProposalState = .staged,
        reverts: String? = nil
    ) -> NilesProposal {
        NilesProposal(
            id: id,
            tool: tool,
            title: id,
            agentName: "Test",
            createdAt: .distantPast,
            isDestructive: false,
            evidence: [],
            diff: [ProposalDiffLine(.add, "+ \(id)")],
            context: [],
            state: state,
            revertsProposalId: reverts
        )
    }

    @Test
    func undoAvailabilityFollowsTheProposalStates() {
        let executed = proposal(id: "a", state: .executed)
        let staged = proposal(id: "b", state: .staged)
        let denied = proposal(id: "c", state: .denied)

        // Only executed rows offer Undo.
        #expect(LiveNilesStore.undoAvailable(for: executed, proposals: [executed, staged, denied]))
        #expect(!LiveNilesStore.undoAvailable(for: staged, proposals: [executed, staged, denied]))
        #expect(!LiveNilesStore.undoAvailable(for: denied, proposals: [executed, staged, denied]))
    }

    @Test
    func alreadyUndoneRowsOfferNoUndoButFailedRevertsStillDo() {
        let original = proposal(id: "a", state: .executed)
        // The revert executed: the original is undone — there is no undo of an undo.
        let appliedRevert = proposal(id: "r", state: .executed, reverts: "a")
        #expect(!LiveNilesStore.undoAvailable(for: original, proposals: [original, appliedRevert]))

        // The revert failed: the store keeps the original's revert plan, so Undo retries.
        let failedRevert = proposal(id: "f", state: .failed, reverts: "a")
        #expect(LiveNilesStore.undoAvailable(for: original, proposals: [original, failedRevert]))
    }

    @Test
    func unrevertableOperationsNeverOfferUndo() {
        // RevertPlanBuilder's unrevertable set: scene execution, identify,
        // unblock, accessory removal — no paired revert, no Undo affordance.
        for tool in ["execute_scene", "identify_accessory", "unblock_accessory", "remove_accessory"] {
            let executed = proposal(id: "a", tool: tool, state: .executed)
            #expect(!LiveNilesStore.undoAvailable(for: executed, proposals: [executed]))
        }
    }

    // MARK: - Live pipeline behavior

    @Test
    func executedRowOffersUndoAndTheTapRevertsImmediately() async throws {
        let fake = FakeHomeKitService(graph: .demoFixture)
        let (store, coordinator) = makeStore(fake)
        guard let id = await stage(store, coordinator, "create_room", ["homeId": .string("home-1"), "name": .string("Studio")]) else {
            Issue.record("Failed to stage create_room")
            return
        }

        // Staged rows decide — they never offer Undo.
        #expect(store.undoStates[id] == nil)

        await store.approveAndWait(id)
        try await waitUntil { store.proposals.first { $0.id == id }?.state == .executed }

        // The executed row offers Undo.
        #expect(store.undoStates[id] == .idle)

        // The tap path: the Undoing… state is visible synchronously, before
        // the revert's pipeline round-trip settles.
        store.undo(id)
        #expect(store.undoStates[id] == .inFlight)

        try await waitUntil {
            store.proposals.first { $0.revertsProposalId == id }?.state == .executed
        }
        // The revert applied: the room is gone and the original no longer
        // offers Undo (no undo of an undo).
        #expect(try await fake.snapshot().homes[0].rooms.contains { $0.name == "Studio" } == false)
        #expect(store.undoStates[id] == nil)
        let revert = try #require(store.proposals.first { $0.revertsProposalId == id })
        let allConfirmed = revert.evidence.allSatisfy(\.confirmed)
        #expect(allConfirmed)
    }

    @Test
    func conflictedUndoSurfacesTheTypedDivergencesInlineAndChangesNothing() async throws {
        let fake = FakeHomeKitService(graph: .demoFixture)
        let (store, coordinator) = makeStore(fake)
        guard let id = await stage(store, coordinator, "create_room", ["homeId": .string("home-1"), "name": .string("Studio")]) else {
            Issue.record("Failed to stage create_room")
            return
        }
        await store.approveAndWait(id)
        try await waitUntil { store.proposals.first { $0.id == id }?.state == .executed }

        // Diverge the home out-of-band: the revert expects the created room
        // to still exist, so removing it is exactly what the conflict check
        // exists to catch.
        let graph = try await fake.snapshot()
        let room = try #require(graph.homes[0].rooms.first { $0.name == "Studio" })
        _ = try await fake.perform(.removeRoom(homeId: graph.homes[0].id, roomId: room.id))

        // The Undo tap (awaited directly — undoAndWait is the shared path).
        await store.undoAndWait(id)

        // The typed error lands on the row: divergences named, nothing
        // applied, the original still executed.
        guard case .conflict(let divergences)? = store.undoStates[id] else {
            Issue.record("Expected a conflict state on the row after a diverged undo")
            return
        }
        #expect(divergences.isEmpty == false)
        #expect(divergences.allSatisfy { $0.confirmed == false })
        #expect(store.proposals.first { $0.id == id }?.state == .executed)
        #expect(try await fake.snapshot().homes[0].rooms.contains { $0.name == "Studio" } == false)
        // No revert proposal was staged for the refused undo.
        #expect(store.proposals.first { $0.revertsProposalId == id } == nil)
    }

    @Test
    func doubleUndoIsRefusedAndLeavesTheHomeUntouched() async throws {
        let fake = FakeHomeKitService(graph: .demoFixture)
        let (store, coordinator) = makeStore(fake)
        guard let id = await stage(store, coordinator, "create_room", ["homeId": .string("home-1"), "name": .string("Studio")]) else {
            Issue.record("Failed to stage create_room")
            return
        }
        await store.approveAndWait(id)
        try await waitUntil { store.proposals.first { $0.id == id }?.state == .executed }

        await store.undoAndWait(id)
        try await waitUntil {
            store.proposals.first { $0.revertsProposalId == id }?.state == .executed
        }
        // The second attempt hits the store's no-undo-of-an-undo guard; the
        // row stays non-undoable and the room stays removed.
        await store.undoAndWait(id)
        #expect(store.undoStates[id] == nil)
        #expect(try await fake.snapshot().homes[0].rooms.contains { $0.name == "Studio" } == false)
        #expect(store.proposals.filter { $0.revertsProposalId == id }.count == 1)
    }

    // MARK: - Approve-all batch states

    @Test
    func approveAllShowsBatchFeedbackAndSettlesEveryStagedRow() async throws {
        let fake = FakeHomeKitService(graph: .demoFixture)
        let (store, coordinator) = makeStore(fake)
        guard let first = await stage(store, coordinator, "create_room", ["homeId": .string("home-1"), "name": .string("Studio")]) else {
            Issue.record("Failed to stage create_room")
            return
        }
        guard let second = await stage(store, coordinator, "rename_room", ["roomId": .string("room-2"), "name": .string("Cookery")]) else {
            Issue.record("Failed to stage rename_room")
            return
        }
        #expect(store.pendingProposals.count == 2)

        // The tap path: batch feedback is visible synchronously — every
        // staged row shows its approving chip and the button locks.
        store.approveAll()
        #expect(store.isApprovingAll)
        #expect(store.decisionsInFlight[first] == .approving)
        #expect(store.decisionsInFlight[second] == .approving)

        try await waitUntil {
            !store.isApprovingAll
                && store.decisionsInFlight.isEmpty
                && store.proposals.allSatisfy { $0.state == .executed }
        }
        #expect(store.pendingProposals.isEmpty)
        let graph = try await fake.snapshot()
        #expect(graph.homes[0].rooms.contains { $0.name == "Studio" })
        #expect(graph.homes[0].rooms.first { $0.id == "room-2" }?.name == "Cookery")

        // Undo afterwards is per-item: both executed rows now offer Undo
        // independently.
        #expect(store.undoStates[first] == .idle)
        #expect(store.undoStates[second] == .idle)
    }

    @Test
    func approveAllWithNothingStagedIsANoOp() async throws {
        let (store, _) = makeStore(FakeHomeKitService(graph: .demoFixture))
        await store.refresh()
        store.approveAll()
        #expect(store.isApprovingAll == false)
        #expect(store.pendingProposals.isEmpty)
    }
}
