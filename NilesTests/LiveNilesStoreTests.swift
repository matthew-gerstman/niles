import Foundation
import MCP
import NilesCore
import Testing
@testable import Niles

/// Convenience token source for tests — the real app uses the Keychain.
struct StaticTokenStore: TokenStoring {
    let token: String
    func loadOrCreate() throws -> String { token }
}

private struct Timeout: Error {}

/// Waits (on the main actor) until `condition` holds or the timeout expires.
@MainActor
private func waitUntil(
    timeout: TimeInterval = 5,
    _ condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { throw Timeout() }
        try await Task.sleep(for: .milliseconds(50))
    }
}

/// End-to-end acceptance for the live wiring: an agent's write-tool call
/// stages a proposal onto the live `ProposalStore`, it appears in the store
/// the Approvals screen renders, and approving it executes the pipeline path
/// against the fake home — with read-back evidence attached.
@MainActor
struct LiveNilesStoreTests {

    @Test
    func stagedProposalAppearsAndApprovalAppliesToFakeHome() async throws {
        let fake = FakeHomeKitService(graph: .demoFixture)
        let coordinator = ServerCoordinator(tokenStore: StaticTokenStore(token: "test-token"), homeKitService: fake)
        let store = LiveNilesStore(coordinator: coordinator, notifier: .disabled)
        await store.refresh()
        #expect(store.pendingProposals.isEmpty)

        // Simulate the agent: stage through the same registry the transport serves.
        let registry = WriteToolRegistry(store: try #require(coordinator.proposalStore))
        let response = await registry.call(
            name: "create_room",
            arguments: ["homeId": .string("home-1"), "name": .string("Studio")]
        )
        #expect(response.isError != true)

        // The staged proposal appears in the store the Approvals screen renders.
        await store.refresh()
        #expect(store.pendingProposals.count == 1)
        let pending = store.pendingProposals[0]
        #expect(pending.tool == "create_room")
        #expect(pending.state == .staged)

        // Nothing has touched the fake home yet.
        let before = try await fake.snapshot()
        #expect(!before.homes[0].rooms.contains { $0.name == "Studio" })

        // Approve — the pipeline executes and records read-back evidence.
        await store.approveAndWait(pending.id)
        try await waitUntil { store.proposals.first(where: { $0.id == pending.id })?.state == .executed }

        // The fake home now contains the room — approval applied the change.
        let after = try await fake.snapshot()
        #expect(after.homes[0].rooms.contains { $0.name == "Studio" })

        // Evidence rendered on the proposal, and the Home tab reflects the graph.
        let executed = store.proposals.first { $0.id == pending.id }
        #expect(executed?.context.contains { $0.text.contains("✓") } == true)
        #expect(store.sections.first { $0.title == "Rooms" }?.rows.contains { $0.name == "Studio" } == true)
        #expect(store.approvedTodayCount == 1)
    }

    @Test
    func denialLeavesFakeHomeUntouched() async throws {
        let fake = FakeHomeKitService(graph: .demoFixture)
        let coordinator = ServerCoordinator(tokenStore: StaticTokenStore(token: "test-token"), homeKitService: fake)
        let store = LiveNilesStore(coordinator: coordinator, notifier: .disabled)
        await store.refresh()

        let registry = WriteToolRegistry(store: try #require(coordinator.proposalStore))
        let response = await registry.call(
            name: "create_room",
            arguments: ["homeId": .string("home-1"), "name": .string("Never Applied")]
        )
        #expect(response.isError != true)
        await store.refresh()
        #expect(store.pendingProposals.count == 1)

        await store.denyAndWait(store.pendingProposals[0].id)
        try await waitUntil { store.proposals.first?.state == .denied }

        let graph = try await fake.snapshot()
        #expect(!graph.homes[0].rooms.contains { $0.name == "Never Applied" })
        #expect(store.pendingProposals.isEmpty)
    }

    @Test
    func pairingTokenComesFromTheTokenStore() async throws {
        let coordinator = ServerCoordinator(tokenStore: StaticTokenStore(token: "pairing-token"), homeKitService: FakeHomeKitService())
        let store = LiveNilesStore(coordinator: coordinator, notifier: .disabled, tokenStore: StaticTokenStore(token: "pairing-token"))
        await store.loadTokenAndWait()
        #expect(store.token == "pairing-token")
        #expect(store.tokenError == nil)
    }
}
