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

    @Test func toolSurfaceIsSixReadsAndFourteenWrites() async throws {
        let (_, store, _, _) = makeContext()
        let reads = ReadToolRegistry(service: await store.homeKit)
        let writes = WriteToolRegistry(store: store)

        #expect(reads.tools.count == 6)
        #expect(writes.tools.count == 14)
        #expect(reads.toolNames.isDisjoint(with: writes.toolNames))
        // Destructive hints land on exactly the three delete tools.
        let destructive = writes.tools.filter { $0.annotations.destructiveHint == true }
        #expect(Set(destructive.map(\.name)) == ["delete_room", "delete_service_group", "delete_trigger"])
    }

    @MainActor
    @Test func coordinatorBuildsAStoreForAnInjectedService() {
        let withService = ServerCoordinator(homeKitService: FakeHomeKitService())
        #expect(withService.proposalStore != nil)

        let without = ServerCoordinator()
        #expect(without.proposalStore == nil)
    }
}
