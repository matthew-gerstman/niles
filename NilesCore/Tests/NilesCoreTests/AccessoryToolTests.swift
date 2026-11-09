import Foundation
import MCP
import Testing
@testable import NilesCore

/// The accessory-lifecycle tools end to end over the fake service: rename,
/// identify (capability-gated), room assignment, unblock, and destructive
/// remove (with the full reference inventory on the card) — staging, the
/// deny and expiry paths that apply nothing, and execution with read-back
/// evidence. No test touches `HMHomeManager`.
@Suite struct AccessoryToolTests {
    private let t0 = Date(timeIntervalSince1970: 1_762_592_000)

    private func fixtureGraph() -> HomeGraph {
        let identify = HomeGraph.Accessory(id: "acc-light-a", name: "Light A", supportsIdentify: true)
        let noIdentify = HomeGraph.Accessory(id: "acc-sensor", name: "Door Sensor", supportsIdentify: false)
        let kitchen = HomeGraph.Room(
            id: "room-kitchen", name: "Kitchen",
            accessories: [identify]
        )
        let hallway = HomeGraph.Room(
            id: "room-hallway", name: "Hallway",
            accessories: [noIdentify]
        )
        let movieNight = HomeGraph.Scene(
            id: "scene-movie", name: "Movie Night", type: "AppleScene",
            actions: [
                HomeGraph.SceneAction(
                    accessoryId: "acc-light-a", accessoryName: "Light A",
                    service: nil, characteristic: "On", characteristicName: nil,
                    valueDescription: "1"
                ),
            ]
        )
        let everything = HomeGraph.ServiceGroup(
            id: "group-all", name: "Everything",
            services: [
                HomeGraph.ServiceRef(
                    id: "svc-light-a", name: "Light A", serviceType: "Lightbulb",
                    accessoryId: "acc-light-a", accessoryName: "Light A"
                ),
            ]
        )
        let watcher = HomeGraph.Trigger(
            id: "trigger-watch", name: "Light watcher", isEnabled: false,
            linkedSceneIds: [],
            detail: .event(
                events: [
                    HomeGraph.EventRef(
                        type: "characteristic", characteristicType: "On",
                        valueDescription: "1", accessoryId: "acc-light-a"
                    ),
                ],
                predicate: nil
            )
        )
        let home = HomeGraph.Home(
            id: "home-1",
            name: "Townhouse",
            rooms: [kitchen, hallway],
            scenes: [movieNight],
            serviceGroups: [everything],
            triggers: [watcher]
        )
        return HomeGraph(homes: [home])
    }

    /// Controllable clock for the store's TTL — expiry is lazy, so tests move
    /// the clock instead of sleeping (same pattern as SceneToolTests).
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

    // MARK: - Rename

