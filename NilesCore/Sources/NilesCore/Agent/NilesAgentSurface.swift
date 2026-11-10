import Foundation
import MCP

/// The agent-facing tool surface — the compacted vocabulary the on-device
/// model sees (spec art_VrC0iUUA §What we should build; catalog draft
/// art_yvbPAfG9, v7).
///
/// Six of the twelve tools are the registries' own tools passed through;
/// the six here (search, get_details, create, update, rename, delete) are
/// adapter-shaped: they translate the agent's vocabulary — accessory
/// groups, entity ids, kind-based creation — onto registry primitives and
/// never appear in the MCP server's tool list. The registries keep their
/// full per-type surfaces for MCP clients.
public enum NilesAgentSurface {

    /// Kinds for `get_details` deep reads and search-result typing.
    public enum DetailKind: String, Sendable, CaseIterable {
        case home, room, zone, scene, group, trigger, accessory
    }

    /// Kinds for `create`.
    public enum CreateKind: String, Sendable, CaseIterable {
        case room, zone, scene, group, timer, event
    }

    /// An entity id the agent unified surface resolved against the graph.
    public enum ResolvedEntity: Equatable, Sendable {
        case room(homeId: String, id: String, name: String)
        case zone(homeId: String, id: String, name: String)
        case scene(homeId: String, id: String, name: String)
        case accessoryGroup(homeId: String, id: String, name: String)
        case accessory(homeId: String, id: String, name: String)
        case trigger(homeId: String, id: String, name: String)

        public var id: String {
            switch self {
            case .room(_, let id, _), .zone(_, let id, _), .scene(_, let id, _),
                .accessoryGroup(_, let id, _), .accessory(_, let id, _), .trigger(_, let id, _):
                return id
            }
        }

        public var name: String {
            switch self {
            case .room(_, _, let name), .zone(_, _, let name), .scene(_, _, let name),
                .accessoryGroup(_, _, let name), .accessory(_, _, let name), .trigger(_, _, let name):
                return name
            }
        }
    }

    // MARK: - Adapter tool definitions

