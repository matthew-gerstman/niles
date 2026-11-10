import Foundation
import MCP
import Testing
@testable import NilesCore

/// The dispatcher's contract: proxy output byte-identical to direct registry
/// results, a mechanical in-band call budget, response truncation, and
/// staged-proposal bookkeeping. No Foundation Models involved — these run
/// anywhere NilesCore tests run.
@Suite struct AgentDispatcherTests {
    private func text(of result: CallTool.Result) -> String {
        result.content.compactMap { part in
            if case .text(let text) = part { return text.text }
            return nil
        }.joined(separator: "\n")
    }

    // MARK: - Parity: proxy == direct registry call

    @Test func validReadCallIsByteIdenticalToDirectRegistry() async throws {
        let fixture = AgentFixtures.registries()
        let dispatcher = NilesToolDispatcher(reads: fixture.reads, writes: fixture.writes)

        let direct = await fixture.reads.call(name: "get_homes", arguments: [:])
        let proxied = await dispatcher.call(name: "get_homes", arguments: [:])

        #expect(proxied.text == text(of: direct))
        #expect(proxied.isError == (direct.isError == true))
        #expect(proxied.stagedProposalId == nil)
    }

    @Test func validWriteCallIsByteIdenticalToDirectRegistry() async throws {
        let fixture = AgentFixtures.registries()
        let dispatcher = NilesToolDispatcher(reads: fixture.reads, writes: fixture.writes)

        let arguments: [String: MCP.Value] = [
            "homeId": .string("home-1"),
            "name": .string("Movie Time"),
            "actions": .array([.object([
                "accessoryId": .string("acc-lr-1"),
                "characteristic": .string("Brightness"),
                "value": .double(30),
            ])]),
        ]
        let direct = await fixture.writes.call(name: "create_scene", arguments: arguments)
        #expect(direct.isError != true)  // sanity: the fixture stages cleanly

        let fresh = AgentFixtures.registries()
        let secondDispatcher = NilesToolDispatcher(reads: fresh.reads, writes: fresh.writes)
        let proxied = await secondDispatcher.call(name: "create_scene", arguments: arguments)

        #expect(proxied.text == text(of: direct))
        #expect(proxied.isError == (direct.isError == true))
    }

    @Test func invalidArgumentsCallIsByteIdenticalToDirectRegistry() async throws {
        let fixture = AgentFixtures.registries()
        let dispatcher = NilesToolDispatcher(reads: fixture.reads, writes: fixture.writes)

        // create_scene without its required arguments.
        let direct = await fixture.writes.call(name: "create_scene", arguments: [:])
        #expect(direct.isError == true)

        let fresh = AgentFixtures.registries()
        let secondDispatcher = NilesToolDispatcher(reads: fresh.reads, writes: fresh.writes)
        let proxied = await secondDispatcher.call(name: "create_scene", arguments: [:])

        #expect(proxied.text == text(of: direct))
        #expect(proxied.isError)
    }

    @Test func unknownToolCallIsByteIdenticalToDirectWriteRegistry() async throws {
        let fixture = AgentFixtures.registries()
        let dispatcher = NilesToolDispatcher(reads: fixture.reads, writes: fixture.writes)

        let direct = await fixture.writes.call(name: "not_a_tool", arguments: nil)
        #expect(direct.isError == true)

        let fresh = AgentFixtures.registries()
        let secondDispatcher = NilesToolDispatcher(reads: fresh.reads, writes: fresh.writes)
        let proxied = await secondDispatcher.call(name: "not_a_tool", arguments: nil)

        #expect(proxied.text == text(of: direct))
        #expect(proxied.isError)
    }

    @Test func plannerRejectionIsByteIdenticalToDirectRegistry() async throws {
        let fixture = AgentFixtures.registries()
        let dispatcher = NilesToolDispatcher(reads: fixture.reads, writes: fixture.writes)

        // A duplicate room name is rejected by the planner.
        let direct = await fixture.writes.call(name: "create_room", arguments: [
            "homeId": .string("home-1"),
            "name": .string("Living Room"),
        ])
        #expect(direct.isError == true)

        let fresh = AgentFixtures.registries()
        let secondDispatcher = NilesToolDispatcher(reads: fresh.reads, writes: fresh.writes)
        let proxied = await secondDispatcher.call(name: "create_room", arguments: [
            "homeId": .string("home-1"),
            "name": .string("Living Room"),
        ])

        #expect(proxied.text == text(of: direct))
        #expect(proxied.isError)
    }

