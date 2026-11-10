import Foundation
import MCP
import Testing
@testable import NilesCore

/// The unified write verbs (Blueprint art_34OYtrUm, write layer): rename,
/// delete, create, and update dispatch by id to the SAME per-type code paths
/// the per-type tools use. Two properties are locked here:
///
/// - Dispatch equivalence — a unified call and its per-type predecessor
///   produce the identical `Plan` (so the identical proposal); a unified
///   verb with its own dispatch path fails these tests.
/// - Staging semantics — proposals still require human approval, nothing
///   executes directly, automations stage DISABLED with arming as its own
///   separate proposal (set_trigger_state is not absorbed into update),
///   and the device-immediate tools keep their own signatures.
@Suite struct UnifiedWriteToolTests {
    private let t0 = Date(timeIntervalSince1970: 1_762_592_000)

    // MARK: - Fixtures

    /// One home with every entity kind: two rooms with accessories (each
    /// exposing a Lightbulb service with the characteristics writes target),
    /// a zone, a scene with actions, a service group, and one timer plus one
    /// event trigger — everything a unified verb can dispatch to.
    private func fixtureGraph() -> HomeGraph {
        let onA = HomeGraph.CharacteristicRef(id: "char-light-a-on", type: "On")
        let onB = HomeGraph.CharacteristicRef(id: "char-light-b-on", type: "On")
        let brightA = HomeGraph.CharacteristicRef(id: "char-light-a-bright", type: "Brightness")
        let brightB = HomeGraph.CharacteristicRef(id: "char-light-b-bright", type: "Brightness")
        let kitchen = HomeGraph.Room(
            id: "room-kitchen", name: "Kitchen",
            accessories: [HomeGraph.Accessory(
                id: "acc-light-a", name: "Light A",
                services: [HomeGraph.AccessoryService(
                    id: "svc-light-a", name: "Light A",
                    characteristics: [onA, brightA]
                )]
            )]
        )
        let living = HomeGraph.Room(
            id: "room-living", name: "Living Room",
            accessories: [HomeGraph.Accessory(
                id: "acc-light-b", name: "Light B",
                services: [HomeGraph.AccessoryService(
                    id: "svc-light-b", name: "Light B",
                    characteristics: [onB, brightB]
                )]
            )]
        )
        let upstairs = HomeGraph.Zone(id: "zone-upstairs", name: "Upstairs", roomIds: ["room-kitchen", "room-living"])
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
        let deskLamps = HomeGraph.ServiceGroup(
            id: "group-desk", name: "Desk Lamps",
            services: [
                HomeGraph.ServiceRef(
                    id: "svc-light-a", name: "Light A", serviceType: "Lightbulb",
                    accessoryId: "acc-light-a", accessoryName: "Light A"
                ),
            ]
        )
        let sunset = HomeGraph.Trigger(
            id: "trigger-sunset", name: "Sunset lights", isEnabled: false,
            linkedSceneIds: ["scene-movie"],
            detail: .timer(fireDate: Date(timeIntervalSince1970: 1_762_592_400), recurrence: [:])
        )
        let motion = HomeGraph.Trigger(
            id: "trigger-motion", name: "Motion lights", isEnabled: false,
            detail: .event(HomeGraph.Trigger.Detail.EventDetail(
                events: [HomeGraph.EventRef(
                    type: "characteristic", characteristicType: "MotionDetected",
                    valueDescription: "1", accessoryId: "acc-light-a"
                )],
                predicate: "presence predicate", readable: true
            ))
        )
        let home = HomeGraph.Home(
            id: "home-1", name: "Townhouse",
            rooms: [kitchen, living],
            zones: [upstairs],
            scenes: [movieNight],
            serviceGroups: [deskLamps],
            triggers: [sunset, motion]
        )
        return HomeGraph(homes: [home])
    }

