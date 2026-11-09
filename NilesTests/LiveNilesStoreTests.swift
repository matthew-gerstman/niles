import Foundation
import MCP
import NilesCore
import Testing
import UIKit
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

    /// Regression for the device-QA latency finding: the tap path must give
    /// visible feedback synchronously — before the pipeline round-trip
    /// settles — and reconcile with the settled result.
    @Test
    func approveTapShowsOptimisticFeedbackBeforePipelineSettles() async throws {
        let fake = FakeHomeKitService(graph: .demoFixture)
        let coordinator = ServerCoordinator(tokenStore: StaticTokenStore(token: "test-token"), homeKitService: fake)
        let store = LiveNilesStore(coordinator: coordinator, notifier: .disabled)
        await store.refresh()
        let registry = WriteToolRegistry(store: try #require(coordinator.proposalStore))
        _ = await registry.call(
            name: "create_room",
            arguments: ["homeId": .string("home-1"), "name": .string("Studio")]
        )
        await store.refresh()
        let pending = try #require(store.pendingProposals.first)

        // The tap path: no await. The in-progress chip must be visible now.
        store.approve(pending.id)
        #expect(store.decisionsInFlight[pending.id] == .approving)

        // Reconciliation: the marker clears once the pipeline settles and
        // the refreshed state is authoritative.
        try await waitUntil { store.decisionsInFlight.isEmpty }
        let settled = try #require(store.proposals.first { $0.id == pending.id })
        #expect(settled.state == .executed)
        #expect(store.pendingProposals.isEmpty)
    }

    /// Double-tap idempotency on the tap path: a second tap while the first
    /// round-trip is still in flight must not execute the operations twice —
    /// the pipeline's terminal-state guard rejects the re-approve.
    @Test
    func doubleTapApproveExecutesOperationsOnce() async throws {
        let fake = FakeHomeKitService(graph: .demoFixture)
        let coordinator = ServerCoordinator(tokenStore: StaticTokenStore(token: "test-token"), homeKitService: fake)
        let store = LiveNilesStore(coordinator: coordinator, notifier: .disabled)
        await store.refresh()
        let registry = WriteToolRegistry(store: try #require(coordinator.proposalStore))
        _ = await registry.call(
            name: "create_room",
            arguments: ["homeId": .string("home-1"), "name": .string("Studio")]
        )
        await store.refresh()
        let pending = try #require(store.pendingProposals.first)

        // Two taps in quick succession, as on a card that looked dead.
        store.approve(pending.id)
        store.approve(pending.id)

        try await waitUntil {
            store.decisionsInFlight.isEmpty
                && store.proposals.first { $0.id == pending.id }?.state == .executed
        }
        let after = try await fake.snapshot()
        #expect(after.homes[0].rooms.filter { $0.name == "Studio" }.count == 1)
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

    /// Regression for device QA F3: the full live-store path for the
    /// zone-membership write — stage `create_zone` + `set_zone_rooms`
    /// through the write registry the transport serves, approve through the
    /// store the Approvals screen renders, and assert the membership via an
    /// authenticated read tool (`get_zones`), not by construction.
    @Test
    func stagedZoneMembershipAppliesAndReadsBackThroughGetZones() async throws {
        let fake = FakeHomeKitService(graph: .demoFixture)
        let coordinator = ServerCoordinator(tokenStore: StaticTokenStore(token: "test-token"), homeKitService: fake)
        let store = LiveNilesStore(coordinator: coordinator, notifier: .disabled)
        await store.refresh()
        let writes = WriteToolRegistry(store: try #require(coordinator.proposalStore))
        let reads = ReadToolRegistry(service: fake)

        // The device-QA shape: a disposable zone, then a room moved into it.
        _ = await writes.call(
            name: "create_zone",
            arguments: ["homeId": .string("home-1"), "name": .string("QA Zone")]
        )
        await store.refresh()
        let create = store.pendingProposals.first { $0.tool == "create_zone" }
        try #require(create != nil)
        await store.approveAndWait(create!.id)
        try await waitUntil { store.proposals.first(where: { $0.id == create!.id })?.state == .executed }

        // The zone's id comes from a read-back, the same surface an
        // authenticated agent sees.
        let zonesAfterCreate = await reads.call(name: "get_zones")
        let createdZoneId = try Self.zoneId(named: "QA Zone", in: zonesAfterCreate)

        _ = await writes.call(
            name: "set_zone_rooms",
            arguments: ["zoneId": .string(createdZoneId), "roomIds": .array([.string("room-3")])]
        )
        await store.refresh()
        let move = store.pendingProposals.first { $0.tool == "set_zone_rooms" }
        try #require(move != nil)
        await store.approveAndWait(move!.id)
        try await waitUntil { store.proposals.first(where: { $0.id == move!.id })?.state == .executed }

        // Authenticated read-back: the zone now contains Office, and the
        // read-back evidence agrees.
        let zonesAfterMove = await reads.call(name: "get_zones")
        #expect(zonesAfterMove.isError != true)
        let office = try Self.roomRefs(named: "Office", in: zonesAfterMove)
        #expect(office.count == 1)
        #expect(office[0].id == "room-3")

        let executed = store.proposals.first { $0.id == move!.id }
        #expect(executed?.evidence.first?.confirmed == true)
        #expect(executed?.evidence.first?.observed.contains("QA Zone") == true)
    }

    /// Decodes a `get_zones` result and returns the id of the named zone.
    private static func zoneId(named name: String, in result: CallTool.Result, sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        let zones = try Self.zones(from: result, sourceLocation: sourceLocation)
        return try #require(zones.first(where: { $0.name == name })?.id, sourceLocation: sourceLocation)
    }

    /// Decodes a `get_zones` result and returns the rooms of the named zone.
    private static func roomRefs(named name: String, in result: CallTool.Result, sourceLocation: SourceLocation = #_sourceLocation) throws -> [RoomReadBack] {
        let zones = try Self.zones(from: result, sourceLocation: sourceLocation)
        return try #require(zones.first(where: { $0.name == name })?.rooms, sourceLocation: sourceLocation)
    }

    private static func zones(from result: CallTool.Result, sourceLocation: SourceLocation = #_sourceLocation) throws -> [ZoneReadBack] {
        #expect(result.isError != true, sourceLocation: sourceLocation)
        let value = try #require(result.structuredContent, sourceLocation: sourceLocation)
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(ZonesReadBack.self, from: data).zones
    }

    /// Local decoding of the `get_zones` projection — the projection types
    /// are internal to NilesCore, so the app target decodes its own shape.
    private struct ZonesReadBack: Codable { var zones: [ZoneReadBack] }
    private struct ZoneReadBack: Codable {
        var id: String
        var name: String
        var rooms: [RoomReadBack]
    }
    private struct RoomReadBack: Codable {
        var id: String
        var name: String
    }

    @Test
    func pairingTokenComesFromTheTokenStore() async throws {
        let coordinator = ServerCoordinator(tokenStore: StaticTokenStore(token: "pairing-token"), homeKitService: FakeHomeKitService())
        let store = LiveNilesStore(coordinator: coordinator, notifier: .disabled, tokenStore: StaticTokenStore(token: "pairing-token"))
        await store.loadTokenAndWait()
        #expect(store.token == "pairing-token")
        #expect(store.tokenError == nil)
    }

    /// The screen keep-awake binding, driven through the same scene-phase
    /// handoff and kill switch the app uses: serving foregrounded disables
    /// the idle timer; the kill switch or backgrounding re-enables it.
    @Test
    func servingKeepsScreenAwakeAndStoppingRestoresAutoLock() async throws {
        let coordinator = ServerCoordinator(tokenStore: StaticTokenStore(token: "test-token"), homeKitService: FakeHomeKitService())
        let store = LiveNilesStore(coordinator: coordinator, notifier: .disabled)
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        await store.handleScene(isActive: true)
        try await waitUntil { UIApplication.shared.isIdleTimerDisabled }

        // Kill switch off: the server stops and auto-lock returns.
        store.setServerRunning(false)
        try await waitUntil { !UIApplication.shared.isIdleTimerDisabled }

        // Kill switch back on: serving again, screen stays awake.
        store.setServerRunning(true)
        try await waitUntil { UIApplication.shared.isIdleTimerDisabled }

        // Backgrounding: the server stops and auto-lock returns.
        await store.handleScene(isActive: false)
        try await waitUntil { !UIApplication.shared.isIdleTimerDisabled && !store.serverIsRunning }
    }
}