    // MARK: - Budget

    @Test func budgetExhaustionReturnsInBandErrorAndNeverThrows() async throws {
        let fixture = AgentFixtures.registries()
        let dispatcher = NilesToolDispatcher(reads: fixture.reads, writes: fixture.writes, budget: 3)

        for _ in 0..<3 {
            let outcome = await dispatcher.call(name: "get_homes", arguments: [:])
            #expect(!outcome.isError)
        }
        let fourth = await dispatcher.call(name: "get_homes", arguments: [:])
        #expect(fourth.isError)
        #expect(fourth.text.contains("Budget exhausted"))
        #expect(fourth.text.contains("3"))
        let fifth = await dispatcher.call(name: "get_homes", arguments: [:])
        #expect(fifth.isError)
    }

    @Test func budgetCountsFailedCallsToo() async throws {
        let fixture = AgentFixtures.registries()
        let dispatcher = NilesToolDispatcher(reads: fixture.reads, writes: fixture.writes, budget: 2)

        // Two failing calls still spend the budget: otherwise a model looping
        // on bad arguments spins forever.
        _ = await dispatcher.call(name: "not_a_tool", arguments: nil)
        _ = await dispatcher.call(name: "create_scene", arguments: [:])
        let third = await dispatcher.call(name: "get_homes", arguments: [:])
        #expect(third.isError)
        #expect(third.text.contains("Budget exhausted"))
    }

    // MARK: - Truncation

    @Test func oversizedResponsesAreTruncatedWithMarker() async throws {
        var graph = AgentFixtures.graph()
        // Force a big response: 30 rooms of accessories.
        for index in 0..<30 {
            graph.homes[0].rooms.append(HomeGraph.Room(
                id: "room-x-\(index)", name: "Room \(index)",
                accessories: (0..<12).map { AgentFixtures.dimmableLight(
                    id: "acc-\(index)-\($0)", name: "Light \(index)-\($0)"
                ) }
            ))
        }
        let fixture = AgentFixtures.registries(graph: graph)
        let dispatcher = NilesToolDispatcher(reads: fixture.reads, writes: fixture.writes, responseCharacterLimit: 500)

        let outcome = await dispatcher.call(name: "get_rooms", arguments: ["detail": .string("full")])
        #expect(!outcome.isError)
        #expect(outcome.text.count > 500)
        #expect(outcome.text.count < 500 + 250)  // marker only
        #expect(outcome.text.contains("[truncated by Niles"))
    }

    @Test func smallResponsesAreNotTruncated() async throws {
        let fixture = AgentFixtures.registries()
        let dispatcher = NilesToolDispatcher(reads: fixture.reads, writes: fixture.writes)

        let outcome = await dispatcher.call(name: "get_homes", arguments: [:])
        #expect(!outcome.text.contains("[truncated"))
    }

    // MARK: - Staged-proposal bookkeeping

    @Test func successfulWritesRecordStagedProposalIds() async throws {
        let fixture = AgentFixtures.registries()
        let dispatcher = NilesToolDispatcher(reads: fixture.reads, writes: fixture.writes)

        let outcome = await dispatcher.call(name: "create_room", arguments: [
            "homeId": .string("home-1"),
            "name": "Sunroom",
        ])
        #expect(!outcome.isError)
        #expect(outcome.stagedProposalId != nil)
        let staged = await dispatcher.stagedProposalIds
        #expect(staged.count == 1)
        #expect(staged.first == outcome.stagedProposalId)

        let store = fixture.store
        let proposals = await store.allProposals()
        #expect(proposals.count == 1)
        #expect(proposals.first?.id == outcome.stagedProposalId)
    }

    @Test func failedWritesRecordNothing() async throws {
        let fixture = AgentFixtures.registries()
        let dispatcher = NilesToolDispatcher(reads: fixture.reads, writes: fixture.writes)

        let outcome = await dispatcher.call(name: "create_room", arguments: [
            "homeId": .string("home-1"),
            "name": "Living Room",  // duplicate — planner rejects
        ])
        #expect(outcome.isError)
        #expect(outcome.stagedProposalId == nil)
        let staged = await dispatcher.stagedProposalIds
        #expect(staged.isEmpty)
    }