    @Test func renameAccessoryStagesAndExecutesWithReadBack() async throws {
        let (fake, store, registry, _) = makeContext()

        let staged = try proposal(from: await registry.call(
            name: "rename_accessory",
            arguments: ["accessoryId": .string("acc-light-a"), "name": .string("Kitchen Lamp")]
        ))
        #expect(staged.state == .staged)
        #expect(staged.isDestructive == false)
        #expect(staged.entries.first?.op == .rename)
        #expect(staged.card.contains { $0.text.contains("Light A") && $0.text.contains("Kitchen Lamp") })

        let approved = try await store.approve(id: staged.id)
        #expect(approved.state == .executed)
        #expect(approved.error == nil)
        #expect(approved.evidence.first?.confirmed == true)
        #expect(approved.evidence.first?.claim.contains("Kitchen Lamp") == true)

        let graph = await fake.graph
        #expect(graph.homes.first!.rooms.first { $0.id == "room-kitchen" }?
            .accessories.first { $0.id == "acc-light-a" }?.name == "Kitchen Lamp")
    }

    @Test func renameAccessoryToSameNameIsANoChange() async throws {
        let (_, _, registry, _) = makeContext()

        let result = await registry.call(
            name: "rename_accessory",
            arguments: ["accessoryId": .string("acc-light-a"), "name": .string("light a")]
        )
        #expect(errorText(of: result)?.contains("already named") == true)
    }

    @Test func renameMissingAccessoryFailsBeforeStaging() async throws {
        let (_, store, registry, _) = makeContext()

        let result = await registry.call(
            name: "rename_accessory",
            arguments: ["accessoryId": .string("acc-nowhere"), "name": .string("Ghost")]
        )
        #expect(errorText(of: result)?.contains("No accessory with id acc-nowhere") == true)
        #expect(await store.allProposals().isEmpty)
    }

    // MARK: - Identify

    @Test func identifyStagesAndExecutesWithPresenceEvidence() async throws {
        let (fake, store, registry, _) = makeContext()

        let staged = try proposal(from: await registry.call(
            name: "identify_accessory",
            arguments: ["accessoryId": .string("acc-light-a")]
        ))
        #expect(staged.state == .staged)
        #expect(staged.isDestructive == false)
        #expect(staged.card.contains { $0.text.contains("Light A") && $0.text.contains("flash/beep") })

        let approved = try await store.approve(id: staged.id)
        #expect(approved.state == .executed)
        #expect(approved.evidence.first?.confirmed == true)

        // Identify has no graph-observable effect; the accessory must remain.
        let graph = await fake.graph
        #expect(graph.homes.first!.rooms.flatMap(\.accessories).contains { $0.id == "acc-light-a" })
    }

    @Test func identifyKnownUnsupportedAccessoryIsRejectedAtStaging() async throws {
        let (_, store, registry, _) = makeContext()

        let result = await registry.call(
            name: "identify_accessory",
            arguments: ["accessoryId": .string("acc-sensor")]
        )
        let text = try #require(errorText(of: result))
        #expect(text.contains("Door Sensor"))
        #expect(text.contains("does not support identify"))
        #expect(await store.allProposals().isEmpty)
    }

    @Test func identifyWithUnknownCapabilityDataStagesWithACaution() async throws {
        var graph = fixtureGraph()
        graph.homes[0].rooms[0].accessories[0].supportsIdentify = nil
        let (_, store, registry, _) = makeContext(graph: graph)

        let staged = try proposal(from: await registry.call(
            name: "identify_accessory",
            arguments: ["accessoryId": .string("acc-light-a")]
        ))
        #expect(staged.card.contains { $0.kind == .note && $0.text.contains("Could not verify identify support") })
        #expect(try await store.proposal(id: staged.id).state == .staged)
    }

    // MARK: - Room assignment

    @Test func assignAccessoryToRoomStagesAndExecutesWithReadBack() async throws {
        let (fake, store, registry, _) = makeContext()

        let staged = try proposal(from: await registry.call(
            name: "assign_accessory_to_room",
            arguments: ["accessoryId": .string("acc-light-a"), "roomId": .string("room-hallway")]
        ))
        #expect(staged.entries.first?.op == .move)
        #expect(staged.entries.first?.before == "Kitchen")
        #expect(staged.entries.first?.after == "Hallway")

        let approved = try await store.approve(id: staged.id)
        #expect(approved.state == .executed)
        #expect(approved.evidence.first?.confirmed == true)

        let graph = await fake.graph
        #expect(graph.homes.first!.rooms.first { $0.id == "room-kitchen" }?
            .accessories.contains { $0.id == "acc-light-a" } == false)
        #expect(graph.homes.first!.rooms.first { $0.id == "room-hallway" }?
            .accessories.contains { $0.id == "acc-light-a" } == true)
    }

    @Test func assignAccessoryToUnknownRoomFailsBeforeStaging() async throws {
        let (_, store, registry, _) = makeContext()

        let result = await registry.call(
            name: "assign_accessory_to_room",
            arguments: ["accessoryId": .string("acc-light-a"), "roomId": .string("room-nowhere")]
        )
        #expect(errorText(of: result)?.contains("room-nowhere") == true)
        #expect(await store.allProposals().isEmpty)
    }

    @Test func assignAccessoryToItsOwnRoomIsANoChange() async throws {
        let (_, _, registry, _) = makeContext()

        let result = await registry.call(
            name: "assign_accessory_to_room",
            arguments: ["accessoryId": .string("acc-light-a"), "roomId": .string("room-kitchen")]
        )
        #expect(errorText(of: result)?.contains("already in") == true)
    }

    // MARK: - Unblock

    @Test func unblockAccessoryStagesAndExecutes() async throws {
        let (fake, store, registry, _) = makeContext()

        let staged = try proposal(from: await registry.call(
            name: "unblock_accessory",
            arguments: ["accessoryId": .string("acc-light-a")]
        ))
        #expect(staged.isDestructive == false)

        let approved = try await store.approve(id: staged.id)
        #expect(approved.state == .executed)
        #expect(approved.evidence.first?.confirmed == true)

        let graph = await fake.graph
        #expect(graph == fixtureGraph())
    }

    // MARK: - Remove (destructive)

    @Test func removeAccessoryCardListsEveryReference() async throws {
        let (fake, store, registry, _) = makeContext()

        let staged = try proposal(from: await registry.call(
            name: "remove_accessory",
            arguments: ["accessoryId": .string("acc-light-a")]
        ))
        #expect(staged.isDestructive == true)
        #expect(staged.entries.first?.op == .delete)
        // The card inventories every reference: scene, service group, trigger.
        #expect(staged.card.contains { $0.kind == .remove && $0.text.contains("Light A") })
        #expect(staged.card.contains { $0.kind == .note && $0.text.contains("Movie Night") })
        #expect(staged.card.contains { $0.kind == .note && $0.text.contains("Everything") })
        #expect(staged.card.contains { $0.kind == .note && $0.text.contains("Light watcher") })

        let approved = try await store.approve(id: staged.id)
        #expect(approved.state == .executed)
        #expect(approved.evidence.first?.confirmed == true)

        let graph = await fake.graph
        // The accessory is gone…
        #expect(graph.homes.first!.rooms.flatMap(\.accessories).contains { $0.id == "acc-light-a" } == false)
        // …and everything referencing it was detached, never broken.
        #expect(graph.homes.first!.scenes.first { $0.id == "scene-movie" }?.actions.isEmpty == true)
        #expect(graph.homes.first!.serviceGroups.first { $0.id == "group-all" }?.services.isEmpty == true)
        #expect(graph.homes.first!.triggers.first { $0.id == "trigger-watch" } != nil)
        if case .event(let events, _) = graph.homes.first!.triggers.first { $0.id == "trigger-watch" }!.detail {
            #expect(events.isEmpty)
        } else {
            Issue.record("Trigger watcher should remain an event trigger")
        }
    }

    @Test func removeUnreferencedAccessorySaysSoOnTheCard() async throws {
        let (fake, store, registry, _) = makeContext()

        let staged = try proposal(from: await registry.call(
            name: "remove_accessory",
            arguments: ["accessoryId": .string("acc-sensor")]
        ))
        #expect(staged.card.contains { $0.text.contains("Nothing references this accessory.") })

        let approved = try await store.approve(id: staged.id)
        #expect(approved.state == .executed)

        let graph = await fake.graph
        #expect(graph.homes.first!.rooms.flatMap(\.accessories).contains { $0.id == "acc-sensor" } == false)
    }

    @Test func denyLeavesAccessoryAndReferencesUntouched() async throws {
        let (fake, store, registry, _) = makeContext()

        let staged = try proposal(from: await registry.call(
            name: "remove_accessory",
            arguments: ["accessoryId": .string("acc-light-a")]
        ))
        let denied = try await store.deny(id: staged.id)
        #expect(denied.state == .denied)
        #expect(denied.evidence.isEmpty)

        #expect(await fake.graph == fixtureGraph())
    }

    @Test func expiredRemoveAccessoryExecutesNothing() async throws {
        let (fake, store, registry, clock) = makeContext()

        let staged = try proposal(from: await registry.call(
            name: "remove_accessory",
            arguments: ["accessoryId": .string("acc-light-a")]
        ))

        // Past the 24-hour TTL the lazy sweep retires the proposal: the
        // decision path refuses it and the fake home never saw the change.
        clock.advance(by: 24 * 60 * 60 + 1)

        let listed = await store.allProposals()
        #expect(listed.first?.state == .expired)

        await #expect(throws: ProposalStoreError.proposalNotPending(id: staged.id, state: .expired)) {
            try await store.approve(id: staged.id)
        }

        #expect(await fake.graph == fixtureGraph())
    }
}
