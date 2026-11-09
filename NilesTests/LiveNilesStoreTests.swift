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
    func listAgents() throws -> [PairedAgent] {
        [PairedAgent(id: UUID(), name: nil, token: token, pairedAt: .distantPast)]
    }
    func issueToken(name: String?) throws -> PairedAgent {
        PairedAgent(id: UUID(), name: name, token: token, pairedAt: Date())
    }
    func revoke(id: UUID) throws {}
}

/// A token store with a stable, mutable agent list — what the paired-agents
/// list and revoke flow tests need (the Keychain stand-in stays stateless).
final class MutableListTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var agents: [PairedAgent]
    private(set) var revokedIDs: [UUID] = []

    init(agents: [PairedAgent]) {
        self.agents = agents
    }

    func loadOrCreate() throws -> String { agents.first?.token ?? "" }
    func listAgents() throws -> [PairedAgent] { agents }
    func issueToken(name: String?) throws -> PairedAgent {
        let agent = PairedAgent(id: UUID(), name: name, token: "issued-token", pairedAt: Date())
        agents.append(agent)
        return agent
    }
    func revoke(id: UUID) throws {
        lock.lock()
        revokedIDs.append(id)
        lock.unlock()
        agents.removeAll { $0.id == id }
    }
}

/// A controllable clock for `PairingCodeManager` — tests advance it to drive
/// expiry without sleeping.
final class MutableClock: @unchecked Sendable {
    var date: Date
    init(date: Date = Date()) { self.date = date }
    func advance(by interval: TimeInterval) { date.addTimeInterval(interval) }
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

    /// A per-test temp log: the default `ActivityLog()` binds to the app's
    /// real Application Support, whose persisted file would otherwise share
    /// history across concurrent tests and simulator relaunches.
    private func isolatedActivityLog() -> ActivityLog {
        ActivityLog(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("niles-activity-\(UUID().uuidString)", isDirectory: true))
    }

    @Test
    func stagedProposalAppearsAndApprovalAppliesToFakeHome() async throws {
        let fake = FakeHomeKitService(graph: .demoFixture)
        let coordinator = ServerCoordinator(tokenStore: StaticTokenStore(token: "test-token"), homeKitService: fake)
        let store = LiveNilesStore(coordinator: coordinator, notifier: .disabled, activityLog: isolatedActivityLog())
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

        // Evidence rides on the proposal in its structured form — per-check
        // claim/observed/confirmed, no longer glued into context strings.
        let executed = store.proposals.first { $0.id == pending.id }
        #expect(executed?.evidence.isEmpty == false)
        #expect(executed?.evidence.first?.confirmed == true)
        #expect(executed?.context.contains { $0.text.contains("✓") } == false)
        #expect(store.sections.first { $0.title == "Rooms" }?.rows.contains { $0.name == "Studio" } == true)
        #expect(store.approvedTodayCount == 1)
    }

    /// The activity timeline records a proposal's life — staged, decided,
    /// executed — with agent attribution and structured evidence on the
    /// executed event, and it survives a store re-init over the same
    /// directory (the persistence contract).
    @Test
    func activityEventsRecordStagingDecisionsAndExecution() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("niles-activity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fake = FakeHomeKitService(graph: .demoFixture)
        let coordinator = ServerCoordinator(tokenStore: StaticTokenStore(token: "test-token"), homeKitService: fake)
        let store = LiveNilesStore(
            coordinator: coordinator,
            notifier: .disabled,
            activityLog: ActivityLog(directory: directory)
        )
        await store.refresh()
        let registry = WriteToolRegistry(store: try #require(coordinator.proposalStore))
        _ = await registry.call(
            name: "create_room",
            arguments: ["homeId": .string("home-1"), "name": .string("Studio")]
        )
        await store.refresh() // the staged event
        let pending = try #require(store.pendingProposals.first)
        await store.approveAndWait(pending.id) // the decided event

        let kinds = store.activityEvents.filter { $0.proposalId == pending.id }.map(\.kind)
        #expect(kinds == [.staged, .decided, .executed])
        let executedEvent = try #require(
            store.activityEvents.last { $0.proposalId == pending.id && $0.kind == .executed }
        )
        #expect(executedEvent.evidence.isEmpty == false)
        #expect(executedEvent.decision == nil)

        // The log round-trips: a fresh store over the same directory reloads it.
        let reloaded = LiveNilesStore(
            coordinator: coordinator,
            notifier: .disabled,
            activityLog: ActivityLog(directory: directory)
        )
        await reloaded.refresh()
        #expect(reloaded.activityEvents == store.activityEvents)
    }

