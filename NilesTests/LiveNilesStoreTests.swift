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
