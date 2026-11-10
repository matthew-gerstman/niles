import Foundation
import MCP
import Testing
@testable import NilesCore

/// The approval pipeline end to end over the fake service: agent request ->
/// staged proposal -> human decision -> (for approvals) executed operations
/// with read-back evidence. No test touches `HMHomeManager`.
@Suite struct ProposalPipelineTests {
    // MARK: - Fixtures

    private let t0 = Date(timeIntervalSince1970: 1_762_592_000)

    private func fixtureGraph() -> HomeGraph {
        let kitchen = HomeGraph.Room(
            id: "room-kitchen", name: "Kitchen",
            accessories: [HomeGraph.Accessory(id: "acc-light-a", name: "Light A")]
        )
        let living = HomeGraph.Room(
            id: "room-living", name: "Living Room",
            accessories: [
                HomeGraph.Accessory(id: "acc-lamp-b", name: "Lamp B"),
                HomeGraph.Accessory(id: "acc-speaker-c", name: "Speaker C"),
            ]
        )
        let office = HomeGraph.Room(id: "room-office", name: "Office")
        let home = HomeGraph.Home(
            id: "home-1",
            name: "Townhouse",
            rooms: [kitchen, living, office],
            zones: [HomeGraph.Zone(id: "zone-upstairs", name: "Upstairs", roomIds: ["room-kitchen"])]
        )
        return HomeGraph(homes: [home])
    }

