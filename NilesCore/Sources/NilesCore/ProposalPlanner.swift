import Foundation

/// Pure planning: one typed write request + the current graph -> the minimal
/// HomeKit operations and the full review card. No side effects; every
/// rejection throws `PlannerError` before a proposal exists, so the human
/// never sees a card that is guaranteed to fail (spec: eager validation).
public enum ProposalPlanner {

    public enum PlannerError: Error, Equatable, Sendable {
        case unknownHome(String)
        case unknownRoom(String)
        case unknownZone(String)
        case unknownScene(String)
        case unknownServiceGroup(String)
        case unknownTrigger(String)
        case unknownAccessory(id: String, home: String)
        case unknownService(String)
        case unknownServiceOnAccessory(accessory: String, service: String)
        case unsupportedCharacteristic(accessory: String, characteristic: String)
        case duplicateName(kind: String, name: String, home: String)
        case invalidInput(String)
        case noChange(String)
        case validationFailed([String])

        /// Agent-readable text; the tool layer surfaces it in-band.
        public var message: String {
            switch self {
            case .unknownHome(let id):
                "No home with id \(id). Call get_homes first."
            case .unknownRoom(let id):
                "No room with id \(id). Call get_rooms first."
            case .unknownZone(let id):
                "No zone with id \(id). Call get_zones first."
            case .unknownScene(let id):
                "No scene with id \(id). Call get_scenes first."
            case .unknownServiceGroup(let id):
                "No service group with id \(id). Call get_service_groups first."
            case .unknownTrigger(let id):
                "No trigger with id \(id). Call get_triggers first."
            case .unknownAccessory(let id, let home):
                "No accessory with id \(id) in home “\(home)”."
            case .unknownService(let id):
                "No service with id \(id) visible in the home graph; service ids come from get_service_groups."
            case .unknownServiceOnAccessory(let accessory, let service):
                "Accessory “\(accessory)” has no service “\(service)”. Check the accessory's services with get_rooms."
            case .unsupportedCharacteristic(let accessory, let characteristic):
                "Accessory “\(accessory)” has no service with characteristic \(characteristic). "
                    + "Check the accessory's supported characteristics with get_rooms."
            case .duplicateName(let kind, let name, let home):
                "A \(kind) named “\(name)” already exists in “\(home)”."
            case .invalidInput(let detail):
                detail
            case .noChange(let detail):
                "Nothing to change: \(detail)"
            case .validationFailed(let messages):
                messages.joined(separator: " ")
            }
        }
    }

    public static func plan(_ request: WriteRequest, graph: HomeGraph) throws -> Plan {
        switch request {
        case .createRoom(let homeId, let name):
            return try createRoom(homeId: homeId, name: name, graph: graph)
        case .renameRoom(let roomId, let name):
            return try renameRoom(roomId: roomId, name: name, graph: graph)
        case .deleteRoom(let roomId):
            return try deleteRoom(roomId: roomId, graph: graph)
        case .setZoneRooms(let zoneId, let roomIds):
            return try setZoneRooms(zoneId: zoneId, roomIds: roomIds, graph: graph)
        case .createZone(let homeId, let name):
            return try createZone(homeId: homeId, name: name, graph: graph)
        case .renameZone(let zoneId, let name):
            return try renameZone(zoneId: zoneId, name: name, graph: graph)
        case .deleteZone(let zoneId):
            return try deleteZone(zoneId: zoneId, graph: graph)
        case .createScene(let homeId, let name, let actions):
            return try createScene(homeId: homeId, name: name, actions: actions, graph: graph)
        case .setSceneActions(let sceneId, let actions):
            return try setSceneActions(sceneId: sceneId, actions: actions, graph: graph)
        case .renameScene(let sceneId, let name):
            return try renameScene(sceneId: sceneId, name: name, graph: graph)
        case .deleteScene(let sceneId, let deleteLinkedTriggers):
            return try deleteScene(sceneId: sceneId, deleteLinkedTriggers: deleteLinkedTriggers, graph: graph)
        case .executeScene(let sceneId):
            return try executeScene(sceneId: sceneId, graph: graph)
        case .createServiceGroup(let homeId, let name):
            return try createServiceGroup(homeId: homeId, name: name, graph: graph)
        case .renameServiceGroup(let groupId, let name):
            return try renameServiceGroup(groupId: groupId, name: name, graph: graph)
        case .setServiceGroupMembers(let groupId, let serviceIds):
            return try setServiceGroupMembers(groupId: groupId, serviceIds: serviceIds, graph: graph)
        case .deleteServiceGroup(let groupId):
            return try deleteServiceGroup(groupId: groupId, graph: graph)
        case .createTimerTrigger(let homeId, let name, let fireDate, let recurrence, let sceneId):
            return try createTimerTrigger(
                homeId: homeId, name: name, fireDate: fireDate, recurrence: recurrence ?? [:],
                sceneId: sceneId, graph: graph
            )
        case .createEventTrigger(let homeId, let name, let events, let endEvents, let executeOnce, let sceneId):
            return try createEventTrigger(
                homeId: homeId, name: name, events: events, endEvents: endEvents,
                executeOnce: executeOnce, sceneId: sceneId, graph: graph
            )
        case .updateEventTrigger(
            let triggerId, let events, let endEvents, let recurrences, let executeOnce, let sceneId
        ):
            return try updateEventTrigger(
                triggerId: triggerId, events: events, endEvents: endEvents,
                recurrences: recurrences, executeOnce: executeOnce, sceneId: sceneId, graph: graph
            )
        case .setTriggerState(let triggerId, let enabled, let fireDate, let recurrence):
            return try setTriggerState(
                triggerId: triggerId, enabled: enabled, fireDate: fireDate,
                recurrence: recurrence, graph: graph
            )
        case .deleteTrigger(let triggerId):
            return try deleteTrigger(triggerId: triggerId, graph: graph)
        case .renameAccessory(let accessoryId, let name):
            return try renameAccessory(accessoryId: accessoryId, name: name, graph: graph)
        case .identifyAccessory(let accessoryId):
            return try identifyAccessory(accessoryId: accessoryId, graph: graph)
        case .assignAccessoryToRoom(let accessoryId, let roomId):
            return try assignAccessoryToRoom(accessoryId: accessoryId, roomId: roomId, graph: graph)
        case .unblockAccessory(let accessoryId):
            return try unblockAccessory(accessoryId: accessoryId, graph: graph)
        case .removeAccessory(let accessoryId):
            return try removeAccessory(accessoryId: accessoryId, graph: graph)
        case .writeCharacteristic(let accessoryId, let service, let characteristic, let value):
            return try writeCharacteristic(
                accessoryId: accessoryId, service: service, characteristic: characteristic,
                value: value, graph: graph
            )
        }
    }

    /// The default planning function the proposal store composes: parse the
    /// MCP arguments, then plan against the graph.
    public static var planFunction: ProposalStore.PlanFunction {
        { tool, arguments, graph in
            try plan(WriteRequest.parse(tool: tool, arguments: arguments), graph: graph)
        }
    }

    // MARK: - Rooms

