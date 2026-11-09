import Foundation
import MCP
import Testing
@testable import NilesCore

/// The paired-revert undo: approve executes immediately and captures the
/// pre-state; undo conflict-checks the revert against the current home and
/// applies it forward-only. No test advances the clock — there is no window
/// to wait out.
@Suite struct ProposalStoreUndoTests {
    // MARK: - Fixtures

    private func fixtureGraph(withScene scene: HomeGraph.Scene? = nil) -> HomeGraph {
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
            zones: [HomeGraph.Zone(id: "zone-upstairs", name: "Upstairs", roomIds: ["room-kitchen"])],
            scenes: scene.map { [$0] } ?? []
        )
        return HomeGraph(homes: [home])
    }

    /// A graph whose accessory carries a writable, valued Brightness
    /// characteristic — the write-undo tests' subject.
    private func writableGraph() -> HomeGraph {
        let living = HomeGraph.Room(
            id: "room-living", name: "Living Room",
            accessories: [
                HomeGraph.Accessory(
                    id: "acc-dim", name: "Dim Lamp",
                    services: [
                        HomeGraph.AccessoryService(
                            id: "service-dim", name: "Dim Lamp", serviceType: "Lightbulb",
                            characteristics: [
                                HomeGraph.CharacteristicRef(
                                    id: "char-dim-brightness", type: "Brightness", name: "Brightness",
                                    valueDescription: "65",
                                    metadata: HomeGraph.CharacteristicMetadata(
                                        format: "float", units: "percentage",
                                        minValue: 0, maxValue: 100, step: 1
                                    )
                                ),
                            ]
                        ),
                    ]
                ),
            ]
        )
        let home = HomeGraph.Home(id: "home-1", name: "Townhouse", rooms: [living])
        return HomeGraph(homes: [home])
    }

    private func makeContext(graph: HomeGraph) -> (fake: FakeHomeKitService, store: ProposalStore, registry: WriteToolRegistry) {
        let fake = FakeHomeKitService(graph: graph)
        let store = ProposalStore(homeKit: fake)
        let registry = WriteToolRegistry(store: store)
        return (fake, store, registry)
    }

    private func proposal(from result: CallTool.Result, sourceLocation: SourceLocation = #_sourceLocation) throws -> Proposal {
        #expect(result.isError != true, sourceLocation: sourceLocation)
        let value = try #require(result.structuredContent, sourceLocation: sourceLocation)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Proposal.self, from: JSONEncoder().encode(value))
    }

    private func brightness(of graph: HomeGraph) -> String? {
        graph.homes.first?.rooms.first?.accessories.first?.services.first?.characteristics.first?.valueDescription
    }

    // MARK: - Undo of a deletion

    @Test func undoOfDeletedRoomRecreatesItAndRestoresMembership() async throws {
        var graph = fixtureGraph()
        let original = graph.homes[0].rooms.first { $0.id == "room-living" }!
        #expect(original.accessories.map(\.id) == ["acc-lamp-b", "acc-speaker-c"])

        let (fake, store, registry) = makeContext(graph: graph)
        let staged = try proposal(from: await registry.call(
            name: "delete_room",
            arguments: ["roomId": .string("room-living")]
        ))
        let approved = try await store.approve(id: staged.id)
        #expect(approved.state == .executed)

        // The deletion displaced both members to the default room.
        let afterDelete = await fake.graph
        #expect(!afterDelete.homes.first!.rooms.contains { $0.id == "room-living" })
        let displaced = afterDelete.homes.first!.rooms.first { $0.name == "Default Room" }
        #expect(displaced?.accessories.map(\.id).sorted() == ["acc-lamp-b", "acc-speaker-c"])

        // Undo: re-create the room (same name) and move both members back.
        let reverted = try await store.undo(proposalId: staged.id)
        #expect(reverted.state == .executed)
        #expect(reverted.error == nil)
        #expect(reverted.revertsProposalId == staged.id)
        #expect(!reverted.evidence.isEmpty)
        #expect(reverted.evidence.allSatisfy { $0.confirmed })
        #expect(reverted.evidence.count == 3) // room re-created + two members returned

        let restored = await fake.graph
        let reCreated = restored.homes.first!.rooms.first { $0.name == "Living Room" }
        #expect(reCreated != nil)
        #expect(reCreated?.id != "room-living") // a re-create gets a fresh id
        #expect(reCreated?.accessories.map(\.id) == ["acc-lamp-b", "acc-speaker-c"])

        // The revert is linked back to the original in the store's history.
        let all = await store.allProposals()
        #expect(all.count == 2)
        #expect(all.contains { $0.id == reverted.id && $0.revertsProposalId == staged.id })

        // No undo of an undo: the original's plan is spent.
        await #expect(throws: ProposalStoreError.notRevertable(id: staged.id)) {
            try await store.undo(proposalId: staged.id)
        }
        let unchanged = await fake.graph
        #expect(unchanged == restored)
    }

    @Test func undoOfZoneDeletionRestoresMembership() async throws {
        let (fake, store, registry) = makeContext(graph: fixtureGraph())
        let staged = try proposal(from: await registry.call(
            name: "delete_zone",
            arguments: ["zoneId": .string("zone-upstairs")]
        ))
        #expect((try await store.approve(id: staged.id)).state == .executed)
        #expect(await fake.graph.homes.first!.zones.isEmpty)

        let reverted = try await store.undo(proposalId: staged.id)
        #expect(reverted.state == .executed)
        #expect(reverted.evidence.allSatisfy { $0.confirmed })

        let restored = await fake.graph
        let zone = restored.homes.first!.zones.first { $0.name == "Upstairs" }
        #expect(zone?.roomIds == ["room-kitchen"])
    }

    @Test func undoOfACreateDeletesTheCreatedObject() async throws {
        let (fake, store, registry) = makeContext(graph: fixtureGraph())
        let staged = try proposal(from: await registry.call(
            name: "create_room",
            arguments: ["homeId": .string("home-1"), "name": .string("Movie Room")]
        ))
        let approved = try await store.approve(id: staged.id)
        #expect(approved.state == .executed)
        #expect(await fake.graph.homes.first!.rooms.contains { $0.name == "Movie Room" })

        let reverted = try await store.undo(proposalId: staged.id)
        #expect(reverted.state == .executed)
        #expect(reverted.evidence.allSatisfy { $0.confirmed })
        #expect(!await fake.graph.homes.first!.rooms.contains { $0.name == "Movie Room" })
    }

    @Test func undoOfARenameRestoresThePriorName() async throws {
        let (fake, store, registry) = makeContext(graph: fixtureGraph())
        let staged = try proposal(from: await registry.call(
            name: "rename_room",
            arguments: ["roomId": .string("room-kitchen"), "name": .string("Cookery")]
        ))
        #expect((try await store.approve(id: staged.id)).state == .executed)
        #expect(await fake.graph.homes.first!.rooms.first { $0.id == "room-kitchen" }?.name == "Cookery")

        let reverted = try await store.undo(proposalId: staged.id)
        #expect(reverted.state == .executed)
        #expect(reverted.evidence.allSatisfy { $0.confirmed })
        #expect(await fake.graph.homes.first!.rooms.first { $0.id == "room-kitchen" }?.name == "Kitchen")
    }

    // MARK: - Undo of a write

    @Test func undoOfAWriteRestoresThePriorValue() async throws {
        let (fake, store, registry) = makeContext(graph: writableGraph())
        let staged = try proposal(from: await registry.call(
            name: "write_characteristic",
            arguments: [
                "accessoryId": .string("acc-dim"),
                "characteristic": .string("Brightness"),
                "value": .int(30),
            ]
        ))
        #expect((try await store.approve(id: staged.id)).state == .executed)
        #expect(brightness(of: await fake.graph) == "30")

        let reverted = try await store.undo(proposalId: staged.id)
        #expect(reverted.state == .executed)
        #expect(reverted.evidence.allSatisfy { $0.confirmed })
        #expect(brightness(of: await fake.graph) == "65")
    }

    // MARK: - Conflicts

    @Test func undoAfterExternalDivergenceThrowsConflictAndAppliesNothing() async throws {
        let (fake, store, registry) = makeContext(graph: writableGraph())
        let staged = try proposal(from: await registry.call(
            name: "write_characteristic",
            arguments: [
                "accessoryId": .string("acc-dim"),
                "characteristic": .string("Brightness"),
                "value": .int(30),
            ]
        ))
        #expect((try await store.approve(id: staged.id)).state == .executed)

        // The world moved on: something else wrote the characteristic.
        var drifted = await fake.graph
        drifted.homes[0].rooms[0].accessories[0].services[0].characteristics[0].valueDescription = "72"
        await fake.setGraph(drifted)

        do {
            _ = try await store.undo(proposalId: staged.id)
            Issue.record("Undo should have conflicted with the diverged state")
        } catch let error as ProposalStoreError {
            guard case .undoConflict(let id, let divergences) = error else {
                Issue.record("Expected undoConflict, got \(error)")
                return
            }
            #expect(id == staged.id)
            #expect(!divergences.isEmpty)
            #expect(divergences.allSatisfy { !$0.confirmed })
        }

        // Nothing was applied: the drift stands, and no revert proposal
        // was staged.
        #expect(brightness(of: await fake.graph) == "72")
        let all = await store.allProposals()
        #expect(all.count == 1)
    }

    @Test func undoOfRecreatedNameConflictIsRefused() async throws {
        let (fake, store, registry) = makeContext(graph: fixtureGraph())
        let staged = try proposal(from: await registry.call(
            name: "delete_room",
            arguments: ["roomId": .string("room-kitchen")]
        ))
        #expect((try await store.approve(id: staged.id)).state == .executed)

        // Someone re-took the deleted room's name.
        var drifted = await fake.graph
        drifted.homes[0].rooms.append(HomeGraph.Room(id: "room-kitchen-2", name: "Kitchen", accessories: []))
        await fake.setGraph(drifted)

        do {
            _ = try await store.undo(proposalId: staged.id)
            Issue.record("Undo should have refused the re-taken name")
        } catch let error as ProposalStoreError {
            guard case .undoConflict(let id, let divergences) = error else {
                Issue.record("Expected undoConflict, got \(error)")
                return
            }
            #expect(id == staged.id)
            #expect(divergences.contains { $0.claim.contains("Kitchen") })
        }
    }

    // MARK: - Unrevertable operations

    @Test func sceneExecutionHasNoRevertAndUndoThrowsNotRevertable() async throws {
        let scene = HomeGraph.Scene(
            id: "scene-morning", name: "Morning", type: "Scene", lastExecutionDate: nil, actions: []
        )
        let (fake, store, registry) = makeContext(graph: fixtureGraph(withScene: scene))
        let staged = try proposal(from: await registry.call(
            name: "execute_scene",
            arguments: ["sceneId": .string("scene-morning")]
        ))
        #expect((try await store.approve(id: staged.id)).state == .executed)
        #expect(await fake.graph.homes.first!.scenes.first?.lastExecutionDate != nil)

        // A scene run has no inverse and never offers Undo: no revert
        // proposal is staged, and the undo throws.
        await #expect(throws: ProposalStoreError.notRevertable(id: staged.id)) {
            try await store.undo(proposalId: staged.id)
        }
        let all = await store.allProposals()
        #expect(all.count == 1)
    }

    @Test func undoOfDeniedProposalThrowsNotRevertable() async throws {
        let (_, store, registry) = makeContext(graph: fixtureGraph())
        let staged = try proposal(from: await registry.call(
            name: "create_room",
            arguments: ["homeId": .string("home-1"), "name": .string("Movie Room")]
        ))
        #expect((try await store.deny(id: staged.id)).state == .denied)

        await #expect(throws: ProposalStoreError.notRevertable(id: staged.id)) {
            try await store.undo(proposalId: staged.id)
        }
    }

    // MARK: - Approve all

    @Test func approveAllExecutesEverythingImmediatelyWithPerItemUndo() async throws {
        let (fake, store, registry) = makeContext(graph: fixtureGraph())
        _ = try proposal(from: await registry.call(
            name: "create_room",
            arguments: ["homeId": .string("home-1"), "name": .string("Movie Room")]
        ))
        _ = try proposal(from: await registry.call(
            name: "rename_room",
            arguments: ["roomId": .string("room-office"), "name": .string("Study")]
        ))
        _ = try proposal(from: await registry.call(
            name: "delete_zone",
            arguments: ["zoneId": .string("zone-upstairs")]
        ))

        // One batch approval, destructive included — no clock advancement,
        // no scheduled execution.
        let executed = try await store.approveAll()
        #expect(executed.count == 3)
        #expect(executed.allSatisfy { $0.state == .executed })
        let after = await fake.graph
        #expect(after.homes.first!.rooms.contains { $0.name == "Movie Room" })
        #expect(after.homes.first!.rooms.first { $0.id == "room-office" }?.name == "Study")
        #expect(after.homes.first!.zones.isEmpty)

        // Undo afterwards is per-item, each with its own conflict check.
        let zoneDeletion = executed.last!
        let reverted = try await store.undo(proposalId: zoneDeletion.id)
        #expect(reverted.state == .executed)
        #expect(reverted.revertsProposalId == zoneDeletion.id)
        let restored = await fake.graph
        #expect(restored.homes.first!.zones.first { $0.name == "Upstairs" }?.roomIds == ["room-kitchen"])
    }
}