    /// Controllable clock for the store's TTL — expiry is lazy, so tests move
    /// the clock instead of sleeping.
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: Date
        init(_ time: Date) { self.time = time }
        func advance(by interval: TimeInterval) {
            lock.lock()
            defer { lock.unlock() }
            time = time.addingTimeInterval(interval)
        }
        var now: @Sendable () -> Date { { [self] in self.read() } }
        private func read() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return time
        }
    }

    private func makeContext(
        graph: HomeGraph? = nil, lifetime: TimeInterval = 24 * 60 * 60
    ) -> (fake: FakeHomeKitService, store: ProposalStore, registry: WriteToolRegistry, clock: TestClock) {
        let clock = TestClock(t0)
        let fake = FakeHomeKitService(graph: graph ?? fixtureGraph())
        let store = ProposalStore(homeKit: fake, now: clock.now, lifetime: lifetime)
        let registry = WriteToolRegistry(store: store)
        return (fake, store, registry, clock)
    }

    /// Decodes a successful write-tool result's structured content into the
    /// proposal envelope the agent polls.
    private func proposal(from result: CallTool.Result, sourceLocation: SourceLocation = #_sourceLocation) throws -> Proposal {
        #expect(result.isError != true, sourceLocation: sourceLocation)
        let value = try #require(result.structuredContent, sourceLocation: sourceLocation)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Proposal.self, from: JSONEncoder().encode(value))
    }

    private func errorText(of result: CallTool.Result) -> String? {
        guard result.isError == true else { return nil }
        for case let .text(text, _, _) in result.content {
            return text
        }
        return nil
    }

    // MARK: - Stage -> approve -> applied

    @Test func stageApproveExecutesAndRecordsEvidence() async throws {
        let (fake, store, registry, _) = makeContext()

        let staged = try proposal(from: await registry.call(
            name: "create_room",
            arguments: ["homeId": .string("home-1"), "name": .string("Movie Room")]
        ))
        #expect(staged.state == .staged)

        let graphBefore = await fake.graph
        #expect(!graphBefore.homes.first!.rooms.contains { $0.name == "Movie Room" })

        let approved = try await store.approve(id: staged.id)
        #expect(approved.state == .executed)
        #expect(approved.error == nil)

        let graphAfter = await fake.graph
        #expect(graphAfter.homes.first!.rooms.contains { $0.name == "Movie Room" })

        // Read-back evidence: the claim re-checked against the fresh graph.
        #expect(approved.evidence.count == 1)
        #expect(approved.evidence.first?.confirmed == true)
        #expect(approved.evidence.first?.claim.contains("Movie Room") == true)
    }

    @Test func approvedZoneMembershipAppliesAndConfirms() async throws {
        let (fake, store, registry, _) = makeContext()

        let staged = try proposal(from: await registry.call(
            name: "set_zone_rooms",
            arguments: [
                "zoneId": .string("zone-upstairs"),
                "roomIds": .array([.string("room-kitchen"), .string("room-living"), .string("room-office")]),
            ]
        ))

        let approved = try await store.approve(id: staged.id)
        #expect(approved.state == .executed)

        let graph = await fake.graph
        let zone = graph.homes.first!.zones.first!
        #expect(zone.roomIds.sorted() == ["room-kitchen", "room-living", "room-office"])
        #expect(approved.evidence.first?.confirmed == true)
    }

    @Test func approvedZoneCreationAndDeletionPreservesRooms() async throws {
        let (fake, store, registry, _) = makeContext()

        let created = try proposal(from: await registry.call(
            name: "create_zone",
            arguments: ["homeId": .string("home-1"), "name": .string("Downstairs")]
        ))
        let createdApproved = try await store.approve(id: created.id)
        #expect(createdApproved.state == .executed)
        #expect(createdApproved.evidence.first?.confirmed == true)

        let zoneId = await fake.graph.homes.first!.zones.first(where: { $0.name == "Downstairs" })!.id

        // Destructive severity: the card shows the member-room count and
        // states that rooms survive untouched.
        let deleted = try proposal(from: await registry.call(
            name: "delete_zone", arguments: ["zoneId": .string(zoneId)]
        ))
        #expect(deleted.isDestructive == true)
        #expect(deleted.card.contains { $0.text.contains("rooms survive untouched") })

        let deletedApproved = try await store.approve(id: deleted.id)
        #expect(deletedApproved.state == .executed)
        #expect(deletedApproved.evidence.first?.confirmed == true)

        let graph = await fake.graph
        #expect(!graph.homes.first!.zones.contains { $0.id == zoneId })
        // The zone is gone; its rooms are not.
        #expect(graph.homes.first!.rooms.map(\.name).sorted() == ["Kitchen", "Living Room", "Office"])
    }

    // MARK: - Approval ordering (device QA F3: zone membership vs zone delete)

    /// Forwards to the fake, but suspends the next `setZoneRooms` perform
    /// between an `arm()` and a `release()` — letting a test pin the exact
    /// approval ordering the device QA wave observed (a second approval
    /// completing while the first is still mid-execution).
    private final class GatedHomeKitService: HomeKitWriting, @unchecked Sendable {
        private let fake: FakeHomeKitService
        private let lock = NSLock()
        private var armed = false
        private var hit = false
        private var continuation: CheckedContinuation<Void, Never>?

        init(fake: FakeHomeKitService) { self.fake = fake }

        /// Arms the gate: the next `setZoneRooms` perform suspends.
        func arm() {
            lock.lock()
            armed = true
            lock.unlock()
        }

        /// Releases a suspended `setZoneRooms` perform. Idempotent.
        func release() {
            lock.lock()
            continuation?.resume()
            continuation = nil
            lock.unlock()
        }

        /// True once a `setZoneRooms` perform is suspended in the gate.
        var gateHit: Bool {
            lock.withLock { hit }
        }

        func perform(_ operation: HomeKitOperation) async throws -> String? {
            if case .setZoneRooms = operation {
                let shouldWait = lock.withLock { () -> Bool in
                    let shouldWait = armed
                    if shouldWait { armed = false; hit = true }
                    return shouldWait
                }
                if shouldWait {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        lock.lock()
                        self.continuation = continuation
                        lock.unlock()
                    }
                }
            }
            return try await fake.perform(operation)
        }

        func snapshot() async throws -> HomeGraph {
            try await fake.snapshot()
        }
    }

    /// Waits until the gate reports a hit or the timeout expires — the
    /// gate's suspension is asynchronous by design, never pollable
    /// synchronously.
    private struct GateTimeout: Error {}
    private func waitForGate(
        timeout: TimeInterval = 5, service: GatedHomeKitService
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !service.gateHit {
            guard Date() < deadline else { throw GateTimeout() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func zoneMoveReadBackIsNotPollutedByAConcurrentZoneDeleteApproval() async throws {
        // The device-QA wave's shape: a disposable zone, a membership move
        // into it, and a zone delete approved while the move is still
        // executing. The move's read-back must reflect what the move did —
        // not whatever a later approval changed in the meantime.
        var graph = fixtureGraph()
        graph.homes[0].zones.append(HomeGraph.Zone(id: "zone-qa", name: "Niles QA Zone", roomIds: []))
        let service = GatedHomeKitService(fake: FakeHomeKitService(graph: graph))
        let store = ProposalStore(homeKit: service, now: { Date() })
        let registry = WriteToolRegistry(store: store)

        let moveProposal = try proposal(from: await registry.call(
            name: "set_zone_rooms",
            arguments: ["zoneId": .string("zone-qa"), "roomIds": .array([.string("room-office")])]
        ))
        let deleteProposal = try proposal(from: await registry.call(
            name: "delete_zone", arguments: ["zoneId": .string("zone-qa")]
        ))

        await service.arm()
        defer { service.release() }
        async let moveApproved = store.approve(id: moveProposal.id)
        try await waitForGate(service: service) // the move is suspended mid-execution

        // The delete is approved while the move's execution is suspended —
        // the double-tap ordering the device QA observed (F1b/F3).
        async let deleteApproved = store.approve(id: deleteProposal.id)
        // Give the racing delete every chance to complete before the move's
        // execution resumes.
        try await Task.sleep(for: .milliseconds(200))
        await service.release()

        let (move, delete) = try await (moveApproved, deleteApproved)
        #expect(delete.state == .executed)

        // The move executed while its zone still existed; its own read-back
        // must confirm the membership it applied — never report the zone the
        // LATER approval deleted as "execution failed".
        #expect(move.state == .executed)
        #expect(move.evidence.first?.confirmed == true)
        #expect(move.evidence.first?.observed.contains("Niles QA Zone") == true)

        // Forward-only: the delete still wins — the zone is gone and the
        // room survives it.
        let final = try await service.snapshot()
        #expect(!final.homes[0].zones.contains { $0.id == "zone-qa" })
        #expect(final.homes[0].rooms.contains { $0.id == "room-office" })
    }

    @Test func zoneMoveEvidenceNamesABatchDeleteInsteadOfExecutionFailure() throws {
        // Read-back taken after a later operation in the same approval batch
        // deleted the zone: the final graph cannot confirm membership, but
        // the evidence must say the batch deleted the zone — not that the
        // write failed.
        let graph = fixtureGraph() // no zone-qa — the batch deleted it

        let evidence = ProposalEvidenceCollector.collect(
            operations: [
                .setZoneRooms(homeId: "home-1", zoneId: "zone-qa", addRoomIds: ["room-office"], removeRoomIds: []),
                .removeZone(homeId: "home-1", zoneId: "zone-qa"),
            ],
            createdIds: [nil, nil],
            graph: graph
        )

        #expect(evidence[1].confirmed == true) // the delete itself reads back
        #expect(evidence[0].observed.contains("deleted by a later operation in this batch"))
        #expect(evidence[0].observed.contains("not found after execution") == false)
        #expect(evidence[0].confirmed == false)
    }

    @Test func zoneMoveEvidenceStillReportsAMissingZoneWhenTheBatchNeverDeletedIt() throws {
        // No later delete in the batch: a missing zone IS an execution
        // failure — the honest wording stays.
        let graph = fixtureGraph()

        let evidence = ProposalEvidenceCollector.collect(
            operations: [
                .setZoneRooms(homeId: "home-1", zoneId: "zone-qa", addRoomIds: ["room-office"], removeRoomIds: []),
            ],
            createdIds: [nil],
            graph: graph
        )

        #expect(evidence[0].observed == "Zone zone-qa not found after execution")
        #expect(evidence[0].confirmed == false)
    }

    @Test func approvedZoneRenameAppliesAndConfirms() async throws {
        let (fake, store, registry, _) = makeContext()

        let staged = try proposal(from: await registry.call(
            name: "rename_zone",
            arguments: ["zoneId": .string("zone-upstairs"), "name": .string("Top Floor")]
        ))
        #expect(staged.title == "Rename zone “Upstairs”")

        let approved = try await store.approve(id: staged.id)
        #expect(approved.state == .executed)
        #expect(approved.evidence.first?.confirmed == true)

        let graph = await fake.graph
        #expect(graph.homes.first!.zones.first!.name == "Top Floor")
    }

    @Test func duplicateZoneNameIsRejectedBeforeAnyProposalExists() async throws {
        let (_, _, registry, _) = makeContext()
        let result = await registry.call(
            name: "create_zone",
            arguments: ["homeId": .string("home-1"), "name": .string("upstairs")]
        )
        #expect(result.isError == true)
        #expect(errorText(of: result)?.contains("already exists") == true)
    }

    @Test func zoneDeletionDenialAppliesNothing() async throws {
        let (fake, store, registry, _) = makeContext()

        let staged = try proposal(from: await registry.call(
            name: "delete_zone", arguments: ["zoneId": .string("zone-upstairs")]
        ))
        let denied = try await store.deny(id: staged.id)
        #expect(denied.state == .denied)
        #expect(denied.evidence.isEmpty)

        let graph = await fake.graph
        #expect(graph == fixtureGraph())
    }

    @Test func approvedServiceGroupRenameAppliesAndConfirms() async throws {
        let (fake, store, registry, _) = makeContext()

        let created = try proposal(from: await registry.call(
            name: "create_service_group",
            arguments: ["homeId": .string("home-1"), "name": .string("Desk Lamps")]
        ))
        #expect(try await store.approve(id: created.id).state == .executed)
        let groupId = await fake.graph.homes.first!.serviceGroups.first!.id

        let renamed = try proposal(from: await registry.call(
            name: "rename_service_group",
            arguments: ["groupId": .string(groupId), "name": .string("Floor Lamps")]
        ))
        let renamedApproved = try await store.approve(id: renamed.id)
        #expect(renamedApproved.state == .executed)
        #expect(renamedApproved.evidence.first?.confirmed == true)

        let graph = await fake.graph
        #expect(graph.homes.first!.serviceGroups.first!.name == "Floor Lamps")
    }

    @Test func sceneCreationStagesAndExecutesWithoutExecutingScene() async throws {
        let (fake, store, registry, _) = makeContext()

        let staged = try proposal(from: await registry.call(
            name: "create_scene",
            arguments: [
                "homeId": .string("home-1"),
                "name": .string("Movie Night"),
                "actions": .array([
                    .object([
                        "accessoryId": .string("acc-light-a"),
                        "characteristic": .string("On"),
                        "value": .bool(true),
                    ]),
                    .object([
                        "accessoryId": .string("acc-lamp-b"),
                        "characteristic": .string("Brightness"),
                        "value": .int(30),
                    ]),
                ]),
            ]
        ))
        #expect(staged.state == .staged)

        let approved = try await store.approve(id: staged.id)
        #expect(approved.state == .executed)
        let graph = await fake.graph
        let scene = graph.homes.first!.scenes.first { $0.name == "Movie Night" }
        #expect(scene?.actions.count == 2)
        // Evidence reads the scene's action count back from the graph.
        #expect(approved.evidence.first?.observed.contains("2 actions") == true)
    }

    /// The review card and diff entries name accessories by their human name
    /// resolved from the live graph — never the raw id the agent sent.
    @Test func sceneActionCardShowsResolvedAccessoryNames() async throws {
        var graph = fixtureGraph()
        graph.homes[0].scenes.append(HomeGraph.Scene(
            id: "scene-movie", name: "Movie Night",
            actions: [HomeGraph.SceneAction(
                accessoryId: "acc-lamp-b", accessoryName: "Lamp B", service: nil,
                characteristic: "Brightness", characteristicName: "Brightness", valueDescription: "30"
            )]
        ))
        let (_, store, registry, _) = makeContext(graph: graph)

        let staged = try proposal(from: await registry.call(
            name: "set_scene_actions",
            arguments: [
                "sceneId": .string("scene-movie"),
                "actions": .array([
                    .object([
                        "accessoryId": .string("acc-light-a"),
                        "characteristic": .string("Brightness"),
                        "value": .int(10),
                    ]),
                ]),
            ]
        ))

        // The added action's after-string and card line carry the name.
        let added = staged.entries.first { $0.op == .addMembers }
        #expect(added?.after == "Light A: Brightness → 10")
        // The removed action's before-string resolves its stored name.
        let removed = staged.entries.first { $0.op == .removeMembers }
        #expect(removed?.before == "Lamp B: Brightness → 30")
        #expect(staged.card.contains { $0.text.contains("add action Light A: Brightness → 10") })
        #expect(staged.card.contains { $0.text.contains("remove action Lamp B: Brightness → 30") })
        // No card line falls back to the raw id while the name resolves.
        #expect(!staged.card.contains { $0.text.contains("acc-") })
    }

    /// Unresolvable accessories keep the raw id on the card — the fallback
    /// the spec allows when the graph cannot name the accessory.
    @Test func sceneActionCardFallsBackToRawIdWhenNameUnresolvable() async throws {
        var graph = fixtureGraph()
        graph.homes[0].scenes.append(HomeGraph.Scene(
            id: "scene-movie", name: "Movie Night",
            // A graph record without a stored accessory name (e.g. written
            // before name threading existed) falls back to the raw id.
            actions: [HomeGraph.SceneAction(
                accessoryId: "acc-light-a", accessoryName: nil, service: nil,
                characteristic: "Brightness", characteristicName: "Brightness", valueDescription: "30"
            )]
        ))
        let (_, store, registry, _) = makeContext(graph: graph)

        let staged = try proposal(from: await registry.call(
            name: "set_scene_actions",
            arguments: [
                "sceneId": .string("scene-movie"),
                "actions": .array([
                    .object([
                        "accessoryId": .string("acc-lamp-b"),
                        "characteristic": .string("Brightness"),
                        "value": .int(20),
                    ]),
                ]),
            ]
        ))

        let removed = staged.entries.first { $0.op == .removeMembers }
        #expect(removed?.before == "acc-light-a: Brightness → 30")
        #expect(staged.card.contains { $0.text.contains("remove action acc-light-a: Brightness → 30") })
        // The resolvable addition still shows its name.
        #expect(staged.card.contains { $0.text.contains("add action Lamp B: Brightness → 20") })
    }

    // MARK: - Deny

    @Test func denyLeavesHomeUntouchedAndIsTerminal() async throws {
        let (fake, store, registry, _) = makeContext()

        let staged = try proposal(from: await registry.call(
            name: "rename_room",
            arguments: ["roomId": .string("room-kitchen"), "name": .string("Cookery")]
        ))

        let denied = try await store.deny(id: staged.id)
        #expect(denied.state == .denied)
        #expect(denied.evidence.isEmpty)
        #expect(denied.error == nil)
        #expect(denied.state.leftHomeUntouched)

        let graph = await fake.graph
        #expect(graph == fixtureGraph())

        await #expect(throws: ProposalStoreError.proposalNotPending(id: staged.id, state: .denied)) {
            try await store.approve(id: staged.id)
        }
    }

    // MARK: - Expiry

    @Test func expiredProposalExecutesNothing() async throws {
        let (fake, store, registry, clock) = makeContext()

        let staged = try proposal(from: await registry.call(
            name: "create_room",
            arguments: ["homeId": .string("home-1"), "name": .string("Movie Room")]
        ))

        // Past the 24-hour TTL the lazy sweep retires the proposal: it is
        // listed as expired, its id can no longer be decided, and the fake
        // home never saw the change.
        clock.advance(by: 24 * 60 * 60 + 1)

        let listed = await store.allProposals()
        #expect(listed.first?.state == .expired)

        await #expect(throws: ProposalStoreError.proposalNotPending(id: staged.id, state: .expired)) {
            try await store.approve(id: staged.id)
        }

        let graph = await fake.graph
        #expect(graph == fixtureGraph())

        let polled = try proposal(from: await registry.call(
            name: "get_proposal", arguments: ["proposalId": .string(staged.id)]
        ))
        #expect(polled.state == .expired)
    }

    // MARK: - Event-trigger editing

    /// The deny and expiry paths for update_event_trigger (spec: denial and
    /// expiry apply nothing) plus staging over the pipeline's own fixture.
    @Test func eventTriggerUpdateStagesDeniesAndExpiresWithoutTouchingTheTrigger() async throws {
        let (fake, store, registry, clock) = makeContext()

        let scene = try proposal(from: await registry.call(
            name: "create_scene",
            arguments: [
                "homeId": .string("home-1"),
                "name": .string("Movie Night"),
                "actions": .array([.object([
                    "accessoryId": .string("acc-light-a"),
                    "characteristic": .string("On"),
                    "value": .bool(true),
                ])]),
            ]
        ))
        _ = try await store.approve(id: scene.id)

        let created = try proposal(from: await registry.call(
            name: "create_event_trigger",
            arguments: [
                "homeId": .string("home-1"),
                "name": .string("Lights On"),
                "events": .array([
                    .object([
                        "accessoryId": .string("acc-light-a"),
                        "characteristic": .string("On"),
                        "value": .bool(true),
                    ]),
                ]),
                "sceneId": .string("scene-1"),
            ]
        ))
        _ = try await store.approve(id: created.id)
        let before = await fake.graph.homes.first!.triggers.first!

        // Staging: an edit proposal is staged, then denied — nothing applies.
        let edit = try proposal(from: await registry.call(
            name: "update_event_trigger",
            arguments: [
                "triggerId": .string("trigger-1"),
                "events": .array([.object(["presence": .string("atHome")])]),
            ]
        ))
        let denied = try await store.deny(id: edit.id)
        #expect(denied.state == .denied)
        #expect(denied.state.leftHomeUntouched)
        #expect(await fake.graph.homes.first!.triggers.first! == before)

        // A second edit expires past the TTL — its operations never run.
        let second = try proposal(from: await registry.call(
            name: "update_event_trigger",
            arguments: [
                "triggerId": .string("trigger-1"),
                "events": .array([.object(["presence": .string("away")])]),
            ]
        ))
        clock.advance(by: 24 * 60 * 60 + 1)
        let expired = await store.allProposals().first { $0.id == second.id }
        #expect(expired?.state == .expired)
        await #expect(throws: ProposalStoreError.proposalNotPending(id: second.id, state: .expired)) {
            try await store.approve(id: second.id)
        }
        #expect(await fake.graph.homes.first!.triggers.first! == before)
    }

    // MARK: - Declarative collapse

    @Test func multiRoomZoneDiffCollapsesToOneProposal() async throws {
        let (_, store, registry, _) = makeContext()

        _ = try proposal(from: await registry.call(
            name: "set_zone_rooms",
            arguments: [
                "zoneId": .string("zone-upstairs"),
                "roomIds": .array([.string("room-kitchen"), .string("room-living"), .string("room-office")]),
            ]
        ))

        let listed = await store.allProposals()
        // One agent request -> exactly one approval card, never one per room.
        #expect(listed.count == 1)
        let staged = listed.first!
        #expect(staged.tool == "set_zone_rooms")
        #expect(staged.card.contains { $0.text.contains("Living Room") })
    }

    // MARK: - Blast radius

    @Test func deleteRoomCardNamesTheDefaultRoomFallback() async throws {
        let (fake, store, registry, _) = makeContext()

        let staged = try proposal(from: await registry.call(
            name: "delete_room",
            arguments: ["roomId": .string("room-kitchen")]
        ))
        #expect(staged.isDestructive)
        #expect(staged.card.contains { line in
            line.kind == .note && line.text.contains("default room")
        })

        let approved = try await store.approve(id: staged.id)
        #expect(approved.state == .executed)
        let graph = await fake.graph
        let rooms = graph.homes.first!.rooms
        #expect(!rooms.contains { $0.id == "room-kitchen" })
        // HomeKit's observable behavior: accessories move to the default room.
        let defaultRoom = rooms.first { $0.name == "Default Room" }
        #expect(defaultRoom?.accessories.map(\.id) == ["acc-light-a"])
        #expect(approved.evidence.first?.confirmed == true)
    }

    // MARK: - Validation and dedupe

    @Test func invalidRequestIsRejectedBeforeAnyProposalExists() async throws {
        let (_, store, registry, _) = makeContext()

        let result = await registry.call(
            name: "create_room",
            arguments: ["homeId": .string("home-nope"), "name": .string("Ghost Room")]
        )
        #expect(result.isError == true)
        #expect(errorText(of: result)?.contains("Nothing was staged") == true)
        #expect(await store.allProposals().isEmpty)
    }

    @Test func duplicatePendingRequestReturnsTheSameProposal() async throws {
        let (_, store, registry, _) = makeContext()

        let first = try proposal(from: await registry.call(
            name: "create_room",
            arguments: ["homeId": .string("home-1"), "name": .string("Movie Room")]
        ))
        let second = try proposal(from: await registry.call(
            name: "create_room",
            arguments: ["homeId": .string("home-1"), "name": .string("Movie Room")]
        ))

        #expect(first.id == second.id)
        #expect(await store.allProposals().count == 1)

        // After the first resolves, the same request stages a new proposal.
        _ = try await store.deny(id: first.id)
        let third = try proposal(from: await registry.call(
            name: "create_room",
            arguments: ["homeId": .string("home-1"), "name": .string("Movie Room")]
        ))
        #expect(third.id != first.id)
    }

    // MARK: - Capability validation at staging

    /// A graph whose accessories carry capability data (the read side's
    /// accessory services with their characteristics). "Right" is a plain
    /// on/off bulb; "Dimmable" supports Brightness too.
    private func capabilityGraph() -> HomeGraph {
        func onOff(_ id: String, _ name: String, extra: [HomeGraph.CharacteristicRef] = []) -> HomeGraph.Accessory {
            HomeGraph.Accessory(
                id: id, name: name,
                services: [HomeGraph.AccessoryService(
                    id: "\(id)-svc", name: "Lightbulb", serviceType: "lightbulb",
                    characteristics: [HomeGraph.CharacteristicRef(id: "\(id)-on", type: "On", name: "On")] + extra
                )]
            )
        }
        let dimmable = onOff("acc-dimmable", "Dimmable", extra: [
            HomeGraph.CharacteristicRef(id: "acc-dimmable-brightness", type: "Brightness", name: "Brightness"),
        ])
        let right = onOff("acc-right", "Right")
        // The live read's shape: Characteristic.type carries the HomeKit UUID
        // and the friendly name lives in `name` (DeviceHomeView coordination).
        let liveShape = HomeGraph.Accessory(
            id: "acc-live", name: "Live Shape",
            services: [HomeGraph.AccessoryService(
                id: "acc-live-svc", name: "Lightbulb", serviceType: "lightbulb",
                characteristics: [
                    HomeGraph.CharacteristicRef(id: "acc-live-on", type: "0x0003", name: "On"),
                    HomeGraph.CharacteristicRef(id: "acc-live-brightness", type: "0x0008", name: "Brightness"),
                ]
            )]
        )
        let home = HomeGraph.Home(
            id: "home-1", name: "Townhouse",
            rooms: [HomeGraph.Room(id: "room-living", name: "Living Room", accessories: [right, dimmable, liveShape])]
        )
        return HomeGraph(homes: [home])
    }

    /// The recorded execute-time failure (prop_fde5efe84114: objectMissing —
    /// Accessory "Right" has no service with characteristic Brightness) is
    /// now a staging-time rejection, before any human sees a card.
    @Test func unsupportedCharacteristicIsRejectedAtStaging() async throws {
        let (_, store, registry, _) = makeContext(graph: capabilityGraph())

        let result = await registry.call(
            name: "create_scene",
            arguments: [
                "homeId": .string("home-1"),
                "name": .string("Movie Night"),
                "actions": .array([
                    .object([
                        "accessoryId": .string("acc-right"),
                        "characteristic": .string("Brightness"),
                        "value": .int(30),
                    ]),
                ]),
            ]
        )
        #expect(result.isError == true)
        let text = errorText(of: result) ?? ""
        #expect(text.contains("Accessory “Right” has no service with characteristic Brightness"))
        #expect(text.contains("Nothing was staged"))
        #expect(await store.allProposals().isEmpty)
    }

    @Test func supportedCharacteristicStagesAndExecutes() async throws {
        let (_, store, registry, _) = makeContext(graph: capabilityGraph())

        let staged = try proposal(from: await registry.call(
            name: "create_scene",
            arguments: [
                "homeId": .string("home-1"),
                "name": .string("Movie Night"),
                "actions": .array([
                    .object([
                        "accessoryId": .string("acc-dimmable"),
                        "characteristic": .string("Brightness"),
                        "value": .int(30),
                    ]),
                ]),
            ]
        ))
        #expect(staged.state == .staged)
        // Capability data was readable, so there is no permissive note.
        #expect(!staged.card.contains { $0.text.contains("Could not verify") })

        let approved = try await store.approve(id: staged.id)
        #expect(approved.state == .executed)
        #expect(approved.evidence.first?.confirmed == true)
    }

    /// Accessories whose services list no characteristics (a graph without
    /// capability reads) leave support undeterminable — staging stays
    /// permissive and the card notes it.
    @Test func missingCapabilityDataDegradesToPermissiveNote() async throws {
        // fixtureGraph()'s accessories carry no services — no capability data.
        let (_, store, registry, _) = makeContext()

        let staged = try proposal(from: await registry.call(
            name: "create_scene",
            arguments: [
                "homeId": .string("home-1"),
                "name": .string("Movie Night"),
                "actions": .array([
                    .object([
                        "accessoryId": .string("acc-lamp-b"),
                        "characteristic": .string("Brightness"),
                        "value": .int(30),
                    ]),
                ]),
            ]
        ))
        #expect(staged.state == .staged)
        #expect(staged.card.contains { $0.text.contains("Could not verify Brightness support") })
    }

    /// Coordination with the write-resolver fix: live graphs populate
    /// Characteristic.type with the HomeKit UUID while agents pass friendly
    /// names, so staging matches name OR UUID — the same rule the executor
    /// uses — and never rejects a write execution would accept.
    @Test func friendlyNameMatchesUUIDShapedCharacteristicAtStaging() async throws {
        let (_, store, registry, _) = makeContext(graph: capabilityGraph())

        let staged = try proposal(from: await registry.call(
            name: "create_scene",
            arguments: [
                "homeId": .string("home-1"),
                "name": .string("Movie Night"),
                "actions": .array([
                    .object([
                        "accessoryId": .string("acc-live"),
                        "characteristic": .string("brightness"),
                        "value": .int(30),
                    ]),
                ]),
            ]
        ))
        #expect(staged.state == .staged)
        #expect(!staged.card.contains { $0.text.contains("Could not verify") })
    }

    /// Same class of check for characteristic trigger events: the executor
    /// resolves events against accessory capabilities, so staging does too.
    @Test func characteristicEventOnUnsupportedAccessoryIsRejectedAtStaging() async throws {
        let (_, store, registry, _) = makeContext(graph: capabilityGraph())

        let result = await registry.call(
            name: "create_event_trigger",
            arguments: [
                "homeId": .string("home-1"),
                "name": .string("Dim Alert"),
                "events": .array([
                    .object([
                        "accessoryId": .string("acc-right"),
                        "characteristic": .string("Brightness"),
                        "value": .int(50),
                    ]),
                ]),
            ]
        )
        #expect(result.isError == true)
        #expect(errorText(of: result)?.contains("has no service with characteristic Brightness") == true)
        #expect(await store.allProposals().isEmpty)
    }

    // MARK: - Failed execution


    @Test func failedExecutionRecordsErrorAndUnconfirmedEvidence() async throws {
        let (fake, store, registry, _) = makeContext()

        let staged = try proposal(from: await registry.call(
            name: "rename_room",
            arguments: ["roomId": .string("room-kitchen"), "name": .string("Cookery")]
        ))

        // The world moves between staging and approval: the room vanishes,
        // so the executor cannot resolve the staged reference.
        var moved = fixtureGraph()
        moved.homes[0].rooms.removeAll { $0.id == "room-kitchen" }
        await fake.setGraph(moved)

        let failed = try await store.approve(id: staged.id)
        #expect(failed.state == .failed)
        #expect(failed.error != nil)
        #expect(failed.evidence.first?.confirmed == false)
        #expect(failed.evidence.first?.observed.contains("not found") == true)
    }

    // MARK: - Evidence id threading

    /// A same-named room in an earlier home would fool name-based evidence
    /// matching (the flatMap finds the wrong room first). The created id
    /// pins the evidence to the room the approval actually made.
    @Test func createdRoomEvidenceMatchesByIdNotByName() async throws {
        var graph = fixtureGraph()
        // The decoy lives in the FIRST home, the creation targets the second:
        // name-based matching (flatMap in home order) would describe the
        // decoy, not the room the approval just made.
        graph.homes[0].rooms.append(HomeGraph.Room(
            id: "room-preexisting", name: "Movie Room",
            accessories: [HomeGraph.Accessory(id: "acc-old", name: "Old Light")]
        ))
        graph.homes.append(HomeGraph.Home(id: "home-2", name: "Cottage", rooms: []))
        let (fake, store, registry, _) = makeContext(graph: graph)

        let staged = try proposal(from: await registry.call(
            name: "create_room",
            arguments: ["homeId": .string("home-2"), "name": .string("Movie Room")]
        ))
        let approved = try await store.approve(id: staged.id)
        #expect(approved.state == .executed)
        #expect(approved.evidence.first?.confirmed == true)
        // The decoy holds 1 accessory; the created room starts empty. The
        // created id is what pins the evidence to the right room.
        #expect(approved.evidence.first?.observed.contains("0 accessories") == true)

        let graphAfter = await fake.graph
        #expect(graphAfter.homes.first(where: { $0.id == "home-2" })!.rooms.contains { $0.id == "room-1" })
    }

    /// Creation evidence must assert the NEW trigger is still disabled. A
    /// same-named, already-enabled trigger in an earlier home would
    /// false-fail (or false-confirm arming) under name matching.
    @Test func createdTriggerEvidenceMatchesByIdNotByName() async throws {
        var graph = fixtureGraph()
        // Decoy in home-1 (earlier in flatMap order); creation targets home-2.
        graph.homes[0].triggers.append(HomeGraph.Trigger(
            id: "trigger-preexisting", name: "Evening Lights", isEnabled: true,
            detail: .timer(fireDate: t0, recurrence: [:])
        ))
        graph.homes.append(HomeGraph.Home(id: "home-2", name: "Cottage", rooms: []))
        let (fake, store, registry, _) = makeContext(graph: graph)

        let staged = try proposal(from: await registry.call(
            name: "create_timer_trigger",
            arguments: [
                "homeId": .string("home-2"),
                "name": .string("Evening Lights"),
                "fireDate": .string("2026-11-09T07:30:00Z"),
                "recurrence": .object(["hour": .int(7), "minute": .int(30)]),
            ]
        ))
        let approved = try await store.approve(id: staged.id)
        #expect(approved.state == .executed)
        #expect(approved.evidence.first?.confirmed == true)
        // Name matching would have found the decoy's enabled state instead.
        #expect(approved.evidence.first?.observed.contains("disabled") == true)
    }

    // MARK: - Polling surface

    @Test func getProposalPollReportsStagedAndDeniedStates() async throws {
        let (_, store, registry, _) = makeContext()

        let staged = try proposal(from: await registry.call(
            name: "create_room",
            arguments: ["homeId": .string("home-1"), "name": .string("Movie Room")]
        ))

        let poll = await registry.call(
            name: "get_proposal", arguments: ["proposalId": .string(staged.id)]
        )
        let polled = try proposal(from: poll)
        #expect(polled.id == staged.id)
        #expect(polled.state == .staged)
        #expect(polled.tool == "create_room")

        _ = try await store.deny(id: staged.id)
        let repoll = try proposal(from: await registry.call(
            name: "get_proposal", arguments: ["proposalId": .string(staged.id)]
        ))
        #expect(repoll.state == .denied)

        let unknown = await registry.call(
            name: "get_proposal", arguments: ["proposalId": .string("prop_nope")]
        )
        #expect(unknown.isError == true)
        #expect(errorText(of: unknown)?.contains("No proposal") == true)
    }

    @Test func missingArgumentsAreReportedInBand() async throws {
        let (_, _, registry, _) = makeContext()

        let missing = await registry.call(name: "create_room", arguments: ["homeId": .string("home-1")])
        #expect(missing.isError == true)
        #expect(errorText(of: missing)?.contains("name") == true)

        let missingId = await registry.call(name: "get_proposal", arguments: nil)
        #expect(missingId.isError == true)
    }

    @Test func unknownToolListsTheAvailableTools() async throws {
        let (_, _, registry, _) = makeContext()

        let result = await registry.call(name: "nonsense_tool", arguments: nil)
        #expect(result.isError == true)
        let text = errorText(of: result) ?? ""
        #expect(text.contains("Unknown tool"))
        #expect(text.contains("create_room"))
        #expect(text.contains("get_proposal"))
    }

    @Test func toolSurfaceIsEightReadsAndTwentyEightWrites() async throws {
        let (_, store, _, _) = makeContext()
        let reads = ReadToolRegistry(service: await store.homeKit)
        let writes = WriteToolRegistry(store: store)

        #expect(reads.tools.count == 8)
        #expect(writes.tools.count == 32)
        #expect(reads.toolNames.isDisjoint(with: writes.toolNames))
        // Destructive hints land on exactly the six per-type delete tools
        // plus the unified delete.
        let destructive = writes.tools.filter { $0.annotations.destructiveHint == true }
        #expect(Set(destructive.map(\.name)) == ["delete_room", "delete_service_group", "delete_trigger", "delete_scene", "delete_zone", "remove_accessory", "delete"])
    }

    // MARK: - Trigger arm path

    /// The arm approval end to end: a scene to run, an automation created
    /// disabled that runs it, then the separate enable approval — and the
    /// enabled state must stick, confirmed by read-back evidence. This is
    /// the QA scenario that failed on device (prop_8ef1230a8d71).
    @Test func enableAfterCreateSticksWithConfirmedReadBack() async throws {
        let (fake, store, registry, _) = makeContext()

        // A scene for the automation to run.
        let scene = try proposal(from: await registry.call(
            name: "create_scene",
            arguments: [
                "homeId": .string("home-1"),
                "name": .string("Movie Night"),
                "actions": .array([.object([
                    "accessoryId": .string("acc-light-a"),
                    "characteristic": .string("On"),
                    "value": .bool(true),
                ])]),
            ]
        ))
        _ = try await store.approve(id: scene.id)
        let sceneId = await fake.graph.homes.first!.scenes.first!.id

        // The automation: created DISABLED, running the scene.
        let created = try proposal(from: await registry.call(
            name: "create_timer_trigger",
            arguments: [
                "homeId": .string("home-1"),
                "name": .string("Sunset"),
                "fireDate": .string("2026-11-10T07:30:00Z"),
                "sceneId": .string(sceneId),
            ]
        ))
        let createdResult = try await store.approve(id: created.id)
        #expect(createdResult.state == .executed)

        var trigger = await fake.graph.homes.first!.triggers.first!
        // The create/arm firewall: born disabled, scene linked.
        #expect(trigger.isEnabled == false)
        #expect(trigger.linkedSceneIds == [sceneId])

        // The arm approval — its own proposal, its own human approval.
        let armed = try proposal(from: await registry.call(
            name: "set_trigger_state",
            arguments: ["triggerId": .string(trigger.id), "enabled": .bool(true)]
        ))
        let armedResult = try await store.approve(id: armed.id)
        #expect(armedResult.state == .executed)
        #expect(armedResult.error == nil)

        // The enabled state must stick, and read-back evidence must confirm it.
        trigger = await fake.graph.homes.first!.triggers.first!
        #expect(trigger.isEnabled == true)
        #expect(armedResult.evidence.count == 1)
        #expect(armedResult.evidence.first?.confirmed == true)
    }

    /// Staging rejects the doomed arm up front: an automation with no scene
    /// can never be enabled (HomeKit: "No registered action sets for
    /// trigger"), so the agent learns before a human approves anything.
    @Test func stagingAnArmForAScenelessAutomationIsRejectedWithGuidance() async throws {
        let (fake, store, registry, _) = makeContext()

        let created = try proposal(from: await registry.call(
            name: "create_timer_trigger",
            arguments: [
                "homeId": .string("home-1"),
                "name": .string("Bare"),
                "fireDate": .string("2026-11-10T07:30:00Z"),
            ]
        ))
        _ = try await store.approve(id: created.id)
        let trigger = await fake.graph.homes.first!.triggers.first!

        let armed = await registry.call(
            name: "set_trigger_state",
            arguments: ["triggerId": .string(trigger.id), "enabled": .bool(true)]
        )
        #expect(armed.isError == true)
        let text = errorText(of: armed) ?? ""
        #expect(text.contains("no action sets"))
        #expect(text.contains("scene"))

        // Nothing was staged and the trigger stays as it was.
        #expect(await store.allProposals().count == 1)
        #expect(await fake.graph.homes.first!.triggers.first!.isEnabled == false)
    }

    @MainActor
    @Test func coordinatorBuildsAStoreForAnInjectedService() {
        let withService = ServerCoordinator(homeKitService: FakeHomeKitService())
        #expect(withService.proposalStore != nil)

        let without = ServerCoordinator()
        #expect(without.proposalStore == nil)
    }
}