    /// Undo on the live wiring: the paired revert runs as its own forward
    /// proposal — executed immediately, read back, and linked to the
    /// original in the activity log (the `.undone` event rides the undo tap).
    @Test
    func undoRecordsRevertLinkedToTheOriginal() async throws {
        let fake = FakeHomeKitService(graph: .demoFixture)
        let coordinator = ServerCoordinator(tokenStore: StaticTokenStore(token: "test-token"), homeKitService: fake)
        let store = LiveNilesStore(coordinator: coordinator, notifier: .disabled, activityLog: isolatedActivityLog())
        await store.refresh()
        let registry = WriteToolRegistry(store: try #require(coordinator.proposalStore))
        _ = await registry.call(
            name: "create_room",
            arguments: ["homeId": .string("home-1"), "name": .string("Studio")]
        )
        await store.refresh()
        let staged = try #require(store.pendingProposals.first)
        await store.approveAndWait(staged.id)
        try await waitUntil { store.proposals.first(where: { $0.id == staged.id })?.state == .executed }
        #expect(try await fake.snapshot().homes[0].rooms.contains { $0.name == "Studio" })

        // The Undo tap: the revert stages and executes immediately.
        await store.undoAndWait(staged.id)
        try await waitUntil {
            store.proposals.first { $0.revertsProposalId == staged.id }?.state == .executed
        }

        // The revert is a linked, executed proposal with its own evidence.
        let revert = try #require(store.proposals.first { $0.revertsProposalId == staged.id })
        #expect(revert.state == .executed)
        #expect(revert.evidence.allSatisfy { $0.confirmed })
        #expect(try await fake.snapshot().homes[0].rooms.contains { $0.name == "Studio" } == false)

        // The activity log tells the whole story: the original's life ends
        // in an undone event, and the revert's executed event names what it
        // reverted.
        let kinds = store.activityEvents.filter { $0.proposalId == staged.id }.map(\.kind)
        #expect(kinds == [.staged, .decided, .executed, .undone])
        let revertEvent = try #require(
            store.activityEvents.last { $0.proposalId == revert.id && $0.kind == .executed }
        )
        #expect(revertEvent.detail?.contains("revert of") == true)
    }