    private func makeContext() -> (fake: FakeHomeKitService, store: ProposalStore, registry: WriteToolRegistry) {
        let fake = FakeHomeKitService(graph: fixtureGraph())
        let store = ProposalStore(homeKit: fake, now: { self.t0 })
        let registry = WriteToolRegistry(store: store)
        return (fake, store, registry)
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

    /// The shared-dispatch assertion: the unified call and its per-type
    /// predecessor plan to the identical proposal plan.
    private func assertDispatchEquivalent(
        unifiedTool: String, unifiedArguments: [String: MCP.Value],
        perTypeTool: String, perTypeArguments: [String: MCP.Value],
        graph: HomeGraph,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let plan = ProposalPlanner.planFunction
        let unifiedPlan = try plan(unifiedTool, unifiedArguments, graph)
        let perTypePlan = try plan(perTypeTool, perTypeArguments, graph)
        #expect(unifiedPlan == perTypePlan, sourceLocation: sourceLocation)
    }

    // MARK: - Dispatch equivalence: rename

    @Test func renameDispatchesToEachPerTypeRename() throws {
        let graph = fixtureGraph()
        try assertDispatchEquivalent(
            unifiedTool: "rename",
            unifiedArguments: ["entityId": .string("room-kitchen"), "newName": .string("Cook Space")],
            perTypeTool: "rename_room",
            perTypeArguments: ["roomId": .string("room-kitchen"), "name": .string("Cook Space")],
            graph: graph
        )
        try assertDispatchEquivalent(
            unifiedTool: "rename",
            unifiedArguments: ["entityId": .string("zone-upstairs"), "newName": .string("Top Floor")],
            perTypeTool: "rename_zone",
            perTypeArguments: ["zoneId": .string("zone-upstairs"), "name": .string("Top Floor")],
            graph: graph
        )
        try assertDispatchEquivalent(
            unifiedTool: "rename",
            unifiedArguments: ["entityId": .string("scene-movie"), "newName": .string("Cinema")],
            perTypeTool: "rename_scene",
            perTypeArguments: ["sceneId": .string("scene-movie"), "name": .string("Cinema")],
            graph: graph
        )
        try assertDispatchEquivalent(
            unifiedTool: "rename",
            unifiedArguments: ["entityId": .string("group-desk"), "newName": .string("Study Lamps")],
            perTypeTool: "rename_service_group",
            perTypeArguments: ["groupId": .string("group-desk"), "name": .string("Study Lamps")],
            graph: graph
        )
        try assertDispatchEquivalent(
            unifiedTool: "rename",
            unifiedArguments: ["entityId": .string("acc-light-a"), "newName": .string("Lamp A")],
            perTypeTool: "rename_accessory",
            perTypeArguments: ["accessoryId": .string("acc-light-a"), "name": .string("Lamp A")],
            graph: graph
        )
    }

    // MARK: - Dispatch equivalence: delete

    @Test func deleteDispatchesToEachPerTypeDelete() throws {
        let graph = fixtureGraph()
        try assertDispatchEquivalent(
            unifiedTool: "delete",
            unifiedArguments: ["entityId": .string("room-kitchen")],
            perTypeTool: "delete_room",
            perTypeArguments: ["roomId": .string("room-kitchen")],
            graph: graph
        )
        try assertDispatchEquivalent(
            unifiedTool: "delete",
            unifiedArguments: ["entityId": .string("zone-upstairs")],
            perTypeTool: "delete_zone",
            perTypeArguments: ["zoneId": .string("zone-upstairs")],
            graph: graph
        )
        try assertDispatchEquivalent(
            unifiedTool: "delete",
            unifiedArguments: ["entityId": .string("scene-movie"), "deleteLinkedTriggers": .bool(true)],
            perTypeTool: "delete_scene",
            perTypeArguments: ["sceneId": .string("scene-movie"), "deleteLinkedTriggers": .bool(true)],
            graph: graph
        )
        try assertDispatchEquivalent(
            unifiedTool: "delete",
            unifiedArguments: ["entityId": .string("group-desk")],
            perTypeTool: "delete_service_group",
            perTypeArguments: ["groupId": .string("group-desk")],
            graph: graph
        )
        try assertDispatchEquivalent(
            unifiedTool: "delete",
            unifiedArguments: ["entityId": .string("acc-light-a")],
            perTypeTool: "remove_accessory",
            perTypeArguments: ["accessoryId": .string("acc-light-a")],
            graph: graph
        )
        try assertDispatchEquivalent(
            unifiedTool: "delete",
            unifiedArguments: ["entityId": .string("trigger-sunset")],
            perTypeTool: "delete_trigger",
            perTypeArguments: ["triggerId": .string("trigger-sunset")],
            graph: graph
        )
    }

    // MARK: - Dispatch equivalence: create

    @Test func createDispatchesToEachPerTypeCreate() throws {
        let graph = fixtureGraph()
        try assertDispatchEquivalent(
            unifiedTool: "create",
            unifiedArguments: ["kind": .string("room"), "homeId": .string("home-1"), "name": .string("Attic")],
            perTypeTool: "create_room",
            perTypeArguments: ["homeId": .string("home-1"), "name": .string("Attic")],
            graph: graph
        )
        try assertDispatchEquivalent(
            unifiedTool: "create",
            unifiedArguments: ["kind": .string("zone"), "homeId": .string("home-1"), "name": .string("Basement")],
            perTypeTool: "create_zone",
            perTypeArguments: ["homeId": .string("home-1"), "name": .string("Basement")],
            graph: graph
        )
        try assertDispatchEquivalent(
            unifiedTool: "create",
            unifiedArguments: [
                "kind": .string("scene"), "homeId": .string("home-1"), "name": .string("Read"),
                "actions": .array([.object([
                    "accessoryId": .string("acc-light-a"),
                    "characteristic": .string("Brightness"),
                    "value": .int(40),
                ])]),
            ],
            perTypeTool: "create_scene",
            perTypeArguments: [
                "homeId": .string("home-1"), "name": .string("Read"),
                "actions": .array([.object([
                    "accessoryId": .string("acc-light-a"),
                    "characteristic": .string("Brightness"),
                    "value": .int(40),
                ])]),
            ],
            graph: graph
        )
        try assertDispatchEquivalent(
            unifiedTool: "create",
            unifiedArguments: [
                "kind": .string("group"), "homeId": .string("home-1"), "name": .string("Sconces"),
                "serviceIds": .array([.string("svc-light-a")]),
            ],
            perTypeTool: "create_service_group",
            perTypeArguments: [
                "homeId": .string("home-1"), "name": .string("Sconces"),
                "serviceIds": .array([.string("svc-light-a")]),
            ],
            graph: graph
        )
        try assertDispatchEquivalent(
            unifiedTool: "create",
            unifiedArguments: [
                "kind": .string("timer"), "homeId": .string("home-1"), "name": .string("Wake Up"),
                "fireDate": .string("2026-11-09T07:30:00Z"),
                "recurrence": .object(["hour": .int(7), "minute": .int(30)]),
                "sceneId": .string("scene-movie"),
            ],
            perTypeTool: "create_timer_trigger",
            perTypeArguments: [
                "homeId": .string("home-1"), "name": .string("Wake Up"),
                "fireDate": .string("2026-11-09T07:30:00Z"),
                "recurrence": .object(["hour": .int(7), "minute": .int(30)]),
                "sceneId": .string("scene-movie"),
            ],
            graph: graph
        )
        let events: MCP.Value = .array([
            .object([
                "accessoryId": .string("acc-light-a"),
                "characteristic": .string("MotionDetected"),
                "value": .bool(true),
            ]),
        ])
        try assertDispatchEquivalent(
            unifiedTool: "create",
            unifiedArguments: [
                "kind": .string("event"), "homeId": .string("home-1"), "name": .string("Motion"),
                "events": events,
            ],
            perTypeTool: "create_event_trigger",
            perTypeArguments: [
                "homeId": .string("home-1"), "name": .string("Motion"),
                "events": events,
            ],
            graph: graph
        )
    }

    // MARK: - Dispatch equivalence: update

    @Test func updateDispatchesToEachPerTypeDeclarativeSet() throws {
        let graph = fixtureGraph()
        try assertDispatchEquivalent(
            unifiedTool: "update",
            unifiedArguments: [
                "entityId": .string("group-desk"),
                "members": .array([.string("svc-light-a"), .string("svc-light-b")]),
            ],
            perTypeTool: "set_service_group_members",
            perTypeArguments: [
                "groupId": .string("group-desk"),
                "serviceIds": .array([.string("svc-light-a"), .string("svc-light-b")]),
            ],
            graph: graph
        )
        try assertDispatchEquivalent(
            unifiedTool: "update",
            unifiedArguments: ["entityId": .string("zone-upstairs"), "rooms": .array([.string("room-kitchen")])],
            perTypeTool: "set_zone_rooms",
            perTypeArguments: ["zoneId": .string("zone-upstairs"), "roomIds": .array([.string("room-kitchen")])],
            graph: graph
        )
        try assertDispatchEquivalent(
            unifiedTool: "update",
            unifiedArguments: [
                "entityId": .string("scene-movie"),
                "actions": .array([.object([
                    "accessoryId": .string("acc-light-b"),
                    "characteristic": .string("On"),
                    "value": .bool(false),
                ])]),
            ],
            perTypeTool: "set_scene_actions",
            perTypeArguments: [
                "sceneId": .string("scene-movie"),
                "actions": .array([.object([
                    "accessoryId": .string("acc-light-b"),
                    "characteristic": .string("On"),
                    "value": .bool(false),
                ])]),
            ],
            graph: graph
        )
        try assertDispatchEquivalent(
            unifiedTool: "update",
            unifiedArguments: [
                "entityId": .string("trigger-motion"),
                "events": .array([.object(["presence": .string("away")])]),
                "executeOnce": .bool(true),
            ],
            perTypeTool: "update_event_trigger",
            perTypeArguments: [
                "triggerId": .string("trigger-motion"),
                "events": .array([.object(["presence": .string("away")])]),
                "executeOnce": .bool(true),
            ],
            graph: graph
        )
    }

    // MARK: - Invariants the unified verbs must not break

    @Test func unifiedCreateStagesDisabledAndArmingStaysSeparate() async throws {
        let (fake, store, registry) = makeContext()

        let staged = try proposal(from: await registry.call(
            name: "create",
            arguments: [
                "kind": .string("timer"), "homeId": .string("home-1"), "name": .string("Wake Up"),
                "fireDate": .string("2026-11-09T07:30:00Z"),
                "sceneId": .string("scene-movie"),
            ]
        ))

        // Same proposal as the per-type tool: staged, DISABLED card, and the
        // separate-arming note.
        #expect(staged.state == .staged)
        #expect(staged.tool == "create_timer_trigger")
        #expect(staged.card.contains { $0.text.contains("DISABLED") })
        #expect(staged.card.contains { $0.kind == .note && $0.text.contains("separate") })

        // Nothing applies at staging — the fixture's two triggers are the
        // only ones in the graph.
        let graphAtStaging = await fake.graph
        #expect(graphAtStaging.homes.first?.triggers.count == 2)

        let approved = try await store.approve(id: staged.id)
        #expect(approved.state == .executed)
        let graph = await fake.graph
        // Find the automation this test created by name: the fixture's two
        // triggers also exist, and both are disabled by fixture default.
        let created = try #require(graph.homes.first?.triggers.first { $0.name == "Wake Up" })
        // The locked rule holds through the unified verb: creation never arms.
        #expect(created.isEnabled == false)
    }

    @Test func unifiedUpdateRefusesTimerTriggersAndNeverAbsorbsArming() async throws {
        let (_, _, registry) = makeContext()

        let result = try await registry.call(
            name: "update",
            arguments: [
                "entityId": .string("trigger-sunset"),
                "events": .array([.object(["presence": .string("atHome")])]),
            ]
        )
        let text = try #require(errorText(of: result))
        #expect(text.contains("set_trigger_state"))
        #expect(text.contains("arming") || text.contains("schedule"))
    }

    @Test func setTriggerStateRemainsRegisteredBesideUnifiedVerbs() {
        let registry = WriteToolRegistry(store: ProposalStore(homeKit: FakeHomeKitService(graph: fixtureGraph()), now: { self.t0 }))
        let names = Set(registry.tools.map(\.name))
        #expect(names.contains("set_trigger_state"))
        // The device-immediate and standalone tools keep their own
        // signatures — no unified verb absorbs them.
        #expect(names.contains("execute_scene"))
        #expect(names.contains("write_characteristic"))
        #expect(names.contains("identify_accessory"))
        #expect(names.contains("unblock_accessory"))
        #expect(names.contains("assign_accessory_to_room"))
        #expect(names.contains("get_proposal"))
    }

    // MARK: - Resolution errors

    @Test func unknownEntityIdNamesSearchAndGetDetails() async throws {
        let (_, _, registry) = makeContext()
        let result = try await registry.call(name: "rename", arguments: [
            "entityId": .string("nope"), "newName": .string("X"),
        ])
        let text = try #require(errorText(of: result))
        #expect(text.contains("Nothing was staged"))
        #expect(text.contains("search or get_details"))
    }

    @Test func renameOnTriggerIsRejected() async throws {
        let (_, _, registry) = makeContext()
        let result = try await registry.call(name: "rename", arguments: [
            "entityId": .string("trigger-sunset"), "newName": .string("Dusk"),
        ])
        let text = try #require(errorText(of: result))
        #expect(text.contains("Triggers cannot be renamed"))
    }

    @Test func unknownCreateKindListsValidKinds() async throws {
        let (fake, _, registry) = makeContext()
        let result = try await registry.call(name: "create", arguments: [
            "kind": .string("castle"), "homeId": .string("home-1"), "name": .string("Nope"),
        ])
        let text = try #require(errorText(of: result))
        #expect(text.contains("room, zone, scene, group, timer, event"))
        let graph = await fake.graph
        #expect(graph.homes.first?.rooms.count == 2)
    }

    @Test func updateOnRoomIsRejected() async throws {
        let (_, _, registry) = makeContext()
        let result = try await registry.call(name: "update", arguments: [
            "entityId": .string("room-kitchen"),
            "actions": .array([]),
        ])
        let text = try #require(errorText(of: result))
        #expect(text.contains("update applies to groups"))
    }

    // MARK: - Staging semantics unchanged

    @Test func unifiedStagesProposalAndAppliesOnlyOnApproval() async throws {
        let (fake, store, registry) = makeContext()

        let staged = try proposal(from: await registry.call(
            name: "rename",
            arguments: ["entityId": .string("room-kitchen"), "newName": .string("Cook Space")]
        ))

        // The unified verb stages under the per-type proposal tool: one
        // pipeline, one review card, nothing applied yet.
        #expect(staged.state == .staged)
        #expect(staged.tool == "rename_room")
        #expect(staged.title.contains("Rename room"))
        let graphAtStaging = await fake.graph
        #expect(graphAtStaging.homes.first?.rooms.first?.name == "Kitchen")

        let denied = try await store.deny(id: staged.id)
        #expect(denied.state == .denied)
        let graphAfterDenial = await fake.graph
        #expect(graphAfterDenial.homes.first?.rooms.first?.name == "Kitchen")
    }

    // MARK: - Surface coherence

    /// The per-type predecessors the Blueprint table names, all of which
    /// must carry the DEPRECATED marker; every other tool must not.
    private static let deprecatedPredecessors: Set<String> = [
        "rename_room", "rename_zone", "rename_scene", "rename_service_group", "rename_accessory",
        "delete_room", "delete_zone", "delete_scene", "delete_service_group", "delete_trigger", "remove_accessory",
        "create_room", "create_zone", "create_scene", "create_service_group",
        "create_timer_trigger", "create_event_trigger",
        "set_service_group_members", "set_zone_rooms", "set_scene_actions", "update_event_trigger",
    ]

    @Test func everyToolHasDescriptionAndOnlyPredecessorsAreDeprecated() {
        let registry = WriteToolRegistry(store: ProposalStore(homeKit: FakeHomeKitService(graph: fixtureGraph()), now: { self.t0 }))
        let byName = Dictionary(uniqueKeysWithValues: registry.tools.map { ($0.name, $0) })

        // The four unified verbs are registered exactly once each.
        for name in ["rename", "delete", "create", "update"] {
            #expect(byName[name] != nil)
        }

        // Surface coherence: every tool ships plain-language text, and the
        // DEPRECATED marker sits on exactly the per-type predecessors.
        for tool in registry.tools {
            #expect(tool.description?.isEmpty == false)
            let deprecated = tool.description?.contains("DEPRECATED") == true
            #expect(deprecated == Self.deprecatedPredecessors.contains(tool.name))
        }

        // A unified verb's own description never carries the marker.
        #expect(byName["rename"]?.description?.contains("DEPRECATED") == false)
    }

    @Test func agentSurfaceStaysAtTheV9EightTools() async {
        let fake = FakeHomeKitService(graph: fixtureGraph())
        let toolset = NilesToolDispatcher(
            reads: ReadToolRegistry(service: fake),
            writes: WriteToolRegistry(store: ProposalStore(homeKit: fake, now: { self.t0 }))
        )
        let names = await toolset.agentToolDefinitions.map(\.name)
        #expect(names == NilesToolDispatcher.agentToolOrder)
        #expect(names.count == 8)
    }
}
