import Foundation
import Testing
@testable import NilesCore

/// The Undo tap IS the approval: an executed proposal's paired revert
/// stages as a new forward-only proposal and executes immediately, linked
/// through `revertsProposalId` (the 2026-11-13 "undo does nothing" report).
/// Guards the submission path end to end over `FakeHomeKitService` — no
/// `HMHomeManager`, following the PR #15 validation-test pattern.
@Suite struct UndoSubmissionTests {

    private func makeStore() -> (fake: FakeHomeKitService, store: ProposalStore) {
        let fake = FakeHomeKitService(graph: HomeGraph(homes: [
            HomeGraph.Home(id: "home-1", name: "Townhouse")
        ]))
        return (fake, ProposalStore(homeKit: fake))
    }

    /// Stages (not approves) the same plan the `-UISeedQueue undo` fixture
    /// uses: a create_room over the empty demo home.
    private func stageAddStudio(_ store: ProposalStore) async -> Proposal {
        await store.stage(plan: Plan(
            tool: "create_room",
            title: "Create room Studio",
            summary: "Adds the Studio room.",
            isDestructive: false,
            operations: [.addRoom(homeId: "home-1", name: "Studio")],
            entries: [.init(
                object: .init(kind: .room, id: "", name: "Studio"),
                op: .create, before: nil, after: "Studio"
            )],
            card: [.init(.add, "Add room Studio")]
        ))
    }

    @Test func undoSubmitsAndExecutesThePairedRevert() async throws {
        let (fake, store) = makeStore()
        let original = try await store.approve(id: await stageAddStudio(store).id)
        #expect(original.state == .executed)

        let revert = try await store.undo(proposalId: original.id)

        // The revert is a real, executed proposal linked back to the original.
        #expect(revert.state == .executed)
        #expect(revert.revertsProposalId == original.id)
        #expect(revert.title.hasPrefix("Undo — "))

        // The revert applied: the room the original added is gone again.
        let graph = try await fake.snapshot()
        #expect(graph.homes.first?.rooms.contains { $0.name == "Studio" } == false)

        // No undo of an undo: the spent plan refuses with a typed cause.
        await #expect(throws: ProposalStoreError.self) {
            try await store.undo(proposalId: original.id)
        }
    }

    @Test func undoRefusesWithTypedConflictWhenTheHomeDiverged() async throws {
        let (fake, store) = makeStore()
        let original = try await store.approve(id: await stageAddStudio(store).id)
        #expect(original.state == .executed)

        // The room vanished outside Niles: the recorded post-state moved, so
        // the conflict check must refuse and apply nothing.
        var diverged = try await fake.snapshot()
        diverged.homes[0].rooms.removeAll { $0.name == "Studio" }
        await fake.setGraph(diverged)

        await #expect(throws: ProposalStoreError.self) {
            try await store.undo(proposalId: original.id)
        }

        // Nothing was applied: the divergence stands.
        let graph = try await fake.snapshot()
        #expect(graph.homes.first?.rooms.contains { $0.name == "Studio" } == false)
    }
}