    /// Approve all executes every staged proposal immediately — destructive
    /// included — and each decision lands as its own decided event.
    @Test
    func approveAllExecutesAllStagedImmediately() async throws {
        let fake = FakeHomeKitService(graph: .demoFixture)
        let coordinator = ServerCoordinator(tokenStore: StaticTokenStore(token: "test-token"), homeKitService: fake)
        let store = LiveNilesStore(coordinator: coordinator, notifier: .disabled, activityLog: isolatedActivityLog())
        await store.refresh()
        let registry = WriteToolRegistry(store: try #require(coordinator.proposalStore))
        _ = await registry.call(
            name: "create_room",
            arguments: ["homeId": .string("home-1"), "name": .string("Studio")]
        )
        _ = await registry.call(
            name: "rename_room",
            arguments: ["roomId": .string("room-2"), "name": .string("Cookery")]
        )
        await store.refresh()
        #expect(store.pendingProposals.count == 2)

        await store.approveAllAndWait()
        try await waitUntil { store.proposals.allSatisfy { $0.state == .executed } }

        let after = try await fake.snapshot()
        #expect(after.homes[0].rooms.contains { $0.name == "Studio" })
        #expect(after.homes[0].rooms.first { $0.id == "room-2" }?.name == "Cookery")
        let decided = store.activityEvents.filter { $0.kind == .decided }.map(\.proposalId)
        #expect(Set(decided).count == 2)
        #expect(store.pendingProposals.isEmpty)
    }

    /// Regression for the device-QA latency finding: the tap path must give
    /// visible feedback synchronously — before the pipeline round-trip
    /// settles — and reconcile with the settled result.
    @Test
    func approveTapShowsOptimisticFeedbackBeforePipelineSettles() async throws {
        let fake = FakeHomeKitService(graph: .demoFixture)
        let coordinator = ServerCoordinator(tokenStore: StaticTokenStore(token: "test-token"), homeKitService: fake)
        let store = LiveNilesStore(coordinator: coordinator, notifier: .disabled, activityLog: isolatedActivityLog())
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
        let store = LiveNilesStore(coordinator: coordinator, notifier: .disabled, activityLog: isolatedActivityLog())
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
        let store = LiveNilesStore(coordinator: coordinator, notifier: .disabled, activityLog: isolatedActivityLog())
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

        // Authenticated read-back: QA Zone now contains exactly Office, and
        // the read-back evidence agrees.
        let zonesAfterMove = await reads.call(name: "get_zones")
        #expect(zonesAfterMove.isError != true)
        let qaZoneRooms = try Self.roomRefs(named: "QA Zone", in: zonesAfterMove)
        #expect(qaZoneRooms.count == 1)
        #expect(qaZoneRooms[0].id == "room-3")
        #expect(qaZoneRooms[0].name == "Office")

        let executed = store.proposals.first { $0.id == move!.id }
        // The app model summarizes evidence as a string; the structured
        // confirmed/observed fields are covered by the pipeline tests above.
        #expect(executed?.evidence.isEmpty == false)
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

    /// The pairing card shows a live code from the shared manager; the old
    /// token-display surface (QR/reveal) is gone from the store entirely.
    @Test
    func pairingCardShowsLiveCodeFromTheSharedManager() async throws {
        let coordinator = ServerCoordinator(tokenStore: StaticTokenStore(token: "pairing-token"), homeKitService: FakeHomeKitService())
        let store = LiveNilesStore(coordinator: coordinator, notifier: .disabled)
        await store.refresh()
        #expect(store.pairingCode != nil)
        #expect(store.codeExpiresAt != nil)
    }

    /// The pairing card's code: minted by the shared manager at refresh,
    /// six digits, with the expiry the countdown renders.
    @Test
    func pairingCardShowsLiveCodeAfterRefresh() async throws {
        let clock = MutableClock()
        let coordinator = ServerCoordinator(
            tokenStore: StaticTokenStore(token: "test-token"),
            homeKitService: FakeHomeKitService(),
            pairingCodes: PairingCodeManager(now: { clock.date })
        )
        let store = LiveNilesStore(coordinator: coordinator, notifier: .disabled)

        await store.refresh()
        let code = try #require(store.pairingCode)
        #expect(code.count == 6)
        #expect(code.allSatisfy { $0.isWholeNumber })
        let expiry = try #require(store.codeExpiresAt)
        #expect(abs(expiry.timeIntervalSince(clock.date.addingTimeInterval(300))) < 1)
    }

    /// Foreground-after-expiry (and any refresh with no live code) shows a
    /// fresh code, not the stale one.
    @Test
    func expiredCodeIsRemintedOnTheNextRefresh() async throws {
        let clock = MutableClock()
        let coordinator = ServerCoordinator(
            tokenStore: StaticTokenStore(token: "test-token"),
            homeKitService: FakeHomeKitService(),
            pairingCodes: PairingCodeManager(now: { clock.date })
        )
        let store = LiveNilesStore(coordinator: coordinator, notifier: .disabled)
        await store.refresh()
        let stale = try #require(store.pairingCode)
        let staleExpiry = try #require(store.codeExpiresAt)

        clock.advance(by: 301)
        await store.refresh()
        let fresh = try #require(store.pairingCode)
        #expect(fresh != stale)
        let freshExpiry = try #require(store.codeExpiresAt)
        #expect(freshExpiry > staleExpiry)
    }

    /// The "New code" tap discards the live code and mints a fresh one.
    @Test
    func mintNewCodeReplacesTheDisplayedCode() async throws {
        let coordinator = ServerCoordinator(
            tokenStore: StaticTokenStore(token: "test-token"),
            homeKitService: FakeHomeKitService()
        )
        let store = LiveNilesStore(coordinator: coordinator, notifier: .disabled)
        await store.refresh()
        let before = try #require(store.pairingCode)
        let beforeExpiry = try #require(store.codeExpiresAt)

        await store.mintNewCodeAndWait()
        #expect(store.pairingCode != before)
        #expect(try #require(store.codeExpiresAt) > beforeExpiry)

        // The old code no longer verifies on the wire — the tap invalidated it.
        let manager = coordinator.pairingCodes
        #expect(await manager.verify(before) != .success)
    }

    /// A successful exchange burns the code; the card's next refresh shows a
    /// fresh one — never the spent challenge.
    @Test
    func successfulExchangeBurnsTheCodeAndTheCardShowsAFreshOne() async throws {
        let coordinator = ServerCoordinator(
            tokenStore: StaticTokenStore(token: "test-token"),
            homeKitService: FakeHomeKitService()
        )
        let store = LiveNilesStore(coordinator: coordinator, notifier: .disabled)
        await store.refresh()
        let spent = try #require(store.pairingCode)

        #expect(await coordinator.pairingCodes.verify(spent) == .success)
        await store.refresh()
        #expect(store.pairingCode != nil)
        #expect(store.pairingCode != spent)
    }

    /// The paired-agents rows: stored credentials plus what the live sessions
    /// say — named or defaulted, paired date, last-seen or never connected.
    @Test
    func pairedAgentsListRendersNamesDatesAndLastSeen() throws {
        let agentID = UUID()
        let pairedAt = Date(timeIntervalSince1970: 1_768_000_000)
        let agents = [
            PairedAgent(id: agentID, name: "Obvious", token: "t1", pairedAt: pairedAt),
            PairedAgent(id: UUID(), name: nil, token: "t2", pairedAt: pairedAt),
        ]
        let now = Date()
        let sessions = [
            MCPGateway.SessionInfo(
                id: "s1", clientName: "Obvious", tokenId: agentID,
                startedAt: now.addingTimeInterval(-60), lastAccessedAt: now.addingTimeInterval(-30)
            ),
        ]

        let rows = LiveNilesStore.pairedAgentRows(agents: agents, sessions: sessions, now: now)
        #expect(rows.count == 2)
        #expect(rows[0].id == agentID)
        #expect(rows[0].name == "Obvious")
        #expect(rows[0].detail == "paired \(pairedAt.formatted(date: .abbreviated, time: .omitted)) · last seen now")
        #expect(rows[1].name == "Agent")
        #expect(rows[1].detail.hasSuffix("never connected"))
    }

    /// Revocation: the confirm deletes the Keychain item and the list drops
    /// the row; other agents are untouched.
    @Test
    func revokeFlowDeletesTheCredentialAndRefreshesTheList() async throws {
        let kept = PairedAgent(id: UUID(), name: "Kept agent", token: "keep-token", pairedAt: Date())
        let revoked = PairedAgent(id: UUID(), name: "Revoked agent", token: "revoke-token", pairedAt: Date())
        let tokenStore = MutableListTokenStore(agents: [kept, revoked])
        let coordinator = ServerCoordinator(tokenStore: tokenStore, homeKitService: FakeHomeKitService())
        let store = LiveNilesStore(coordinator: coordinator, notifier: .disabled, tokenStore: tokenStore)
        await store.refresh()
        #expect(store.pairedAgents.map(\.name) == ["Kept agent", "Revoked agent"])

        await store.revokeAgent(revoked.id)

        #expect(store.pairedAgents.map(\.name) == ["Kept agent"])
        #expect(tokenStore.revokedIDs == [revoked.id])
        #expect(try tokenStore.listAgents().map(\.id) == [kept.id])
    }

    /// The countdown label under the code — pure, so the wording is pinned.
    @Test
    func countdownLabelRendersTimeRemainingThenExpired() throws {
        let now = Date()
        #expect(SettingsScreen.countdownText(expiresAt: now.addingTimeInterval(95), now: now) == "Expires in 1:35")
        #expect(SettingsScreen.countdownText(expiresAt: now.addingTimeInterval(60), now: now) == "Expires in 1:00")
        #expect(SettingsScreen.countdownText(expiresAt: now.addingTimeInterval(59), now: now) == "Expires in 0:59")
        #expect(SettingsScreen.countdownText(expiresAt: now, now: now) == "Expired")
        #expect(SettingsScreen.countdownText(expiresAt: now.addingTimeInterval(-5), now: now) == "Expired")
    }

    /// The screen keep-awake binding, driven through the same scene-phase
    /// handoff and kill switch the app uses: serving foregrounded disables
    /// the idle timer; the kill switch or backgrounding re-enables it.
    @Test
    func servingKeepsScreenAwakeAndStoppingRestoresAutoLock() async throws {
        let coordinator = ServerCoordinator(tokenStore: StaticTokenStore(token: "test-token"), homeKitService: FakeHomeKitService())
        let store = LiveNilesStore(coordinator: coordinator, notifier: .disabled, activityLog: isolatedActivityLog())
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

    // MARK: - Home swipe-to-stage

    /// The Home screen's single stage funnel: a swipe stages a normal
    /// proposal through the same store path agents use, the proposal appears
    /// in the queue, and the home graph is unchanged before approval.
    @Test
    func swipeToRunSceneStagesProposalWithoutApplyingIt() async throws {
        let fake = FakeHomeKitService(graph: .demoFixture)
        let coordinator = ServerCoordinator(tokenStore: StaticTokenStore(token: "test-token"), homeKitService: fake)
        let store = LiveNilesStore(coordinator: coordinator, notifier: .disabled)
        await store.refresh()
        #expect(store.pendingProposals.isEmpty)
        let before = try await fake.snapshot()

        let sceneRow = try #require(
            store.sections.first { $0.title == "Scenes" }?.rows.first { $0.entityId == "scene-1" }
        )
        await store.stage(row: sceneRow, action: .run)

        // The staged proposal lands in the queue the Approvals screen renders.
        let pending = store.pendingProposals
        #expect(pending.count == 1)
        #expect(pending[0].tool == "execute_scene")
        #expect(pending[0].state == .staged)
        // Attributed to the human who swiped, not an agent.
        #expect(store.proposals.first { $0.id == pending[0].id }?.agentName == "You")

        // Nothing applied: the fake home is byte-identical to before.
        let after = try await fake.snapshot()
        #expect(after == before)
    }

    @Test
    func swipeToArmTriggerStagesSetTriggerStateWithoutArming() async throws {
        let fake = FakeHomeKitService(graph: .demoFixture)
        let coordinator = ServerCoordinator(tokenStore: StaticTokenStore(token: "test-token"), homeKitService: fake)
        let store = LiveNilesStore(coordinator: coordinator, notifier: .disabled)
        await store.refresh()

        // An enabled trigger's primary swipe is Disarm; staging never flips it.
        let triggerRow = try #require(
            store.sections.first { $0.title == "Triggers" }?.rows.first { $0.isEnabled }
        )
        #expect(triggerRow.primaryAction == .setArmed(false))
        await store.stage(row: triggerRow, action: .setArmed(false))

        let pending = store.pendingProposals
        #expect(pending.count == 1)
        #expect(pending[0].tool == "set_trigger_state")

        let graph = try await fake.snapshot()
        #expect(graph.homes[0].triggers.first { $0.id == triggerRow.entityId }?.isEnabled == true)
    }

    @Test
    func swipeToDeleteStagesDestructiveProposalWithoutApplyingIt() async throws {
        let fake = FakeHomeKitService(graph: .demoFixture)
        let coordinator = ServerCoordinator(tokenStore: StaticTokenStore(token: "test-token"), homeKitService: fake)
        let store = LiveNilesStore(coordinator: coordinator, notifier: .disabled)
        await store.refresh()

        let roomRow = try #require(
            store.sections.first { $0.title == "Rooms" }?.rows.first { $0.entityId == "room-1" }
        )
        await store.stage(row: roomRow, action: .delete)

        let pending = store.pendingProposals
        #expect(pending.count == 1)
        #expect(pending[0].tool == "delete_room")
        #expect(pending[0].isDestructive)

        // The room survives until the proposal is approved.
        let graph = try await fake.snapshot()
        #expect(graph.homes[0].rooms.contains { $0.id == "room-1" })
    }

    @Test
    func swipedRenameStagesRenameWithThePromptedName() async throws {
        let fake = FakeHomeKitService(graph: .demoFixture)
        let coordinator = ServerCoordinator(tokenStore: StaticTokenStore(token: "test-token"), homeKitService: fake)
        let store = LiveNilesStore(coordinator: coordinator, notifier: .disabled)
        await store.refresh()

        let zoneRow = try #require(
            store.sections.first { $0.title == "Zones" }?.rows.first
        )
        await store.stage(row: zoneRow, action: .rename, newName: "Top Floor")

        let pending = store.pendingProposals
        #expect(pending.count == 1)
        #expect(pending[0].tool == "rename_zone")

        // Approving applies it — proving the swipe went through the pipeline.
        await store.approveAndWait(pending[0].id)
        try await waitUntil { store.proposals.first { $0.id == pending[0].id }?.state == .executed }
        let graph = try await fake.snapshot()
        #expect(graph.homes[0].zones.contains { $0.name == "Top Floor" })
    }
}