    private static func createRoom(homeId: String, name: String, graph: HomeGraph) throws -> Plan {
        let trimmed = try requiredHomeKitName(name, kind: "room")
        let home = try self.home(id: homeId, in: graph)
        try rejectDuplicate(kind: "room", name: trimmed, in: home.rooms.map(\.name), homeName: home.name)
        return Plan(
            tool: "create_room",
            title: "Create room “\(trimmed)”",
            summary: "Create room “\(trimmed)” in “\(home.name)”",
            isDestructive: false,
            operations: [.addRoom(homeId: home.id, name: trimmed)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .room, id: "", name: trimmed),
                op: .create,
                before: nil,
                after: trimmed
            )],
            card: [ProposalCardLine(.add, "Room “\(trimmed)” · created")]
        )
    }

    private static func renameRoom(roomId: String, name: String, graph: HomeGraph) throws -> Plan {
        let trimmed = try requiredHomeKitName(name, kind: "room")
        let (home, room) = try self.room(id: roomId, in: graph)
        if room.name == trimmed {
            throw PlannerError.noChange("room “\(room.name)” is already named “\(trimmed)”.")
        }
        return Plan(
            tool: "rename_room",
            title: "Rename room “\(room.name)”",
            summary: "Rename room “\(room.name)” to “\(trimmed)”",
            isDestructive: false,
            operations: [.renameRoom(homeId: home.id, roomId: room.id, to: trimmed)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .room, id: room.id, name: room.name),
                op: .rename,
                before: room.name,
                after: trimmed
            )],
            card: [ProposalCardLine(.plain, "Room “\(room.name)” → “\(trimmed)”")]
        )
    }

    private static func deleteRoom(roomId: String, graph: HomeGraph) throws -> Plan {
        let (home, room) = try self.room(id: roomId, in: graph)
        let displaced = room.accessories.count

        var card: [ProposalCardLine] = [ProposalCardLine(.remove, "Room “\(room.name)” · deleted")]
        if displaced > 0 {
            // Spec risk (shared-database blast radius): HomeKit reassigns the
            // deleted room's accessories to the default room. The card says so.
            let noun = displaced == 1 ? "accessory" : "accessories"
            card.append(ProposalCardLine(.note, "⚠ \(displaced) \(noun) will move to the default room"))
        }
        card.append(ProposalCardLine(
            .plain,
            "Visible immediately to Siri, the Home app, and every automation that references this room."
        ))

        return Plan(
            tool: "delete_room",
            title: "Delete room “\(room.name)”",
            summary: "Delete room “\(room.name)”",
            isDestructive: true,
            operations: [.removeRoom(homeId: home.id, roomId: room.id)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .room, id: room.id, name: room.name),
                op: .delete,
                before: room.name,
                after: nil
            )],
            card: card
        )
    }

    // MARK: - Zones

    private static func setZoneRooms(zoneId: String, roomIds: [String], graph: HomeGraph) throws -> Plan {
        let (home, zone) = try self.zone(id: zoneId, in: graph)

        // Deduplicate while preserving the agent's order.
        var seen = Set<String>()
        let target: [String] = roomIds.filter { seen.insert($0).inserted }
        for roomId in target where !home.rooms.contains(where: { $0.id == roomId }) {
            throw PlannerError.unknownRoom(roomId)
        }

        let current = zone.roomIds
        let additions = target.filter { !current.contains($0) }
        let removals = current.filter { !target.contains($0) }
        if additions.isEmpty && removals.isEmpty {
            throw PlannerError.noChange("zone “\(zone.name)” already contains exactly these rooms.")
        }

        let zoneRef = ProposalObjectRef(kind: .zone, id: zone.id, name: zone.name)
        let entries: [ProposalDiffEntry] =
            additions.map { roomId in
                ProposalDiffEntry(
                    object: zoneRef, op: .addMembers,
                    before: nil, after: Self.room(id: roomId, in: home)?.name ?? roomId
                )
            }
            + removals.map { roomId in
                ProposalDiffEntry(
                    object: zoneRef, op: .removeMembers,
                    before: Self.room(id: roomId, in: home)?.name ?? roomId, after: nil
                )
            }

        var card: [ProposalCardLine] =
            additions.map { roomId in
                ProposalCardLine(.add, "“\(zone.name)” · add room “\(Self.room(id: roomId, in: home)?.name ?? roomId)”")
            }
            + removals.map { roomId in
                ProposalCardLine(.remove, "“\(zone.name)” · remove room “\(Self.room(id: roomId, in: home)?.name ?? roomId)”")
            }
        // The spec's worked example: agents re-send the full membership, and
        // the card must show that the other rooms simply stay.
        if removals.isEmpty {
            let staying = current.filter { !additions.contains($0) }.compactMap { Self.room(id: $0, in: home)?.name }
            if !staying.isEmpty {
                let names = staying.joined(separator: ", ")
                let verb = staying.count == 1 ? "stays" : "stay"
                card.append(ProposalCardLine(.plain, "No rooms removed — \(names) \(verb)."))
            }
        }

        return Plan(
            tool: "set_zone_rooms",
            title: Self.zoneTitle(zoneName: zone.name, additions: additions, removals: removals, home: home),
            summary: Self.zoneSummary(
                zoneName: zone.name, additions: additions, removals: removals, home: home
            ),
            isDestructive: false,
            operations: [.setZoneRooms(homeId: home.id, zoneId: zone.id, addRoomIds: additions, removeRoomIds: removals)],
            entries: entries,
            card: card
        )
    }

    private static func zoneTitle(zoneName: String, additions: [String], removals: [String], home: HomeGraph.Home) -> String {
        if additions.count == 1, removals.isEmpty {
            return "Move \(roomName(id: additions[0], home: home)) into \(zoneName)"
        }
        if removals.count == 1, additions.isEmpty {
            return "Remove \(roomName(id: removals[0], home: home)) from \(zoneName)"
        }
        return "Update zone “\(zoneName)”"
    }

    private static func zoneSummary(zoneName: String, additions: [String], removals: [String], home: HomeGraph.Home) -> String {
        if additions.count == 1, removals.isEmpty {
            return "Add room “\(roomName(id: additions[0], home: home))” to zone “\(zoneName)”"
        }
        if removals.count == 1, additions.isEmpty {
            return "Remove room “\(roomName(id: removals[0], home: home))” from zone “\(zoneName)”"
        }
        return "Update zone “\(zoneName)” membership (\(additions.count) added, \(removals.count) removed)"
    }

    private static func createZone(homeId: String, name: String, graph: HomeGraph) throws -> Plan {
        let trimmed = try requiredHomeKitName(name, kind: "zone")
        let home = try self.home(id: homeId, in: graph)
        try rejectDuplicate(kind: "zone", name: trimmed, in: home.zones.map(\.name), homeName: home.name)
        return Plan(
            tool: "create_zone",
            title: "Create zone “\(trimmed)”",
            summary: "Create zone “\(trimmed)” in “\(home.name)”",
            isDestructive: false,
            operations: [.createZone(homeId: home.id, name: trimmed)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .zone, id: "", name: trimmed),
                op: .create,
                before: nil,
                after: trimmed
            )],
            card: [ProposalCardLine(.add, "Zone “\(trimmed)” · created (empty — add rooms with set_zone_rooms)")]
        )
    }

    private static func renameZone(zoneId: String, name: String, graph: HomeGraph) throws -> Plan {
        let trimmed = try requiredHomeKitName(name, kind: "zone")
        let (home, zone) = try self.zone(id: zoneId, in: graph)
        if zone.name.caseInsensitiveCompare(trimmed) == .orderedSame {
            throw PlannerError.noChange("zone “\(zone.name)” is already named “\(trimmed)”.")
        }
        // Zone names are unique within a home; the new name cannot collide
        // with another zone — this one included.
        let otherZones = home.zones.filter { $0.id != zone.id }
        try rejectDuplicate(kind: "zone", name: trimmed, in: otherZones.map(\.name), homeName: home.name)
        return Plan(
            tool: "rename_zone",
            title: "Rename zone “\(zone.name)”",
            summary: "Rename zone “\(zone.name)” to “\(trimmed)”",
            isDestructive: false,
            operations: [.renameZone(homeId: home.id, zoneId: zone.id, to: trimmed)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .zone, id: zone.id, name: zone.name),
                op: .rename,
                before: zone.name,
                after: trimmed
            )],
            card: [ProposalCardLine(.plain, "Zone “\(zone.name)” → “\(trimmed)”")]
        )
    }

    /// Spec (destructive severity): the card shows how many rooms the zone
    /// grouped, and states plainly that the rooms survive — removing a zone
    /// dissolves only the grouping, never the rooms.
    private static func deleteZone(zoneId: String, graph: HomeGraph) throws -> Plan {
        let (home, zone) = try self.zone(id: zoneId, in: graph)
        let memberNames = zone.roomIds.compactMap { room(id: $0, in: home)?.name }

        var card: [ProposalCardLine] = [ProposalCardLine(.remove, "Zone “\(zone.name)” · deleted")]
        if memberNames.isEmpty {
            card.append(ProposalCardLine(.plain, "The zone has no rooms."))
        } else {
            let roomNoun = memberNames.count == 1 ? "room" : "rooms"
            card.append(ProposalCardLine(
                .plain,
                "It grouped \(memberNames.count) \(roomNoun): \(memberNames.joined(separator: ", "))."
            ))
        }
        card.append(ProposalCardLine(
            .plain,
            "The rooms survive untouched — deleting a zone removes only the grouping."
        ))

        return Plan(
            tool: "delete_zone",
            title: "Delete zone “\(zone.name)”",
            summary: "Delete zone “\(zone.name)”",
            isDestructive: true,
            operations: [.removeZone(homeId: home.id, zoneId: zone.id)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .zone, id: zone.id, name: zone.name),
                op: .delete,
                before: zone.name,
                after: nil
            )],
            card: card
        )
    }

    // MARK: - Scenes

    private static func createScene(homeId: String, name: String, actions: [SceneActionSpec], graph: HomeGraph) throws -> Plan {
        let trimmed = try requiredHomeKitName(name, kind: "scene")
        let home = try self.home(id: homeId, in: graph)
        try rejectDuplicate(kind: "scene", name: trimmed, in: home.scenes.map(\.name), homeName: home.name)
        let capabilityNotes = try validate(accessories: actions, home: home)

        let actionNoun = actions.count == 1 ? "action" : "actions"
        var card: [ProposalCardLine] = [
            ProposalCardLine(.add, "Scene “\(trimmed)” · created with \(actions.count) \(actionNoun)")
        ]
        card += actions.map { ProposalCardLine(.add, describe(spec: $0, home: home)) }
        card += capabilityNotes
        // Scope note: the card preempts the "did it run?" question —
        // running the scene is a separate approval (execute_scene).
        card.append(ProposalCardLine(.note, "⚠ To run this scene later, use execute_scene after approval."))

        return Plan(
            tool: "create_scene",
            title: "Create scene “\(trimmed)”",
            summary: "Create scene “\(trimmed)” with \(actions.count) \(actionNoun)",
            isDestructive: false,
            operations: [.addActionSet(homeId: home.id, name: trimmed, actions: actions)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .scene, id: "", name: trimmed),
                op: .create,
                before: nil,
                after: "\(actions.count) \(actionNoun)"
            )],
            card: card
        )
    }

    private static func setSceneActions(sceneId: String, actions: [SceneActionSpec], graph: HomeGraph) throws -> Plan {
        let (home, scene) = try self.scene(id: sceneId, in: graph)
        let capabilityNotes = try validate(accessories: actions, home: home)

        let currentKeys = scene.actions.map(SceneActionKey.init(action:))
        let targetKeys = actions.map(SceneActionKey.init(spec:))
        let additions = actions.filter { spec in !currentKeys.contains(SceneActionKey(spec: spec)) }
        let removals = scene.actions.filter { action in !targetKeys.contains(SceneActionKey(action: action)) }
        if additions.isEmpty && removals.isEmpty {
            throw PlannerError.noChange("scene “\(scene.name)” already has exactly these actions.")
        }

        let sceneRef = ProposalObjectRef(kind: .scene, id: scene.id, name: scene.name)
        let entries: [ProposalDiffEntry] =
            removals.map { action in
                ProposalDiffEntry(
                    object: sceneRef, op: .removeMembers,
                    before: describe(action: action, home: home), after: nil
                )
            }
            + additions.map { spec in
                ProposalDiffEntry(
                    object: sceneRef, op: .addMembers,
                    before: nil, after: describe(spec: spec, home: home)
                )
            }

        var card: [ProposalCardLine] =
            removals.map { action in
                ProposalCardLine(.remove, "“\(scene.name)” · remove action \(describe(action: action, home: home))")
            }
            + additions.map { spec in
                ProposalCardLine(.add, "“\(scene.name)” · add action \(describe(spec: spec, home: home))")
            }
        let unchanged = scene.actions.count - removals.count
        if unchanged > 0 {
            let noun = unchanged == 1 ? "action" : "actions"
            card.append(ProposalCardLine(.plain, "\(unchanged) existing \(noun) unchanged."))
        }
        card += capabilityNotes

        return Plan(
            tool: "set_scene_actions",
            title: "Update scene “\(scene.name)”",
            summary: "Update scene “\(scene.name)” actions (\(additions.count) added, \(removals.count) removed)",
            isDestructive: false,
            operations: [.setSceneActions(
                homeId: home.id, sceneId: scene.id,
                add: additions, remove: removals.map(SceneActionKey.init(action:))
            )],
            entries: entries,
            card: card
        )
    }

    private static func renameScene(sceneId: String, name: String, graph: HomeGraph) throws -> Plan {
        let trimmed = try requiredHomeKitName(name, kind: "scene")
        let (home, scene) = try self.scene(id: sceneId, in: graph)
        if scene.name.caseInsensitiveCompare(trimmed) == .orderedSame {
            throw PlannerError.noChange("scene “\(scene.name)” is already named “\(trimmed)”.")
        }
        // Scene names are unique across all homes (HomeKit's rule); the new
        // name cannot collide with another scene — this one included.
        let otherScenes = graph.homes.flatMap(\.scenes).filter { $0.id != scene.id }
        try rejectDuplicate(kind: "scene", name: trimmed, in: otherScenes.map(\.name), homeName: home.name)
        return Plan(
            tool: "rename_scene",
            title: "Rename scene “\(scene.name)”",
            summary: "Rename scene “\(scene.name)” to “\(trimmed)”",
            isDestructive: false,
            operations: [.renameActionSet(homeId: home.id, sceneId: scene.id, to: trimmed)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .scene, id: scene.id, name: scene.name),
                op: .rename,
                before: scene.name,
                after: trimmed
            )],
            card: [ProposalCardLine(.plain, "Scene “\(scene.name)” → “\(trimmed)”")]
        )
    }

    /// Spec (destructive staging): the card lists the scene's current actions
    /// and every trigger that links it — a dangling automation is the silent
    /// blast radius of a scene delete. The `deleteLinkedTriggers` flag is the
    /// spec's “delete trigger too / keep trigger” offer, and the card says
    /// which way it goes.
    private static func deleteScene(
        sceneId: String, deleteLinkedTriggers: Bool, graph: HomeGraph
    ) throws -> Plan {
        let (home, scene) = try self.scene(id: sceneId, in: graph)
        let linked = home.triggers.filter { $0.linkedSceneIds.contains(scene.id) }

        var operations: [HomeKitOperation] = [.removeActionSet(homeId: home.id, sceneId: scene.id)]
        if deleteLinkedTriggers {
            operations += linked.map { .removeTrigger(homeId: home.id, triggerId: $0.id) }
        }

        var card: [ProposalCardLine] = [ProposalCardLine(.remove, "Scene “\(scene.name)” · deleted")]
        if scene.actions.isEmpty {
            card.append(ProposalCardLine(.plain, "The scene has no actions."))
        } else {
            card += scene.actions.map { ProposalCardLine(.remove, describe(action: $0, home: home)) }
        }
        for trigger in linked {
            if deleteLinkedTriggers {
                card.append(ProposalCardLine(.remove, "Trigger “\(trigger.name)” · deleted too — it runs this scene"))
            } else {
                card.append(ProposalCardLine(
                    .note,
                    "⚠ Trigger “\(trigger.name)” no longer runs anything — its scene is gone. Pass deleteLinkedTriggers to delete it too."
                ))
            }
        }
        card.append(ProposalCardLine(
            .plain,
            "The scene stops working immediately — visible to the Home app and Siri."
        ))

        let entries: [ProposalDiffEntry] = [ProposalDiffEntry(
            object: ProposalObjectRef(kind: .scene, id: scene.id, name: scene.name),
            op: .delete,
            before: scene.name,
            after: nil
        )] + (deleteLinkedTriggers ? linked.map { trigger in
            ProposalDiffEntry(
                object: ProposalObjectRef(kind: .trigger, id: trigger.id, name: trigger.name),
                op: .delete,
                before: trigger.name,
                after: nil
            )
        } : [])

        let triggerNoun = linked.count == 1 ? "1 trigger" : "\(linked.count) triggers"
        let title = deleteLinkedTriggers && !linked.isEmpty
            ? "Delete scene “\(scene.name)” and \(triggerNoun)"
            : "Delete scene “\(scene.name)”"
        return Plan(
            tool: "delete_scene",
            title: title,
            summary: "Delete scene “\(scene.name)”" + (deleteLinkedTriggers && !linked.isEmpty ? " with \(triggerNoun)" : ""),
            isDestructive: true,
            operations: operations,
            entries: entries,
            card: card
        )
    }

    private static func executeScene(sceneId: String, graph: HomeGraph) throws -> Plan {
        let (home, scene) = try self.scene(id: sceneId, in: graph)
        if scene.actions.isEmpty {
            throw PlannerError.invalidInput(
                "Scene “\(scene.name)” has no actions — HomeKit refuses to execute an empty scene."
            )
        }
        let actionNoun = scene.actions.count == 1 ? "action" : "actions"
        var card: [ProposalCardLine] = [
            ProposalCardLine(.add, "Scene “\(scene.name)” · runs on approval")
        ]
        card += scene.actions.map { ProposalCardLine(.plain, describe(action: $0, home: home)) }
        card.append(ProposalCardLine(
            .note,
            "⚠ Device-immediate — every action above applies to the devices the moment this is approved."
        ))
        return Plan(
            tool: "execute_scene",
            title: "Run scene “\(scene.name)”",
            summary: "Run scene “\(scene.name)” now (\(scene.actions.count) \(actionNoun))",
            isDestructive: false,
            operations: [.executeActionSet(homeId: home.id, sceneId: scene.id)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .scene, id: scene.id, name: scene.name),
                op: .update,
                before: "not running",
                after: "runs on approval"
            )],
            card: card
        )
    }

    // MARK: - Service groups

    private static func createServiceGroup(homeId: String, name: String, graph: HomeGraph) throws -> Plan {
        let trimmed = try requiredHomeKitName(name, kind: "service group")
        let home = try self.home(id: homeId, in: graph)
        try rejectDuplicate(kind: "service group", name: trimmed, in: home.serviceGroups.map(\.name), homeName: home.name)
        return Plan(
            tool: "create_service_group",
            title: "Create service group “\(trimmed)”",
            summary: "Create service group “\(trimmed)” in “\(home.name)”",
            isDestructive: false,
            operations: [.addServiceGroup(homeId: home.id, name: trimmed)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .serviceGroup, id: "", name: trimmed),
                op: .create,
                before: nil,
                after: trimmed
            )],
            card: [ProposalCardLine(.add, "Service group “\(trimmed)” · created")]
        )
    }

    private static func renameServiceGroup(groupId: String, name: String, graph: HomeGraph) throws -> Plan {
        let trimmed = try requiredHomeKitName(name, kind: "service group")
        let (home, group) = try self.serviceGroup(id: groupId, in: graph)
        if group.name.caseInsensitiveCompare(trimmed) == .orderedSame {
            throw PlannerError.noChange("service group “\(group.name)” is already named “\(trimmed)”.")
        }
        // Group names are unique within a home; the new name cannot collide
        // with another group — this one included.
        let otherGroups = home.serviceGroups.filter { $0.id != group.id }
        try rejectDuplicate(kind: "service group", name: trimmed, in: otherGroups.map(\.name), homeName: home.name)
        return Plan(
            tool: "rename_service_group",
            title: "Rename service group “\(group.name)”",
            summary: "Rename service group “\(group.name)” to “\(trimmed)”",
            isDestructive: false,
            operations: [.renameServiceGroup(homeId: home.id, groupId: group.id, to: trimmed)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .serviceGroup, id: group.id, name: group.name),
                op: .rename,
                before: group.name,
                after: trimmed
            )],
            card: [ProposalCardLine(.plain, "Service group “\(group.name)” → “\(trimmed)”")]
        )
    }

    private static func setServiceGroupMembers(groupId: String, serviceIds: [String], graph: HomeGraph) throws -> Plan {
        let (home, group) = try self.serviceGroup(id: groupId, in: graph)

        // The graph only exposes services through groups, so validate against
        // every ServiceRef in the home. The real adapter resolves any
        // HMService; the fake's vocabulary is group-visible services.
        let known = Dictionary(
            home.serviceGroups.flatMap(\.services).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var failures: [String] = []
        for serviceId in serviceIds where known[serviceId] == nil {
            failures.append("Service \(serviceId): \(PlannerError.unknownService(serviceId).message)")
        }
        if !failures.isEmpty {
            throw PlannerError.validationFailed(failures)
        }

        var seen = Set<String>()
        let target = serviceIds.filter { seen.insert($0).inserted }
        let current = group.services.map(\.id)
        let additions = target.filter { !current.contains($0) }
        let removals = current.filter { !target.contains($0) }
        if additions.isEmpty && removals.isEmpty {
            throw PlannerError.noChange("service group “\(group.name)” already has exactly these members.")
        }

        let groupRef = ProposalObjectRef(kind: .serviceGroup, id: group.id, name: group.name)
        let entries: [ProposalDiffEntry] =
            additions.map { serviceId in
                ProposalDiffEntry(
                    object: groupRef, op: .addMembers,
                    before: nil, after: known[serviceId]?.name ?? serviceId
                )
            }
            + removals.map { serviceId in
                ProposalDiffEntry(
                    object: groupRef, op: .removeMembers,
                    before: known[serviceId]?.name ?? serviceId, after: nil
                )
            }

        var card: [ProposalCardLine] =
            additions.map { serviceId in
                ProposalCardLine(.add, "“\(group.name)” · add service “\(known[serviceId]?.name ?? serviceId)”")
            }
            + removals.map { serviceId in
                ProposalCardLine(.remove, "“\(group.name)” · remove service “\(known[serviceId]?.name ?? serviceId)”")
            }
        let unchanged = current.count - removals.count
        if unchanged > 0 {
            let noun = unchanged == 1 ? "member" : "members"
            card.append(ProposalCardLine(.plain, "\(unchanged) existing \(noun) unchanged."))
        }

        return Plan(
            tool: "set_service_group_members",
            title: "Update service group “\(group.name)”",
            summary: "Update service group “\(group.name)” members (\(additions.count) added, \(removals.count) removed)",
            isDestructive: false,
            operations: [.setServiceGroupMembers(
                homeId: home.id, groupId: group.id,
                addServiceIds: additions, removeServiceIds: removals
            )],
            entries: entries,
            card: card
        )
    }

    private static func deleteServiceGroup(groupId: String, graph: HomeGraph) throws -> Plan {
        let (home, group) = try self.serviceGroup(id: groupId, in: graph)
        return Plan(
            tool: "delete_service_group",
            title: "Delete service group “\(group.name)”",
            summary: "Delete service group “\(group.name)”",
            isDestructive: true,
            operations: [.removeServiceGroup(homeId: home.id, groupId: group.id)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .serviceGroup, id: group.id, name: group.name),
                op: .delete,
                before: group.name,
                after: nil
            )],
            card: [
                ProposalCardLine(.remove, "Service group “\(group.name)” · deleted"),
                // Groups are labels over services; deleting one touches no device.
                ProposalCardLine(.plain, "Devices are unaffected — a group is a label over services."),
            ]
        )
    }

    // MARK: - Triggers

    /// Spec locked decision: creation NEVER arms. Every trigger this tool
    /// adds lands disabled; enabling is `set_trigger_state`, which stages
    /// its own separately-approved proposal. An agent can therefore never
    /// silently flip an automation on.

    private static func createTimerTrigger(
        homeId: String, name: String, fireDate: Date, recurrence: [String: Int],
        sceneId: String?, graph: HomeGraph
    ) throws -> Plan {
        let trimmed = try requiredName(name, kind: "trigger")
        let home = try self.home(id: homeId, in: graph)
        let scene = try sceneReference(sceneId, in: home)

        var card: [ProposalCardLine] = [
            ProposalCardLine(.add, "Timer trigger “\(trimmed)” · created DISABLED"),
            ProposalCardLine(.plain, timerLine(fireDate: fireDate, recurrence: recurrence)),
        ]
        if let scene { card.append(ProposalCardLine(.plain, "Runs scene “\(scene.name)” when it fires.")) }
        if scene == nil {
            card.append(ProposalCardLine(
                .note, "⚠ Created without a scene — HomeKit cannot arm it; recreate with a scene to enable it later."
            ))
        }
        card.append(ProposalCardLine(
            .note, "⚠ Created disabled — arming it takes a separate set_trigger_state approval."
        ))

        return Plan(
            tool: "create_timer_trigger",
            title: "Create timer trigger “\(trimmed)”",
            summary: "Create timer trigger “\(trimmed)” (disabled)",
            isDestructive: false,
            operations: [.addTimerTrigger(
                homeId: home.id, name: trimmed, fireDate: fireDate, recurrence: recurrence, sceneId: scene?.id
            )],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .trigger, id: "", name: trimmed),
                op: .create,
                before: nil,
                after: "disabled"
            )],
            card: card
        )
    }

    private static func createEventTrigger(
        homeId: String, name: String, events: [TriggerEventSpec], endEvents: [TriggerEventSpec],
        executeOnce: Bool, sceneId: String?, graph: HomeGraph
    ) throws -> Plan {
        let trimmed = try requiredName(name, kind: "trigger")
        let home = try self.home(id: homeId, in: graph)
        let scene = try sceneReference(sceneId, in: home)
        let capabilityNotes = try validate(events: events, home: home)
            + validate(events: endEvents, home: home)

        var card: [ProposalCardLine] = [
            ProposalCardLine(.add, "Event trigger “\(trimmed)” · created DISABLED"),
        ]
        card += events.map { ProposalCardLine(.plain, "Fires \($0.description(in: home))") }
        card += endEvents.map {
            ProposalCardLine(.plain, "Ends with \($0.description(in: home)) — HomeKit restores the prior state")
        }
        card += capabilityNotes
        if executeOnce {
            card.append(ProposalCardLine(.plain, "Runs once — HomeKit disables the trigger after it fires."))
        }
        if let scene { card.append(ProposalCardLine(.plain, "Runs scene “\(scene.name)” when it fires.")) }
        if scene == nil {
            card.append(ProposalCardLine(
                .note, "⚠ Created without a scene — HomeKit cannot arm it; recreate with a scene to enable it later."
            ))
        }
        card.append(ProposalCardLine(
            .note, "⚠ Created disabled — arming it takes a separate set_trigger_state approval."
        ))

        return Plan(
            tool: "create_event_trigger",
            title: "Create event trigger “\(trimmed)”",
            summary: "Create event trigger “\(trimmed)” (disabled)",
            isDestructive: false,
            operations: [.addEventTrigger(
                homeId: home.id, name: trimmed, events: events, endEvents: endEvents,
                executeOnce: executeOnce, sceneId: scene?.id
            )],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .trigger, id: "", name: trimmed),
                op: .create,
                before: nil,
                after: "disabled"
            )],
            card: card
        )
    }

    /// Event-trigger editing (spec group 1): the event list is declarative —
    /// a full replacement, like set_scene_actions — with optional end-event,
    /// recurrence, execute-once, and scene changes. The create/arm firewall
    /// holds: the plan never touches isEnabled, and the card says so.
    private static func updateEventTrigger(
        triggerId: String, events: [TriggerEventSpec], endEvents: [TriggerEventSpec]?,
        recurrences: [[String: Int]]?, executeOnce: Bool?, sceneId: String?, graph: HomeGraph
    ) throws -> Plan {
        let (home, trigger) = try self.trigger(id: triggerId, in: graph)
        guard case .event(let currentEvents, _) = trigger.detail else {
            throw PlannerError.invalidInput(
                "Trigger “\(trigger.name)” is a timer trigger — set_trigger_state moves its schedule; event triggers have no fire date."
            )
        }
        let capabilityNotes = try validate(events: events, home: home)
            + validate(events: endEvents ?? [], home: home)
        try validateEventTriggerRecurrences(recurrences)
        let newScene = try sceneReference(sceneId, in: home)

        // Diff the declarative list against the current events, matched by
        // canonical identity — the same name-or-UUID rule everywhere else, so
        // the card's diff, the executor, and the read-back agree.
        let currentKeys = currentEvents.map { $0.canonicalKey(in: home) }
        let targetKeys = events.map { $0.canonicalKey(in: home) }
        let removals = zip(currentEvents, currentKeys).filter { !targetKeys.contains($0.1) }
        let additions = zip(events, targetKeys).filter { !currentKeys.contains($0.1) }
        let eventsChanged = !additions.isEmpty || !removals.isEmpty
        let sceneChanged = sceneId.map { id in !trigger.linkedSceneIds.contains(id) } ?? false
        if !eventsChanged, !sceneChanged, endEvents == nil, recurrences == nil, executeOnce == nil {
            throw PlannerError.noChange("event trigger “\(trigger.name)” already watches exactly these events.")
        }

        let accessoryName = { (ref: HomeGraph.EventRef) -> String in
            ref.accessoryId.flatMap { accessory(id: $0, in: home)?.name } ?? ref.accessoryId ?? "an accessory"
        }
        var card: [ProposalCardLine] =
            removals.map {
                ProposalCardLine(.remove, "“\(trigger.name)” · remove event — \(describe(event: $0.0, accessoryName: accessoryName($0.0)))")
            }
            + additions.map {
                ProposalCardLine(.add, "“\(trigger.name)” · add event — fires \($0.0.description(in: home))")
            }
        if let endEvents {
            if endEvents.isEmpty {
                card.append(ProposalCardLine(.remove, "“\(trigger.name)” · end events cleared"))
            } else {
                card += endEvents.map {
                    ProposalCardLine(.plain, "“\(trigger.name)” · ends with \($0.description(in: home)) — HomeKit restores the prior state")
                }
            }
        }
        if let recurrences {
            let days = recurrences.compactMap { $0["weekday"] }.map(weekdayName)
            card.append(ProposalCardLine(
                .plain,
                days.isEmpty ? "Evaluated every day — recurrences cleared." : "Evaluated only on \(days.joined(separator: ", "))."
            ))
        }
        if let executeOnce {
            card.append(ProposalCardLine(
                .plain,
                executeOnce ? "Runs once — HomeKit disables the trigger after it fires." : "Repeats — the trigger keeps firing until deleted or disarmed."
            ))
        }
        if let newScene {
            card.append(ProposalCardLine(.plain, "Runs scene “\(newScene.name)” when it fires."))
        }
        if trigger.linkedSceneIds.isEmpty && sceneId == nil {
            card.append(ProposalCardLine(
                .note, "⚠ Runs no scene — HomeKit cannot arm it; pass sceneId to give it one."
            ))
        }
        card.append(ProposalCardLine(
            .note,
            "⚠ Editing does not change the trigger's armed state — it stays \(trigger.isEnabled ? "enabled" : "disabled")."
        ))

        let triggerRef = ProposalObjectRef(kind: .trigger, id: trigger.id, name: trigger.name)
        var entries: [ProposalDiffEntry] =
            removals.map {
                ProposalDiffEntry(
                    object: triggerRef, op: .removeMembers,
                    before: describe(event: $0.0, accessoryName: accessoryName($0.0)), after: nil
                )
            }
            + additions.map {
                ProposalDiffEntry(object: triggerRef, op: .addMembers, before: nil, after: $0.0.description(in: home))
            }
        if entries.isEmpty {
            // Field-only edits (executeOnce, recurrences, scene) still record
            // one entry so the diff is never empty.
            entries = [ProposalDiffEntry(object: triggerRef, op: .update, before: nil, after: "contents updated")]
        }

        return Plan(
            tool: "update_event_trigger",
            title: "Update event trigger “\(trigger.name)”",
            summary: "Update event trigger “\(trigger.name)” events (\(additions.count) added, \(removals.count) removed)",
            isDestructive: false,
            operations: [.updateEventTrigger(
                homeId: home.id, triggerId: trigger.id, events: events,
                endEvents: endEvents, recurrences: recurrences,
                executeOnce: executeOnce, sceneId: sceneId
            )],
            entries: entries,
            card: card
        )
    }

    private static func setTriggerState(
        triggerId: String, enabled: Bool, fireDate: Date?, recurrence: [String: Int]?,
        graph: HomeGraph
    ) throws -> Plan {
        let (home, trigger) = try self.trigger(id: triggerId, in: graph)
        if trigger.isEnabled == enabled {
            throw PlannerError.noChange("trigger “\(trigger.name)” is already \(enabled ? "enabled" : "disabled").")
        }
        // HomeKit law: a trigger with no registered action sets has nothing
        // to run and cannot be enabled — the approval would always fail with
        // "No registered action sets for trigger". Say so at staging, where
        // the agent can act on it, instead of after a doomed approval.
        if enabled, trigger.linkedSceneIds.isEmpty {
            throw PlannerError.invalidInput(
                "Trigger “\(trigger.name)” runs no scene — HomeKit cannot enable an automation with no action sets. Delete it and recreate it with a scene (sceneId), then arm it."
            )
        }
        // Schedule updates ride the timer trigger only; an event trigger has
        // no fire date to update.
        if fireDate != nil || recurrence != nil, case .event = trigger.detail {
            throw PlannerError.invalidInput(
                "Trigger “\(trigger.name)” is an event trigger; fireDate and recurrence apply to timer triggers."
            )
        }

        let from = trigger.isEnabled ? "enabled" : "disabled"
        let to = enabled ? "enabled" : "disabled"
        var card: [ProposalCardLine] = [
            ProposalCardLine(enabled ? .add : .remove, "Trigger “\(trigger.name)” · \(from) → \(to)")
        ]
        if let fireDate, case .timer = trigger.detail {
            card.append(ProposalCardLine(.plain, timerLine(fireDate: fireDate, recurrence: recurrence ?? [:])))
        }
        if enabled {
            // The locked rule the card must make visible: this is the arm
            // step, always its own approval after the one that created it.
            card.append(ProposalCardLine(
                .note, "⚠ Arming an automation — it will run on its own once approved."
            ))
        }

        // Arming (or disarming) is always its own operation, and a timer
        // whose fire date moves rides the same proposal as a second op.
        var operations: [HomeKitOperation] = [
            .setTriggerEnabled(homeId: home.id, triggerId: trigger.id, enabled: enabled)
        ]
        if case .timer = trigger.detail, fireDate != nil || recurrence != nil {
            operations.append(.updateTimerTrigger(
                homeId: home.id, triggerId: trigger.id,
                fireDate: fireDate ?? timerFireDate(of: trigger),
                recurrence: recurrence ?? timerRecurrence(of: trigger)
            ))
        }

        return Plan(
            tool: "set_trigger_state",
            title: "\(enabled ? "Enable" : "Disable") trigger “\(trigger.name)”",
            summary: "\(enabled ? "Enable" : "Disable") trigger “\(trigger.name)”",
            isDestructive: false,
            operations: operations,
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .trigger, id: trigger.id, name: trigger.name),
                op: .update,
                before: from,
                after: to
            )],
            card: card
        )
    }

    private static func deleteTrigger(triggerId: String, graph: HomeGraph) throws -> Plan {
        let (home, trigger) = try self.trigger(id: triggerId, in: graph)
        return Plan(
            tool: "delete_trigger",
            title: "Delete trigger “\(trigger.name)”",
            summary: "Delete trigger “\(trigger.name)”",
            isDestructive: true,
            operations: [.removeTrigger(homeId: home.id, triggerId: trigger.id)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .trigger, id: trigger.id, name: trigger.name),
                op: .delete,
                before: trigger.name,
                after: nil
            )],
            card: [
                ProposalCardLine(.remove, "Trigger “\(trigger.name)” · deleted"),
                // Spec risk: a silently-disabled automation looks healthy
                // until it fails to fire. Deletion is louder, but the card
                // still says what stops existing.
                ProposalCardLine(.plain, "The automation stops firing immediately — visible to the Home app and Siri."),
            ]
        )
    }

    // MARK: - Accessories

    private static func renameAccessory(accessoryId: String, name: String, graph: HomeGraph) throws -> Plan {
        let (home, accessory) = try self.accessory(id: accessoryId, in: graph)
        let trimmed = try requiredHomeKitName(name, kind: "accessory")
        if accessory.name.caseInsensitiveCompare(trimmed) == .orderedSame {
            throw PlannerError.noChange("accessory “\(accessory.name)” is already named “\(trimmed)”.")
        }
        return Plan(
            tool: "rename_accessory",
            title: "Rename accessory “\(accessory.name)”",
            summary: "Rename accessory “\(accessory.name)” to “\(trimmed)”",
            isDestructive: false,
            operations: [.renameAccessory(homeId: home.id, accessoryId: accessory.id, to: trimmed)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .accessory, id: accessory.id, name: accessory.name),
                op: .rename,
                before: accessory.name,
                after: trimmed
            )],
            card: [ProposalCardLine(.plain, "Accessory “\(accessory.name)” → “\(trimmed)”")]
        )
    }

    /// Spec (accessory lifecycle): identify flashes or beeps the physical
    /// device — harmless but physical, so the card says so. Accessories
    /// without an Identify characteristic cannot be identified: when the
    /// graph carries the capability data a `false` rejects staging with the
    /// typed reason; missing data degrades to a permissive note, the same
    /// shape the characteristic capability check uses.
    private static func identifyAccessory(accessoryId: String, graph: HomeGraph) throws -> Plan {
        let (home, accessory) = try self.accessory(id: accessoryId, in: graph)
        var card: [ProposalCardLine] = [
            ProposalCardLine(.add, "Accessory “\(accessory.name)” · identified (flash/beep)"),
        ]
        switch accessory.supportsIdentify {
        case .some(false):
            throw PlannerError.invalidInput(
                "Accessory “\(accessory.name)” does not support identify — it has no Identify characteristic."
            )
        case .some(true):
            break
        case nil:
            card.append(ProposalCardLine(
                .note,
                "⚠ Could not verify identify support — “\(accessory.name)”'s capability data is unavailable; approval may still fail at execution."
            ))
        }
        return Plan(
            tool: "identify_accessory",
            title: "Identify accessory “\(accessory.name)”",
            summary: "Identify accessory “\(accessory.name)” (flash/beep)",
            isDestructive: false,
            operations: [.identifyAccessory(homeId: home.id, accessoryId: accessory.id)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .accessory, id: accessory.id, name: accessory.name),
                op: .update,
                before: "idle",
                after: "flash/beep on approval"
            )],
            card: card
        )
    }

    private static func assignAccessoryToRoom(accessoryId: String, roomId: String, graph: HomeGraph) throws -> Plan {
        let (home, accessory) = try self.accessory(id: accessoryId, in: graph)
        guard let room = home.rooms.first(where: { $0.id == roomId }) else {
            throw PlannerError.unknownRoom(roomId)
        }
        let currentRoom = home.rooms.first { $0.accessories.contains { $0.id == accessory.id } }
        if currentRoom?.id == room.id {
            throw PlannerError.noChange(
                "accessory “\(accessory.name)” is already in “\(room.name)”."
            )
        }
        let from = currentRoom.map { "“\($0.name)”" } ?? "no room"
        return Plan(
            tool: "assign_accessory_to_room",
            title: "Move accessory “\(accessory.name)” to \(room.name)",
            summary: "Move accessory “\(accessory.name)” from \(from) to “\(room.name)”",
            isDestructive: false,
            operations: [.assignAccessoryToRoom(homeId: home.id, accessoryId: accessory.id, roomId: room.id)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .accessory, id: accessory.id, name: accessory.name),
                op: .move,
                before: currentRoom?.name,
                after: room.name
            )],
            card: [ProposalCardLine(
                .plain,
                "Accessory “\(accessory.name)” · \(from) → “\(room.name)”"
            )]
        )
    }

    /// A security block is HomeKit holding the accessory back (a paused or
    /// misbehaving bridge device); unblocking lets it run again. Blocked
    /// state is not in the graph (the read-depth flags are a separate
    /// group), so staging checks existence only and the card says what
    /// unblocking means.
    private static func unblockAccessory(accessoryId: String, graph: HomeGraph) throws -> Plan {
        let (home, accessory) = try self.accessory(id: accessoryId, in: graph)
        return Plan(
            tool: "unblock_accessory",
            title: "Unblock accessory “\(accessory.name)”",
            summary: "Unblock accessory “\(accessory.name)”",
            isDestructive: false,
            operations: [.unblockAccessory(homeId: home.id, accessoryId: accessory.id)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .accessory, id: accessory.id, name: accessory.name),
                op: .update,
                before: "blocked",
                after: "unblocked"
            )],
            card: [ProposalCardLine(
                .add,
                "Accessory “\(accessory.name)” · unblocked — HomeKit resumes controlling it"
            )]
        )
    }

    /// Spec (destructive severity): the card lists every scene, service
    /// group, and trigger that references the accessory — its actions die
    /// with it, its services leave their groups, its characteristics stop
    /// firing triggers — and where it lands: nowhere, the accessory leaves
    /// the home entirely.
    private static func removeAccessory(accessoryId: String, graph: HomeGraph) throws -> Plan {
        let (home, accessory) = try self.accessory(id: accessoryId, in: graph)
        let currentRoom = home.rooms.first { $0.accessories.contains { $0.id == accessory.id } }

        let referencingScenes = home.scenes.filter { scene in
            scene.actions.contains { $0.accessoryId == accessory.id }
        }
        let referencingGroups = home.serviceGroups.filter { group in
            group.services.contains { $0.accessoryId == accessory.id }
        }
        let referencingTriggers = home.triggers.filter { trigger in
            guard case .event(let events, _) = trigger.detail else { return false }
            return events.contains { $0.accessoryId == accessory.id }
        }

        var card: [ProposalCardLine] = [
            ProposalCardLine(.remove, "Accessory “\(accessory.name)” · deleted"),
        ]
        if let currentRoom {
            card.append(ProposalCardLine(.plain, "It leaves room “\(currentRoom.name)” and the home entirely."))
        }
        for scene in referencingScenes {
            card.append(ProposalCardLine(
                .note,
                "⚠ Scene “\(scene.name)” loses every action it performs on this accessory."
            ))
        }
        for group in referencingGroups {
            card.append(ProposalCardLine(
                .note,
                "⚠ Service group “\(group.name)” loses this accessory's services."
            ))
        }
        for trigger in referencingTriggers {
            card.append(ProposalCardLine(
                .note,
                "⚠ Trigger “\(trigger.name)” fires on this accessory's characteristics and will stop working."
            ))
        }
        if referencingScenes.isEmpty && referencingGroups.isEmpty && referencingTriggers.isEmpty {
            card.append(ProposalCardLine(.plain, "Nothing references this accessory."))
        }

        return Plan(
            tool: "remove_accessory",
            title: "Delete accessory “\(accessory.name)”",
            summary: "Delete accessory “\(accessory.name)”",
            isDestructive: true,
            operations: [.removeAccessory(homeId: home.id, accessoryId: accessory.id)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .accessory, id: accessory.id, name: accessory.name),
                op: .delete,
                before: accessory.name,
                after: nil
            )],
            card: card
        )
    }

    // MARK: - Direct writes (device-immediate)

    /// Spec (direct control, device-immediate): one characteristic write
    /// that applies to the device the moment approval lands. Staging checks
    /// the value against the characteristic's declared metadata with the
    /// same shared check resolution runs — a rejection names the
    /// characteristic, its current reading, and why the target can never
    /// fit, and a proposal that stages always executes.
    private static func writeCharacteristic(
        accessoryId: String, service: String?, characteristic: String, value: HomeKitValue, graph: HomeGraph
    ) throws -> Plan {
        let (home, accessory) = try self.accessory(id: accessoryId, in: graph)
        var card: [ProposalCardLine] = []
        switch capability(characteristic: characteristic, service: service, in: accessory) {
        case .supported:
            break
        case .unverifiable:
            card.append(ProposalCardLine(
                .note,
                "⚠ Could not verify \(characteristic) support — “\(accessory.name)”'s "
                    + "capability data is unavailable; approval may still fail at execution."
            ))
        case .unsupported(let error):
            throw error
        }
        let ref = accessory.characteristic(characteristic, service: service)
        let kind = DeviceHomeView.ValueKind(format: ref?.metadata?.format)
        if let why = DeviceWriteResolver.valueViolation(value, kind: kind, metadata: ref?.metadata) {
            let current = ref?.valueDescription.map { "currently reads \($0)" } ?? "has no current reading"
            throw PlannerError.invalidInput(
                "Characteristic \(characteristic) on “\(accessory.name)” \(current) — "
                    + "target \(value.rendered) rejected: \(why)."
            )
        }
        if ref?.valueDescription == value.rendered {
            throw PlannerError.noChange(
                "“\(accessory.name)” \(characteristic) already reads \(value.rendered)."
            )
        }
        let label = ref?.name ?? characteristic
        let current = ref?.valueDescription ?? "unknown"
        card.insert(ProposalCardLine(
            .plain,
            "\(accessory.name): \(label) \(current) → \(value.rendered)"
        ), at: 0)
        card.append(ProposalCardLine(
            .note,
            "⚠ Device-immediate — the value applies to the device the moment this is approved."
        ))
        let spec = SceneActionSpec(
            accessoryId: accessory.id, service: service, characteristic: characteristic, value: value
        )
        return Plan(
            tool: "write_characteristic",
            title: "Set “\(accessory.name)” \(label) to \(value.rendered)",
            summary: "Set “\(accessory.name)” \(label) to \(value.rendered) now",
            isDestructive: false,
            operations: [.writeCharacteristic(homeId: home.id, action: spec)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .accessory, id: accessory.id, name: accessory.name),
                op: .update,
                before: ref?.valueDescription,
                after: value.rendered
            )],
            card: card
        )
    }

    // MARK: - Shared helpers

    private static func home(id: String, in graph: HomeGraph) throws -> HomeGraph.Home {
        guard let home = graph.homes.first(where: { $0.id == id }) else {
            throw PlannerError.unknownHome(id)
        }
        return home
    }

    private static func room(id: String, in home: HomeGraph.Home) -> HomeGraph.Room? {
        home.rooms.first { $0.id == id }
    }

    private static func room(id: String, in graph: HomeGraph) throws -> (HomeGraph.Home, HomeGraph.Room) {
        for home in graph.homes {
            if let room = Self.room(id: id, in: home) { return (home, room) }
        }
        throw PlannerError.unknownRoom(id)
    }

    private static func zone(id: String, in graph: HomeGraph) throws -> (HomeGraph.Home, HomeGraph.Zone) {
        for home in graph.homes {
            if let zone = home.zones.first(where: { $0.id == id }) { return (home, zone) }
        }
        throw PlannerError.unknownZone(id)
    }

    private static func scene(id: String, in graph: HomeGraph) throws -> (HomeGraph.Home, HomeGraph.Scene) {
        for home in graph.homes {
            if let scene = home.scenes.first(where: { $0.id == id }) { return (home, scene) }
        }
        throw PlannerError.unknownScene(id)
    }

    private static func serviceGroup(id: String, in graph: HomeGraph) throws -> (HomeGraph.Home, HomeGraph.ServiceGroup) {
        for home in graph.homes {
            if let group = home.serviceGroups.first(where: { $0.id == id }) { return (home, group) }
        }
        throw PlannerError.unknownServiceGroup(id)
    }

    private static func trigger(id: String, in graph: HomeGraph) throws -> (HomeGraph.Home, HomeGraph.Trigger) {
        for home in graph.homes {
            if let trigger = home.triggers.first(where: { $0.id == id }) { return (home, trigger) }
        }
        throw PlannerError.unknownTrigger(id)
    }

    private static func accessory(id: String, in graph: HomeGraph) throws -> (HomeGraph.Home, HomeGraph.Accessory) {
        for home in graph.homes {
            for room in home.rooms {
                if let accessory = room.accessories.first(where: { $0.id == id }) {
                    return (home, accessory)
                }
            }
        }
        throw PlannerError.invalidInput("No accessory with id \(id). Accessory ids come from get_rooms.")
    }

    /// A trigger runs an existing scene (HomeKit binds an action set to a
    /// trigger); referencing one that does not exist in the same home is an
    /// eager-validation failure, never a staged surprise.
    private static func sceneReference(_ sceneId: String?, in home: HomeGraph.Home) throws -> HomeGraph.Scene? {
        guard let sceneId, !sceneId.isEmpty else { return nil }
        guard let scene = home.scenes.first(where: { $0.id == sceneId }) else {
            throw PlannerError.unknownScene(sceneId)
        }
        return scene
    }

    private static func roomName(id: String, home: HomeGraph.Home) -> String {
        room(id: id, in: home)?.name ?? id
    }

    private static func requiredName(_ name: String, kind: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PlannerError.invalidInput("\(kind.capitalized) name must not be empty.")
        }
        return trimmed
    }

    /// Names written through HomeKit's `updateName` family (rooms, zones,
    /// scenes, service groups, accessories) face its naming rules — see
    /// `DeviceWriteResolver.nameViolation`, the same check the executor's
    /// resolution runs. Rejecting here keeps staging and execution in
    /// agreement: nothing reaches approval that HomeKit will refuse.
    private static func requiredHomeKitName(_ name: String, kind: String) throws -> String {
        let trimmed = try requiredName(name, kind: kind)
        if let why = DeviceWriteResolver.nameViolation(trimmed) {
            throw PlannerError.invalidInput(
                "\(kind.capitalized) name “\(trimmed)” is not a valid HomeKit name: \(why)."
            )
        }
        return trimmed
    }

    private static func rejectDuplicate(kind: String, name: String, in names: [String], homeName: String) throws {
        if names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            throw PlannerError.duplicateName(kind: kind, name: name, home: homeName)
        }
    }

    /// A human description of an event as it currently exists in the graph —
    /// the "before" side of an event-trigger edit's diff.
    private static func describe(event ref: HomeGraph.EventRef, accessoryName: String) -> String {
        if ref.type.lowercased().contains("presence") {
            switch ref.valueDescription?.lowercased() {
            case "athome": return "someone arrives home"
            case "away": return "everyone is away"
            default: return "a presence change"
            }
        }
        let characteristicName = ref.characteristicType ?? "a characteristic"
        if let value = ref.valueDescription {
            return "\(accessoryName) \(characteristicName) reaches \(value)"
        }
        return "\(accessoryName) \(characteristicName) changes"
    }

    private static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    private static func weekdayName(_ weekday: Int) -> String {
        (1...7).contains(weekday) ? Self.weekdayNames[weekday - 1] : "day \(weekday)"
    }

    /// Event-trigger recurrences are days of the week (HomeKit honors only
    /// the `weekday` component on HMEventTrigger) — the same rule the resolver
    /// enforces at execution, stated eagerly so the agent fixes the request
    /// before staging.
    private static func validateEventTriggerRecurrences(_ recurrences: [[String: Int]]?) throws {
        for components in recurrences ?? [] {
            guard components.count == 1, let weekday = components["weekday"], (1...7).contains(weekday) else {
                throw PlannerError.invalidInput(
                    "Event-trigger recurrences are days of the week — one “weekday” component (1…7, 1 = Sunday) per entry."
                )
            }
        }
    }

    /// Eager per-event validation (spec): every proposed characteristic event
    /// must reference an accessory that exists in the home today and — when
    /// capability data is available — a characteristic it actually supports.
    /// All failures are collected, so the agent fixes everything in one
    /// retry; missing capability data degrades to a permissive card note.
    private static func validate(events: [TriggerEventSpec], home: HomeGraph.Home) throws -> [ProposalCardLine] {
        var failures: [String] = []
        var notes: [ProposalCardLine] = []
        for (index, event) in events.enumerated() {
            guard case .characteristic(let accessoryId, let characteristic, _) = event else { continue }
            guard let accessory = accessory(id: accessoryId, in: home) else {
                let error = PlannerError.unknownAccessory(id: accessoryId, home: home.name)
                failures.append("Event \(index + 1): \(error.message)")
                continue
            }
            switch capability(characteristic: characteristic, service: nil, in: accessory) {
            case .supported:
                break
            case .unverifiable:
                notes.append(ProposalCardLine(
                    .note,
                    "⚠ Could not verify \(characteristic) support — “\(accessory.name)”'s "
                        + "capability data is unavailable; approval may still fail at execution."
                ))
            case .unsupported(let error):
                failures.append("Event \(index + 1): \(error.message)")
            }
        }
        if !failures.isEmpty {
            throw PlannerError.validationFailed(failures)
        }
        return notes
    }

    // MARK: - Capability checks

    /// The outcome of a staging-time capability check against the graph's
    /// accessory services.
    private enum Capability {
        case supported
        /// No characteristic data to judge against — staging stays permissive.
        case unverifiable
        case unsupported(PlannerError)
    }

    /// Whether an accessory supports a characteristic, mirroring the
    /// executor's resolution (`DeviceWriteResolver.resolveAction`): the
    /// characteristic is identified by type UUID or its metadata name (the
    /// shared rule settled with the write-resolver fix so staging and
    /// execution read the same DeviceHomeView shape), and the service
    /// name-or-type filter matches when the spec names a service — so
    /// staging never passes anything execution would reject. Accessories
    /// whose services list no characteristics (a graph without capability
    /// reads) are unverifiable.
    private static func capability(
        characteristic: String, service: String?, in accessory: HomeGraph.Accessory
    ) -> Capability {
        guard accessory.services.contains(where: { !$0.characteristics.isEmpty }) else {
            return .unverifiable
        }
        let services: [HomeGraph.AccessoryService]
        if let wanted = service {
            services = accessory.services.filter {
                $0.name.caseInsensitiveCompare(wanted) == .orderedSame
                    || $0.serviceType.map { $0.caseInsensitiveCompare(wanted) == .orderedSame } == true
            }
            if services.isEmpty {
                return .unsupported(.unknownServiceOnAccessory(accessory: accessory.name, service: wanted))
            }
        } else {
            services = accessory.services
        }
        let matches: (HomeGraph.CharacteristicRef) -> Bool = { ref in
            ref.type == characteristic
                || ref.name.map { $0.caseInsensitiveCompare(characteristic) == .orderedSame } == true
        }
        guard services.contains(where: { $0.characteristics.contains(where: matches) }) else {
            return .unsupported(.unsupportedCharacteristic(accessory: accessory.name, characteristic: characteristic))
        }
        return .supported
    }

    /// "fires 2026-11-09T07:30:00Z, repeating {hour: 7, minute: 30}".
    private static func timerLine(fireDate: Date, recurrence: [String: Int]) -> String {
        var line = "Fires \(ISOTimestamps.render(fireDate))"
        if !recurrence.isEmpty {
            line += ", repeating \(Self.recurrenceDescription(recurrence))"
        }
        return line
    }

    private static func recurrenceDescription(_ recurrence: [String: Int]) -> String {
        let order = ["year", "month", "weekday", "day", "hour", "minute", "second"]
        let parts = order
            .compactMap { key -> String? in recurrence[key].map { "\(key): \($0)" } }
            .joined(separator: ", ")
        return "{\(parts)}"
    }

    private static func timerFireDate(of trigger: HomeGraph.Trigger) -> Date {
        if case .timer(let fireDate, _) = trigger.detail { return fireDate }
        return Date()
    }

    private static func timerRecurrence(of trigger: HomeGraph.Trigger) -> [String: Int] {
        if case .timer(_, let recurrence) = trigger.detail { return recurrence }
        return [:]
    }

    /// Eager per-action validation (spec): every proposed scene action must
    /// reference an accessory that exists in the home today and — when the
    /// graph carries capability data (the read side's accessory services
    /// with their characteristics) — a characteristic the accessory actually
    /// supports. All failures are collected, so the agent fixes everything in
    /// one retry. When an accessory exposes no characteristic data the
    /// support check degrades to permissive and the returned card note says
    /// so; a rejection here always precedes a human seeing a card.
    private static func validate(
        accessories actions: [SceneActionSpec], home: HomeGraph.Home
    ) throws -> [ProposalCardLine] {
        var failures: [String] = []
        var notes: [ProposalCardLine] = []
        for (index, action) in actions.enumerated() {
            guard let accessory = accessory(id: action.accessoryId, in: home) else {
                let error = PlannerError.unknownAccessory(id: action.accessoryId, home: home.name)
                failures.append("Action \(index + 1): \(error.message)")
                continue
            }
            switch capability(characteristic: action.characteristic, service: action.service, in: accessory) {
            case .supported:
                break
            case .unverifiable:
                notes.append(ProposalCardLine(
                    .note,
                    "⚠ Could not verify \(action.characteristic) support — “\(accessory.name)”'s "
                        + "capability data is unavailable; approval may still fail at execution."
                ))
            case .unsupported(let error):
                failures.append("Action \(index + 1): \(error.message)")
            }
        }
        if !failures.isEmpty {
            throw PlannerError.validationFailed(failures)
        }
        return notes
    }

    /// Display line for a proposed action: "Desk Lamp: Brightness → 30".
    private static func describe(spec: SceneActionSpec, home: HomeGraph.Home) -> String {
        let accessory = accessoryName(of: spec.accessoryId, in: home) ?? spec.accessoryId
        let label = characteristicLabel(for: spec.characteristic, in: home)
        return "\(accessory): \(label) → \(spec.value.rendered)"
    }

    /// Display line for an action read from the graph.
    private static func describe(action: HomeGraph.SceneAction, home: HomeGraph.Home) -> String {
        let accessory = action.accessoryName ?? action.accessoryId ?? "unknown accessory"
        let label = action.characteristicName ?? action.characteristic
        return "\(accessory): \(label) → \(action.valueDescription)"
    }

    private static func accessory(id: String, in home: HomeGraph.Home) -> HomeGraph.Accessory? {
        home.rooms.flatMap { $0.accessories }.first { $0.id == id }
    }

    private static func accessoryName(of id: String, in home: HomeGraph.Home) -> String? {
        accessory(id: id, in: home)?.name
    }

    /// Borrow a human label for a characteristic type from any scene action in
    /// the home that already carries one; unknown types fall back to the type
    /// string itself. Display-only — proposals are keyed by type.
    private static func characteristicLabel(for type: String, in home: HomeGraph.Home) -> String {
        for scene in home.scenes {
            for action in scene.actions where action.characteristic == type {
                if let name = action.characteristicName { return name }
            }
        }
        return type
    }
}

/// Display names for proposed events, rendered against the current graph.
extension TriggerEventSpec {
    /// Human line for a review card: "Lamp B Brightness reaches 0",
    /// "someone arrives home".
    func description(in home: HomeGraph.Home) -> String {
        switch self {
        case .characteristic(let accessoryId, let characteristic, let value):
            let accessory = home.rooms.flatMap { $0.accessories }
                .first { $0.id == accessoryId }?.name ?? accessoryId
            if let value {
                return "\(accessory) \(characteristic) reaches \(value.rendered)"
            }
            return "\(accessory) \(characteristic) changes"
        case .presence(let atHome):
            return atHome ? "someone arrives home" : "everyone is away"
        }
    }
}

extension ProposalStore {
    /// The store every caller wants: planned by `ProposalPlanner`. The store
    /// itself takes any plan function — tests and future tools can substitute
    /// their own — so the concrete planner lives here, with the planner.
    public init(
        homeKit: any HomeKitWriting,
        now: @escaping @Sendable () -> Date = { Date() },
        lifetime: TimeInterval = 24 * 60 * 60
    ) {
        self.init(homeKit: homeKit, planWith: ProposalPlanner.planFunction, now: now, lifetime: lifetime)
    }
}