    @Test func readsAndProposalPollRecordNothing() async throws {
        let fixture = AgentFixtures.registries()
        let dispatcher = NilesToolDispatcher(reads: fixture.reads, writes: fixture.writes)

        _ = await dispatcher.call(name: "get_homes", arguments: [:])
        // get_proposal lives in the write registry but reads state.
        let poll = await dispatcher.call(name: "get_proposal", arguments: ["proposalId": .string("nope")])
        #expect(poll.isError)  // nothing staged to poll
        let staged = await dispatcher.stagedProposalIds
        #expect(staged.isEmpty)
    }

    // MARK: - Syracuse sizing (direction 3)

    @Test func syracuseLeanReadFitsWindowButFullDetailIsCapped() async throws {
        // The sizing finding, asserted: a lean get_rooms answer is a small
        // fraction of the 4,096-token window; a full-detail dump of the same
        // home would flood it, so the dispatcher caps it with the marker.
        let fixture = AgentFixtures.registries(graph: AgentFixtures.syracuseShapedGraph())
        let dispatcher = NilesToolDispatcher(reads: fixture.reads, writes: fixture.writes)

        let lean = await dispatcher.call(name: "get_rooms", arguments: [:])
        #expect(!lean.isError)
        #expect(lean.text.count < 16_000)

        let full = await dispatcher.call(name: "get_rooms", arguments: ["detail": .string("full")])
        #expect(!full.isError)
        #expect(full.text.contains("[truncated by Niles"))
    }

    // MARK: - Toolset surface

    @Test func dispatcherExposesEveryRegistryTool() async throws {
        let fixture = AgentFixtures.registries()
        let dispatcher = NilesToolDispatcher(reads: fixture.reads, writes: fixture.writes)

        let definitions = await dispatcher.toolDefinitions
        let names = Set(definitions.map(\.name))
        #expect(names == fixture.reads.toolNames.union(fixture.writes.toolNames))
        #expect(definitions.count == fixture.reads.toolNames.count + fixture.writes.toolNames.count)
    }

    // MARK: - Agent surface (art_yvbPAfG9, v7)

    private func agentDispatcher(graph: HomeGraph = AgentFixtures.graph()) async -> (
        dispatcher: NilesToolDispatcher, store: ProposalStore
    ) {
        let fixture = AgentFixtures.registries(graph: graph)
        let dispatcher = NilesToolDispatcher(reads: fixture.reads, writes: fixture.writes)
        return (dispatcher, fixture.store)
    }

    @Test func agentSurfaceIsExactlyTheTwelveCompactedToolsInCatalogOrder() async throws {
        let (dispatcher, _) = await agentDispatcher()
        let definitions = await dispatcher.agentToolDefinitions
        #expect(definitions.map(\.name) == NilesToolDispatcher.agentToolOrder)
        #expect(definitions.count == 12)
        // The registries' full surfaces stay MCP-only.
        let surface = Set(definitions.map(\.name))
        for excluded in ["get_homes", "get_rooms", "create_room", "create_scene",
                         "create_service_group", "set_zone_rooms", "set_service_group_members",
                         "rename_service_group", "delete_service_group", "delete_trigger",
                         "identify_accessory", "unblock_accessory", "remove_accessory", "niles_tool"] {
            #expect(!surface.contains(excluded), "\(excluded) must stay off the agent surface")
        }
    }

    @Test func unifiedRenameRoutesByEntityType() async throws {
        // Scenes, rooms, and accessories resolve through the same entityId.
        let (dispatcher, store) = await agentDispatcher()
        for (entityId, registryTool) in [
            ("scene-morning", "rename_scene"),
            ("room-living", "rename_room"),
            ("acc-kitchen-1", "rename_accessory"),
        ] {
            let outcome = await dispatcher.call(name: "rename", arguments: [
                "entityId": .string(entityId), "newName": .string("Renamed"),
            ])
            #expect(!outcome.isError, "\(entityId)")
            #expect(outcome.stagedProposalId != nil, "\(entityId)")
        }
        let tools = await store.allProposals().map(\.tool)
        #expect(tools == ["rename_scene", "rename_room", "rename_accessory"])
    }

