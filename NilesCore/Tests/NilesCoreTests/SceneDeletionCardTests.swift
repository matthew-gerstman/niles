import Foundation
import Testing
@testable import NilesCore

/// Scene-deletion staging (Matthew, 2026-11-13): the card must NOT list the
/// scene's saved actions as change rows — they are the scene's content
/// (what it did when it ran), not an effect of the deletion — while the
/// destructive-reference warnings and the immediate-stop explainer stay.
/// Also pins the destructive classification for every destructive operation
/// type: the Queue/Activity rows key the red trash-can icon off it.
///
/// Follows the PR #15 validation-test pattern: pure fixtures over
/// `HomeGraph`, planner output asserted directly.
@Suite struct SceneDeletionCardTests {

    // MARK: - Fixtures

    private func fixtureGraph(
        sceneActions: [HomeGraph.SceneAction] = [], inHome homeName: String = "Townhouse"
    ) -> HomeGraph {
        let powerState = HomeGraph.CharacteristicRef(
            id: "char-power",
            type: "00000025-0000-1000-8000-0026BB765291",
            name: "Power State",
            valueDescription: "1"
        )
        let lampService = HomeGraph.AccessoryService(
            id: "svc-light", name: "Lightbulb",
            serviceType: "00000043-0000-1000-8000-0026BB765291",
            characteristics: [powerState]
        )
        let lamp = HomeGraph.Accessory(
            id: "acc-lamp", name: "Living Room Accent Lights", reachable: true,
            bridged: false, category: "com.apple.hap.lightbulb", services: [lampService]
        )
        let living = HomeGraph.Room(id: "room-living", name: "Living Room", accessories: [lamp])
        var home = HomeGraph.Home(id: "home-1", name: homeName, rooms: [living])
        home.zones = [HomeGraph.Zone(id: "zone-upstairs", name: "Upstairs", roomIds: ["room-living"])]
        home.scenes = [
            HomeGraph.Scene(
                id: "scene-qa", name: "QA Design Round 2",
                actions: sceneActions.isEmpty ? [
                    HomeGraph.SceneAction(
                        accessoryId: "acc-lamp", accessoryName: "Living Room Accent Lights",
                        service: nil, characteristic: "00000025-0000-1000-8000-0026BB765291",
                        characteristicName: "Power State", valueDescription: "1"
                    ),
                ] : sceneActions
            ),
        ]
        home.triggers = [
            HomeGraph.Trigger(
                id: "trigger-evening", name: "Evening", isEnabled: true,
                linkedSceneIds: ["scene-qa"],
                detail: .timer(fireDate: Date(timeIntervalSince1970: 0), recurrence: [:])
            ),
        ]
        home.serviceGroups = [
            HomeGraph.ServiceGroup(
                id: "group-lights", name: "Lights",
                services: [HomeGraph.ServiceRef(
                    id: "svc-light", name: "Lightbulb", serviceType: nil,
                    accessoryId: "acc-lamp", accessoryName: "Living Room Accent Lights"
                )]
            ),
        ]
        return HomeGraph(homes: [home])
    }

    private func stagedDeletion(deleteLinkedTriggers: Bool) throws -> Plan {
        try ProposalPlanner.plan(
            .deleteScene(sceneId: "scene-qa", deleteLinkedTriggers: deleteLinkedTriggers),
            graph: fixtureGraph()
        )
    }

    // MARK: - Scene-deletion card contents

    @Test func deletionCardHasNoSceneActionRows() throws {
        let plan = try stagedDeletion(deleteLinkedTriggers: false)
        // The one action ("Living Room Accent Lights: Power State → 1" in the
        // rendered card) is scene content — none of it may appear.
        #expect(!plan.card.isEmpty)
        #expect(!plan.card.contains { $0.text.contains("Power State") })
        #expect(!plan.card.contains { $0.text.contains("no actions") })
    }

    @Test func deletionCardKeepsTheExplainer() throws {
        let plan = try stagedDeletion(deleteLinkedTriggers: false)
        #expect(plan.card.contains {
            $0.text == "The scene stops working immediately — visible to the Home app and Siri."
        })
    }

    @Test func deletionCardKeepsTheDanglingTriggerWarning() throws {
        // deleteLinkedTriggers = false: the trigger keeps pointing at a gone
        // scene — the one warning that IS relevant.
        let plan = try stagedDeletion(deleteLinkedTriggers: false)
        #expect(plan.card.contains { $0.text.contains("Trigger “Evening” no longer runs anything") })
    }

    @Test func deletionCardKeepsTheDeletedTriggerLine() throws {
        // deleteLinkedTriggers = true: the trigger is deleted too — a real
        // effect of the deletion, listed.
        let plan = try stagedDeletion(deleteLinkedTriggers: true)
        #expect(plan.card.contains { $0.text.contains("Trigger “Evening” · deleted too") })
        #expect(!plan.card.contains { $0.text.contains("Power State") })
    }

    // MARK: - Destructive classification (the row icon's key)

    /// Every destructive operation type classifies destructive — Queue and
    /// Activity rows render the red trash can off this flag, never a name
    /// match. One operation type per case.
    @Test func destructiveOperationTypesClassifyDestructive() throws {
        #expect(try stagedDeletion(deleteLinkedTriggers: false).isDestructive)
        #expect(try ProposalPlanner.plan(
            .deleteTrigger(triggerId: "trigger-evening"), graph: fixtureGraph()
        ).isDestructive)
        #expect(try ProposalPlanner.plan(
            .deleteZone(zoneId: "zone-upstairs"), graph: fixtureGraph()
        ).isDestructive)
        #expect(try ProposalPlanner.plan(
            .deleteServiceGroup(groupId: "group-lights"), graph: fixtureGraph()
        ).isDestructive)
        #expect(try ProposalPlanner.plan(
            .removeAccessory(accessoryId: "acc-lamp"), graph: fixtureGraph()
        ).isDestructive)
        // delete_room needs an empty room (the fixture's living room holds
        // the lamp), so it gets its own empty room.
        let guestRoom = HomeGraph.Room(id: "room-guest", name: "Guest Room", accessories: [])
        var graph = fixtureGraph()
        graph.homes[0].rooms.append(guestRoom)
        #expect(try ProposalPlanner.plan(
            .deleteRoom(roomId: "room-guest"), graph: graph
        ).isDestructive)
    }
}