    /// The six adapter tools, in catalog order. The other six agent tools
    /// (get_proposal, execute_scene, write_characteristic, update_event_trigger,
    /// set_trigger_state, assign_accessory_to_room) pass through with their
    /// registry definitions; the dispatcher assembles the full list.
    public static let adapterDefinitions: [Tool] = [
        Tool(
            name: "search",
            description: "Find objects by name across the home: rooms, zones, scenes, accessory groups, triggers, and accessories. The user's words may name any of these; when several match, ask which one they mean.",
            inputSchema: objectSchema(
                ["query": stringProperty("The name to look for — a room, zone, scene, group, trigger, or accessory.")],
                required: ["query"]
            ),
            annotations: Tool.Annotations(readOnlyHint: true)
        ),
        Tool(
            name: "get_details",
            description: "Read home state. No arguments: a lean whole-home summary — homes with counts, rooms with accessory names, zones, scenes, groups, and triggers, without characteristics. With kind and id: one object in full, including its characteristics.",
            inputSchema: objectSchema(
                [
                    "kind": stringProperty("home, room, zone, scene, group, trigger, or accessory — required with id."),
                    "id": stringProperty("The object's id — required with kind."),
                ],
                required: []
            ),
            annotations: Tool.Annotations(readOnlyHint: true)
        ),
        Tool(
            name: "create",
            description: "Create an object: a room, zone, scene, accessory group, timer automation, or event automation. Payload depends on kind: groups take accessoryIds (the members to group); scenes take actions (characteristic writes — Niles never executes scenes); timer automations take fireDate (ISO-8601) and optional recurrence; event automations take events and optional sceneId and executeOnce. Automations are created DISABLED — arming is a separate set_trigger_state approval. Zone names are unique per home.",
            inputSchema: objectSchema(
                [
                    "kind": stringProperty("room, zone, scene, group, timer, or event."),
                    "homeId": stringProperty("The home to create the object in."),
                    "name": stringProperty("The new object's name."),
                    "accessoryIds": stringArrayProperty("Group creation: the accessories to group."),
                    "actions": sceneActionsProperty,
                    "fireDate": stringProperty("Timer creation: the fire date, ISO-8601."),
                    "recurrence": recurrenceProperty,
                    "events": triggerEventsProperty("Event creation: the events that fire the automation."),
                    "sceneId": stringProperty("Event creation: an optional scene to run."),
                    "executeOnce": boolProperty("Event creation: true to run the scene only once."),
                ],
                required: ["kind", "homeId", "name"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)
        ),
        Tool(
            name: "update",
            description: "Replace an object's complete contents: groups take members (accessory ids), zones take rooms, scenes take actions (characteristic writes). Anything absent from the list is removed. Trigger edits use their own tools.",
            inputSchema: objectSchema(
                [
                    "entityId": stringProperty("The group, zone, or scene to update."),
                    "members": stringArrayProperty("Groups: the complete accessory list."),
                    "rooms": stringArrayProperty("Zones: the complete room list."),
                    "actions": sceneActionsProperty,
                ],
                required: ["entityId"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)
        ),
        Tool(
            name: "rename",
            description: "Rename a room, zone, scene, accessory group, or accessory.",
            inputSchema: objectSchema(
                [
                    "entityId": stringProperty("The object to rename."),
                    "newName": stringProperty("The object's new name."),
                ],
                required: ["entityId", "newName"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)
        ),
        Tool(
            name: "delete",
            description: "DESTRUCTIVE. Remove an object from the home: a room, zone, scene, accessory group, trigger, or an accessory. Per-type consequences — where a room's accessories go, which triggers a deleted scene leaves behind — appear on the review card.",
            inputSchema: objectSchema(
                ["entityId": stringProperty("The object to delete.")],
                required: ["entityId"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false, destructiveHint: true)
        ),
    ]

    /// Reads an optional MCP string array; nil when the value is absent or
    /// holds non-strings — the caller distinguishes presence from validity.
    public static func stringList(_ value: Value?) -> [String]? {
        guard let array = value?.arrayValue else { return nil }
        let strings = array.compactMap(\.stringValue)
        return strings.count == array.count ? strings : nil
    }

    // MARK: - Search

    public struct SearchResults: Codable, Sendable, Equatable {
        public struct Match: Codable, Sendable, Equatable {
            public var type: String
            public var id: String
            public var name: String

            init(kind: DetailKind, id: String, name: String) {
                self.type = kind.rawValue
                self.id = id
                self.name = name
            }
        }

        public var results: [Match]
    }

    /// Case-insensitive contains across rooms, zones, scenes, groups,
    /// triggers, and accessories, in graph order — deterministic so a
    /// scripted disambiguation test sees stable output.
    public static func search(query: String, graph: HomeGraph) -> SearchResults {
        let needle = query.lowercased()
        var matches: [Match] = []
        for home in graph.homes {
            for room in home.rooms where room.name.lowercased().contains(needle) {
                matches.append(Match(kind: .room, id: room.id, name: room.name))
            }
            for zone in home.zones where zone.name.lowercased().contains(needle) {
                matches.append(Match(kind: .zone, id: zone.id, name: zone.name))
            }
            for scene in home.scenes where scene.name.lowercased().contains(needle) {
                matches.append(Match(kind: .scene, id: scene.id, name: scene.name))
            }
            for group in home.serviceGroups where group.name.lowercased().contains(needle) {
                matches.append(Match(kind: .group, id: group.id, name: group.name))
            }
            for trigger in home.triggers where trigger.name.lowercased().contains(needle) {
                matches.append(Match(kind: .trigger, id: trigger.id, name: trigger.name))
            }
            for room in home.rooms {
                for accessory in room.accessories where accessory.name.lowercased().contains(needle) {
                    matches.append(Match(kind: .accessory, id: accessory.id, name: accessory.name))
                }
            }
        }
        return SearchResults(results: matches)
    }

    // MARK: - Details

    /// No arguments → the lean whole-home summary; kind + id → one object
    /// in full. Unknown ids and kinds throw `AgentSurfaceError`, which the
    /// dispatcher converts to an in-band tool error.
    public static func details(kind: String?, id: String?, graph: HomeGraph) throws -> LeanSummaryOrFull {
        switch (kind?.lowercased(), id) {
        case (nil, nil):
            return .leanSummary(LeanSummary(homes: graph.homes))
        case (nil, _), (_, nil):
            throw AgentSurfaceError("Provide kind and id together, or neither.")
        case (let kindRaw?, let id?):
            guard let kind = DetailKind(rawValue: kindRaw) else {
                throw AgentSurfaceError(
                    "Unknown kind \(kindRaw) — use home, room, zone, scene, group, trigger, or accessory."
                )
            }
            return .fullObject(try fullDetails(kind: kind, id: id, graph: graph))
        }
    }

    public enum LeanSummaryOrFull: Encodable, Sendable {
        case leanSummary(LeanSummary)
        case fullObject(any Encodable & Sendable)
    }

    public struct AgentSurfaceError: Error, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    /// Fixed-shape lean summary: no characteristics anywhere — a Syracuse
    /// (71 accessories, 1,179 characteristics) must stay small enough for
    /// the on-device window.
    public struct LeanSummary: Codable, Sendable, Equatable {
        public struct HomeBlock: Codable, Sendable, Equatable {
            public struct NameRef: Codable, Sendable, Equatable {
                public var id: String
                public var name: String
                init(_ id: String, _ name: String) { self.id = id; self.name = name }
            }

            public struct Counts: Codable, Sendable, Equatable {
                public var rooms: Int
                public var accessories: Int
                public var scenes: Int
                public var groups: Int
                public var triggers: Int
            }

            public struct RoomLine: Codable, Sendable, Equatable {
                public var id: String
                public var name: String
                public var accessories: [NameRef]
            }

            public struct ZoneLine: Codable, Sendable, Equatable {
                public var id: String
                public var name: String
                public var rooms: [NameRef]
            }

            public struct SceneLine: Codable, Sendable, Equatable {
                public var id: String
                public var name: String
                public var actions: Int
            }

            public struct GroupLine: Codable, Sendable, Equatable {
                public var id: String
                public var name: String
                public var accessories: [NameRef]
            }

            public struct TriggerLine: Codable, Sendable, Equatable {
                public var id: String
                public var name: String
                public var enabled: Bool
            }

            public var id: String
            public var name: String
            public var homeHubState: String?
            public var counts: Counts
            public var rooms: [RoomLine]
            public var zones: [ZoneLine]
            public var scenes: [SceneLine]
            public var groups: [GroupLine]
            public var triggers: [TriggerLine]
        }

        public var homes: [HomeBlock]

        init(homes: [HomeGraph.Home]) {
            self.homes = homes.map { home in
                let accessories = home.rooms.flatMap(\.accessories)
                let zoneRooms: [String: String] = Dictionary(
                    uniqueKeysWithValues: home.rooms.map { ($0.id, $0.name) }
                )
                return HomeBlock(
                    id: home.id,
                    name: home.name,
                    homeHubState: home.homeHubState,
                    counts: HomeBlock.Counts(
                        rooms: home.rooms.count,
                        accessories: accessories.count,
                        scenes: home.scenes.count,
                        groups: home.serviceGroups.count,
                        triggers: home.triggers.count
                    ),
                    rooms: home.rooms.map {
                        HomeBlock.RoomLine(
                            id: $0.id, name: $0.name,
                            accessories: $0.accessories.map { HomeBlock.NameRef($0.id, $0.name) }
                        )
                    },
                    zones: home.zones.map {
                        HomeBlock.ZoneLine(
                            id: $0.id, name: $0.name,
                            rooms: $0.roomIds.compactMap { zoneRooms[$0] }.map { HomeBlock.NameRef("", $0) }
                        )
                    },
                    scenes: home.scenes.map {
                        HomeBlock.SceneLine(id: $0.id, name: $0.name, actions: $0.actions.count)
                    },
                    groups: home.serviceGroups.map {
                        HomeBlock.GroupLine(
                            id: $0.id, name: $0.name,
                            accessories: $0.services.compactMap { service in
                                guard let accessoryName = service.accessoryName else { return nil }
                                return HomeBlock.NameRef(service.accessoryId ?? "", accessoryName)
                            }
                        )
                    },
                    triggers: home.triggers.map {
                        HomeBlock.TriggerLine(id: $0.id, name: $0.name, enabled: $0.isEnabled)
                    }
                )
            }
        }
    }

    private static func fullDetails(kind: DetailKind, id: String, graph: HomeGraph) throws -> any Encodable & Sendable {
        struct RoomDetail: Encodable, Sendable {
            var id: String
            var homeId: String
            var homeName: String
            var name: String
            var zones: [String]
            var accessories: [HomeGraph.Accessory]
        }
        struct GroupDetail: Encodable, Sendable {
            var id: String
            var homeId: String
            var homeName: String
            var name: String
            var accessories: [HomeGraph.Accessory]
        }

        for home in graph.homes {
            if kind == .home, home.id == id { return .leanSummary(LeanSummary(homes: [home])) }
            if let room = home.rooms.first(where: { $0.id == id }), kind == .room {
                return RoomDetail(
                    id: room.id, homeId: home.id, homeName: home.name, name: room.name,
                    zones: home.zones.filter { $0.roomIds.contains(room.id) }.map(\.name),
                    accessories: room.accessories
                )
            }
            if let zone = home.zones.first(where: { $0.id == id }), kind == .zone { return zone }
            if let scene = home.scenes.first(where: { $0.id == id }), kind == .scene { return scene }
            if let group = home.serviceGroups.first(where: { $0.id == id }), kind == .group {
                let groupedAccessoryIds = Set(group.services.compactMap(\.accessoryId))
                return GroupDetail(
                    id: group.id, homeId: home.id, homeName: home.name, name: group.name,
                    accessories: home.rooms.flatMap(\.accessories)
                        .filter { groupedAccessoryIds.contains($0.id) }
                )
            }
            if let trigger = home.triggers.first(where: { $0.id == id }), kind == .trigger { return trigger }
            if let accessory = home.rooms.flatMap(\.accessories).first(where: { $0.id == id }),
                kind == .accessory
            {
                return accessory
            }
        }
        throw AgentSurfaceError("No \(kind.rawValue) \(id).")
    }

    // MARK: - Entity resolution (rename / delete / update)

    /// Looks an entity id up across every kind the unified surface names.
    public static func resolve(entityId: String, graph: HomeGraph) -> ResolvedEntity? {
        for home in graph.homes {
            if let room = home.rooms.first(where: { $0.id == entityId }) {
                return .room(homeId: home.id, id: room.id, name: room.name)
            }
            if let zone = home.zones.first(where: { $0.id == entityId }) {
                return .zone(homeId: home.id, id: zone.id, name: zone.name)
            }
            if let scene = home.scenes.first(where: { $0.id == entityId }) {
                return .scene(homeId: home.id, id: scene.id, name: scene.name)
            }
            if let group = home.serviceGroups.first(where: { $0.id == entityId }) {
                return .accessoryGroup(homeId: home.id, id: group.id, name: group.name)
            }
            if let trigger = home.triggers.first(where: { $0.id == entityId }) {
                return .trigger(homeId: home.id, id: trigger.id, name: trigger.name)
            }
            if let accessory = home.rooms.flatMap(\.accessories).first(where: { $0.id == entityId }) {
                return .accessory(homeId: home.id, id: accessory.id, name: accessory.name)
            }
        }
        return nil
    }

    /// Maps accessories to their controllable service so grouping speaks
    /// accessories while the registry speaks services. An accessory's
    /// controllable service is its primary service: the first service that
    /// is not the Accessory Information service. Multi-service accessories
    /// group by that primary service — the documented simplification.
    public static func controllableServices(for accessoryIds: [String], graph: HomeGraph) -> (resolved: [String], missing: [String]) {
        var resolved: [String] = []
        var missing: [String] = []
        for accessoryId in accessoryIds {
            let accessory = graph.homes.flatMap(\.rooms).flatMap(\.accessories)
                .first(where: { $0.id == accessoryId })
            guard let primary = primaryService(of: accessory) else {
                missing.append(accessoryId)
                continue
            }
            resolved.append(primary)
        }
        return (resolved, missing)
    }

    private static func primaryService(of accessory: HomeGraph.Accessory?) -> String? {
        guard let accessory else { return nil }
        let controllable = accessory.services.filter { !isAccessoryInformation($0) }
        return (controllable.first ?? accessory.services.first)?.id
    }

    private static func isAccessoryInformation(_ service: HomeGraph.AccessoryService) -> Bool {
        if service.name.caseInsensitiveCompare("Accessory Information") == .orderedSame { return true }
        guard let type = service.serviceType?.lowercased() else { return false }
        // Full HomeKit service UUID "0000003E-0000-1000-8000-0026BB765291"
        // or the short form "00003E".
        return type.contains("0000003e") || type == "00003e"
    }

    // MARK: - Schema DSL

    private static func objectSchema(_ properties: [String: Value], required: [String]) -> Value {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
        ])
    }

    private static func stringProperty(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func boolProperty(_ description: String) -> Value {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    private static func stringArrayProperty(_ description: String) -> Value {
        .object([
            "type": .string("array"),
            "items": .object(["type": .string("string")]),
            "description": .string(description),
        ])
    }

    /// Identical element shape to the registries' scene-actions property so
    /// a scene built through `create` or `update` reads the same as one
    /// built through the MCP registry tools.
    private static let sceneActionsProperty: Value = .object([
        "type": .string("array"),
        "items": .object([
            "type": .string("object"),
            "properties": .object([
                "accessoryId": .object([
                    "type": .string("string"),
                    "description": .string("The accessory whose service is written."),
                ]),
                "service": .object([
                    "type": .string("string"),
                    "description": .string("Optional service name or type; defaults to the accessory's primary service."),
                ]),
                "characteristic": .object([
                    "type": .string("string"),
                    "description": .string("The characteristic type to write, e.g. On or Brightness."),
                ]),
                "value": .object([
                    "description": .string("The target value: number, string, or boolean."),
                ]),
            ]),
            "required": .array([.string("accessoryId"), .string("characteristic"), .string("value")]),
        ]),
        "description": .string("Every characteristic write the scene should perform."),
    ])

    private static let recurrenceProperty: Value = .object([
        "type": .string("object"),
        "description": .string("Optional recurrence for a timer automation: either {intervalMinutes} or {weekdays: [1-7]} — 1 is Sunday."),
    ])

    private static func triggerEventsProperty(_ description: String) -> Value {
        .object([
            "type": .string("array"),
            "items": .object([
                "type": .string("object"),
                "description": .string(
                    "Either a characteristic event {accessoryId, characteristic, value?} — value omitted means the event fires on any change — or a presence event {presence: \"atHome\" | \"away\"}."
                ),
                "properties": .object([
                    "accessoryId": .object([
                        "type": .string("string"),
                        "description": .string("The accessory whose characteristic is watched."),
                    ]),
                    "characteristic": .object([
                        "type": .string("string"),
                        "description": .string("The characteristic type to watch, e.g. On or MotionDetected."),
                    ]),
                    "value": .object([
                        "description": .string("Optional threshold value: number, string, or boolean."),
                    ]),
                    "presence": .object([
                        "type": .string("string"),
                        "description": .string("\"atHome\" or \"away\" — HomeKit evaluates presence itself; Niles never requests location access."),
                    ]),
                ]),
            ]),
            "description": .string(description),
        ])
    }
}