    @Test func renameOnATriggerIsAnInBandError() async throws {
        let (dispatcher, _) = await agentDispatcher(graph: AgentFixtures.syracuseShapedGraph())
        let outcome = await dispatcher.call(name: "rename", arguments: [
            "entityId": .string("trigger-0"), "newName": .string("New Name"),
        ])
        #expect(outcome.isError)
        #expect(outcome.text.contains("cannot be changed"))
        let staged = await dispatcher.stagedProposalIds
        #expect(staged.isEmpty)
    }

    @Test func unifiedDeleteRemovesAnAccessoryAndStagesRegistryDelete() async throws {
        let (dispatcher, store) = await agentDispatcher()
        let outcome = await dispatcher.call(name: "delete", arguments: [
            "entityId": .string("acc-kitchen-1"),
        ])
        #expect(!outcome.isError)
        let proposals = await store.allProposals()
        #expect(proposals.first?.tool == "remove_accessory")
        #expect(proposals.first?.id == outcome.stagedProposalId)
    }

    @Test func createRoutesEveryKindToItsRegistryTool() async throws {
        let (dispatcher, store) = await agentDispatcher()
        let cases: [([String: MCP.Value], String)] = [
            (["homeId": .string("home-1"), "kind": .string("room"), "name": .string("Sunroom")], "create_room"),
            (["homeId": .string("home-1"), "kind": .string("zone"), "name": .string("Second Floor")], "create_zone"),
            (["homeId": .string("home-1"), "kind": .string("group"), "name": .string("Hydra"),
              "accessoryIds": .array([.string("acc-lr-1"), .string("acc-lr-2"), .string("acc-lr-3")])],
             "create_service_group"),
            (["homeId": .string("home-1"), "kind": .string("scene"), "name": .string("Movie Time"),
              "actions": .array([.object([
                  "accessoryId": .string("acc-lr-1"), "characteristic": .string("Brightness"), "value": .double(30),
              ])])],
             "create_scene"),
            (["homeId": .string("home-1"), "kind": .string("timer"), "name": .string("Sunrise"),
              "fireDate": .string("2026-11-11T07:30:00Z")], "create_timer_trigger"),
            (["homeId": .string("home-1"), "kind": .string("event"), "name": .string("Motion Light"),
              "events": .array([.object([
                  "accessoryId": .string("acc-office-1"), "characteristic": .string("On"),
              ])])],
             "create_event_trigger"),
        ]
        for (arguments, expectedTool) in cases {
            let outcome = await dispatcher.call(name: "create", arguments: arguments)
            #expect(!outcome.isError, "\(expectedTool)")
            #expect(outcome.stagedProposalId != nil, "\(expectedTool)")
        }
        let tools = await store.allProposals().map(\.tool)
        #expect(tools == ["create_room", "create_zone", "create_service_group", "create_scene",
                          "create_timer_trigger", "create_event_trigger"])
    }

    @Test func createRejectsMismatchedPayloadsInBand() async throws {
        let (dispatcher, _) = await agentDispatcher()
        let badCases: [[String: MCP.Value]] = [
            // Scene without actions.
            ["homeId": .string("home-1"), "kind": .string("scene"), "name": .string("Empty")],
            // Group without accessoryIds.
            ["homeId": .string("home-1"), "kind": .string("group"), "name": .string("Alone")],
            // Group naming an unknown accessory.
            ["homeId": .string("home-1"), "kind": .string("group"), "name": .string("Ghost"),
             "accessoryIds": .array([.string("acc-nope")])],
            // Timer without a fireDate.
            ["homeId": .string("home-1"), "kind": .string("timer"), "name": .string("Late")],
            // Event automation without events.
            ["homeId": .string("home-1"), "kind": .string("event"), "name": .string("Mystery")],
            // Unknown kind.
            ["homeId": .string("home-1"), "kind": .string("castle"), "name": .string("Nope")],
        ]
        for arguments in badCases {
            let outcome = await dispatcher.call(name: "create", arguments: arguments)
            #expect(outcome.isError, "arguments: \(arguments)")
            #expect(!outcome.text.isEmpty)
        }
        let staged = await dispatcher.stagedProposalIds
        #expect(staged.isEmpty)
    }

    @Test func updateRoutesGroupZoneAndSceneDeclarations() async throws {
        let (dispatcher, store) = await agentDispatcher()
        let cases: [([String: MCP.Value], String)] = [
            (["entityId": .string("sg-lamps"),
              "members": .array([.string("acc-lr-1"), .string("acc-lr-2")])], "set_service_group_members"),
            (["entityId": .string("zone-upstairs"),
              "rooms": .array([.string("room-living"), .string("room-kitchen")])], "set_zone_rooms"),
            (["entityId": .string("scene-morning"),
              "actions": .array([.object([
                  "accessoryId": .string("acc-lr-1"), "characteristic": .string("Brightness"), "value": .double(40),
              ])])],
             "set_scene_actions"),
        ]
        for (arguments, expectedTool) in cases {
            let outcome = await dispatcher.call(name: "update", arguments: arguments)
            #expect(!outcome.isError, "\(expectedTool)")
            #expect(outcome.stagedProposalId != nil, "\(expectedTool)")
        }
        let tools = await store.allProposals().map(\.tool)
        #expect(tools == ["set_service_group_members", "set_zone_rooms", "set_scene_actions"])

        // update on an entity type with no declarative replacement is an
        // in-band error naming its own tools.
        let roomUpdate = await dispatcher.call(name: "update", arguments: [
            "entityId": .string("room-living"), "members": .array([.string("acc-lr-1")]),
        ])
        #expect(roomUpdate.isError)
    }

    @Test func searchReturnsTypedCandidates() async throws {
        var graph = AgentFixtures.graph()
        graph.homes[0].scenes.append(HomeGraph.Scene(
            id: "scene-chill", name: "Chill", type: "AppleScene", actions: []
        ))
        graph.homes[0].rooms[0].accessories.append(
            AgentFixtures.dimmableLight(id: "acc-chill", name: "Chill Light")
        )
        let (dispatcher, _) = await agentDispatcher(graph: graph)

        let outcome = await dispatcher.call(name: "search", arguments: ["query": .string("chill")])
        #expect(!outcome.isError)
        // Both matches, typed: the model needs the id and the type to ask
        // which one the user means.
        #expect(outcome.text.contains("scene-chill"))
        #expect(outcome.text.contains("acc-chill"))
    }

    @Test func getDetailsLeanSummaryAndDeepRead() async throws {
        let (dispatcher, _) = await agentDispatcher(graph: AgentFixtures.syracuseShapedGraph())

        // No arguments: the lean whole-home summary — no characteristics.
        let lean = await dispatcher.call(name: "get_details", arguments: [:])
        #expect(!lean.isError)
        #expect(lean.text.contains("Syracuse House"))
        #expect(!lean.text.contains("valueDescription"))
        #expect(lean.text.count < 16_000)

        // kind + id: one object in full, characteristics included.
        let deep = await dispatcher.call(name: "get_details", arguments: [
            "kind": .string("accessory"), "id": .string("acc-0"),
        ])
        #expect(!deep.isError)
        #expect(deep.text.contains("characteristics"))

        // Unknown id and a kind missing its id are in-band errors.
        let unknown = await dispatcher.call(name: "get_details", arguments: [
            "kind": .string("accessory"), "id": .string("nope"),
        ])
        #expect(unknown.isError)
        let missingId = await dispatcher.call(name: "get_details", arguments: [
            "kind": .string("accessory"),
        ])
        #expect(missingId.isError)
    }

    @Test func accessoryGroupCreateOutputIsByteIdenticalToDirectRegistryCall() async throws {
        let arguments: [String: MCP.Value] = [
            "homeId": .string("home-1"), "kind": .string("group"), "name": .string("Hydra"),
            "accessoryIds": .array([.string("acc-lr-1"), .string("acc-lr-2"), .string("acc-lr-3")]),
        ]
        let (dispatcher, _) = await agentDispatcher()
        let proxied = await dispatcher.call(name: "create", arguments: arguments)

        // Direct registry call with the adapter-resolved service ids.
        let fixture = AgentFixtures.registries()
        let direct = await fixture.writes.call(name: "create_service_group", arguments: [
            "homeId": .string("home-1"), "name": .string("Hydra"),
            "serviceIds": .array([.string("acc-lr-1-svc"), .string("acc-lr-2-svc"), .string("acc-lr-3-svc")]),
        ])

        #expect(proxied.text == text(of: direct))
        #expect(proxied.isError == (direct.isError == true))
    }
}
