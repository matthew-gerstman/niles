import Foundation

extension ProposalPlanner {
    // MARK: - Unified verbs (Blueprint art_34OYtrUm, write layer)

    /// What kind of object an `entityId` names, resolved against the same
    /// graph the per-type planners search — resolution and planning agree
    /// on what exists because they read one graph.
    private enum EntityKind {
        case room, zone, scene, group, accessory, trigger
    }

    /// Rewrites one unified-verb call onto its per-type tool call, or nil
    /// for any other tool name. The per-type `WriteRequest.parse` does all
    /// argument parsing; this only decides which per-type tool the call
    /// becomes, and never stages a proposal itself.
    static func resolveUnified(
        tool: String, arguments: [String: ToolArgument]?, graph: HomeGraph
    ) throws -> (tool: String, arguments: [String: ToolArgument])? {
        switch tool {
        case "rename", "delete", "create", "update":
            break
        default:
            return nil
        }
        let raw = arguments ?? [:]

        func string(_ name: String) throws -> String {
            guard let value = raw[name] else {
                throw ProposalStoreError.invalidArguments("Missing required argument “\(name)”.")
            }
            guard let string = value.stringValue else {
                throw ProposalStoreError.invalidArguments("Argument “\(name)” must be a string.")
            }
            return string
        }

        switch tool {
        case "rename":
            let entityId = try string("entityId")
            let newName = try string("newName")
            switch try entity(of: entityId, in: graph) {
            case .room:
                return ("rename_room", ["roomId": .string(entityId), "name": .string(newName)])
            case .zone:
                return ("rename_zone", ["zoneId": .string(entityId), "name": .string(newName)])
            case .scene:
                return ("rename_scene", ["sceneId": .string(entityId), "name": .string(newName)])
            case .group:
                return ("rename_service_group", ["groupId": .string(entityId), "name": .string(newName)])
            case .accessory:
                return ("rename_accessory", ["accessoryId": .string(entityId), "name": .string(newName)])
            case .trigger:
                throw PlannerError.invalidInput("Triggers cannot be renamed.")
            }
        case "delete":
            let entityId = try string("entityId")
            var args: [String: ToolArgument]
            switch try entity(of: entityId, in: graph) {
            case .room:
                args = ["roomId": .string(entityId)]
                return ("delete_room", args)
            case .zone:
                args = ["zoneId": .string(entityId)]
                return ("delete_zone", args)
            case .scene:
                args = ["sceneId": .string(entityId)]
                // The linked-trigger offer is the one per-type delete
                // argument that carries over.
                if let deleteLinkedTriggers = raw["deleteLinkedTriggers"] {
                    args["deleteLinkedTriggers"] = deleteLinkedTriggers
                }
                return ("delete_scene", args)
            case .group:
                args = ["groupId": .string(entityId)]
                return ("delete_service_group", args)
            case .accessory:
                args = ["accessoryId": .string(entityId)]
                return ("remove_accessory", args)
            case .trigger:
                args = ["triggerId": .string(entityId)]
                return ("delete_trigger", args)
            }
        case "create":
            let kind = try string("kind").lowercased()
            switch kind {
            case "room":
                return ("create_room", raw)
            case "zone":
                return ("create_zone", raw)
            case "scene":
                return ("create_scene", raw)
            case "group":
                return ("create_service_group", raw)
            case "timer":
                return ("create_timer_trigger", raw)
            case "event":
                return ("create_event_trigger", raw)
            default:
                throw PlannerError.invalidInput(
                    "Unknown create kind “\(kind)”. Valid kinds: room, zone, scene, group, timer, event."
                )
            }
        case "update":
            let entityId = try string("entityId")
            var args = raw
            switch try entity(of: entityId, in: graph) {
            case .group:
                guard raw["members"] != nil else {
                    throw PlannerError.invalidInput(
                        "update on a service group needs members — the complete replacement list of service ids; anything absent is removed."
                    )
                }
                args["groupId"] = .string(entityId)
                args["serviceIds"] = raw["members"]
                args.removeValue(forKey: "members")
                args.removeValue(forKey: "entityId")
                return ("set_service_group_members", args)
            case .zone:
                guard raw["rooms"] != nil else {
                    throw PlannerError.invalidInput(
                        "update on a zone needs rooms — the complete replacement list of room ids; anything absent is removed."
                    )
                }
                args["zoneId"] = .string(entityId)
                args["roomIds"] = raw["rooms"]
                args.removeValue(forKey: "rooms")
                args.removeValue(forKey: "entityId")
                return ("set_zone_rooms", args)
            case .scene:
                guard raw["actions"] != nil else {
                    throw PlannerError.invalidInput(
                        "update on a scene needs actions — the complete replacement list of characteristic writes; anything absent is removed."
                    )
                }
                args["sceneId"] = .string(entityId)
                args.removeValue(forKey: "entityId")
                return ("set_scene_actions", args)
            case .trigger:
                // Timer triggers have no event list; the schedule and the
                // armed state move through set_trigger_state, whose arming
                // approval is always its own proposal.
                let (_, trigger) = try self.trigger(id: entityId, in: graph)
                guard case .event = trigger.detail else {
                    throw PlannerError.invalidInput(
                        "Timer triggers have no event list to update — use set_trigger_state to move their schedule; arming is always its own proposal."
                    )
                }
                guard raw["events"] != nil else {
                    throw PlannerError.invalidInput(
                        "update on an event trigger needs events — the complete replacement event list."
                    )
                }
                args["triggerId"] = .string(entityId)
                args.removeValue(forKey: "entityId")
                return ("update_event_trigger", args)
            case .room, .accessory:
                throw PlannerError.invalidInput(
                    "update applies to groups (members), zones (rooms), scenes (actions), and event triggers (events)."
                )
            }
        default:
            return nil
        }
    }

    /// Resolves one id to its kind by membership in the graph. Zero matches
    /// throw `.unknownEntity`; more than one is a defensive ambiguity error —
    /// HomeKit ids are unique, so a collision means a graph this planner
    /// should not stage against.
    private static func entity(of id: String, in graph: HomeGraph) throws -> EntityKind {
        var matches: [EntityKind] = []
        for home in graph.homes {
            if home.rooms.contains(where: { $0.id == id }) { matches.append(.room) }
            if home.zones.contains(where: { $0.id == id }) { matches.append(.zone) }
            if home.scenes.contains(where: { $0.id == id }) { matches.append(.scene) }
            if home.serviceGroups.contains(where: { $0.id == id }) { matches.append(.group) }
            if home.triggers.contains(where: { $0.id == id }) { matches.append(.trigger) }
            if home.rooms.contains(where: { room in room.accessories.contains(where: { $0.id == id }) }) {
                matches.append(.accessory)
            }
        }
        guard let kind = matches.first else {
            throw PlannerError.unknownEntity(id)
        }
        guard matches.count == 1 else {
            throw PlannerError.invalidInput(
                "Id “\(id)” matches more than one kind of object; resolve it again with search or get_details."
            )
        }
        return kind
    }
}
