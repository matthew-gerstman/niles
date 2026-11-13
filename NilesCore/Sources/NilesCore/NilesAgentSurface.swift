import Foundation
import MCP

/// The agent-facing tool surface — the compacted vocabulary the on-device
/// model sees (spec art_VrC0iUUA §What we should build; catalog draft
/// art_yvbPAfG9, v9).
///
/// Two of the eight tools are the registries' own tools passed through;
/// the six here (search, get_details, create, update, rename, delete) are
/// adapter-shaped: they translate the agent's vocabulary — accessory
/// groups, entity ids, kind-based creation — onto registry primitives and
/// never appear in the MCP server's tool list. The registries keep their
/// full per-type surfaces for MCP clients.
///
/// Every adapter description references the owning registry's shared
/// description static — one plain-language text per tool, both projections
/// (art_34OYtrUm). Payload vocabulary that differs between the surfaces is
/// described on each schema's own arguments.
public enum NilesAgentSurface {

    /// Kinds for `get_details` deep reads and search-result typing.
    public enum DetailKind: String, Sendable, CaseIterable {
        case home, room, zone, scene, group, trigger, accessory
    }

    /// Kinds for `create` (v9: automations are out of the agent's scope).
    public enum CreateKind: String, Sendable, CaseIterable {
        case room, zone, scene, group
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

    /// The six adapter tools, in catalog order. The other two agent tools
    /// (get_proposal, assign_accessory_to_room) pass through with their
    /// registry definitions; the dispatcher assembles the full list.
    public static let adapterDefinitions: [Tool] = [
        Tool(
            name: "search",
            description: ReadToolRegistry.searchDescription,
            inputSchema: objectSchema(
                ["query": stringProperty(Self.queryDescription)],
                required: ["query"]
            ),
            annotations: Tool.Annotations(readOnlyHint: true)
        ),
        Tool(
            name: "get_details",
            description: ReadToolRegistry.getDetailsDescription,
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
            description: WriteToolRegistry.createDescription,
            inputSchema: objectSchema(
                [
                    "kind": stringProperty("room, zone, scene, or group."),
                    "homeId": stringProperty("The home to create the object in."),
                    "name": stringProperty("The new object's name."),
                    "accessoryIds": stringArrayProperty("Group creation: the accessories to group."),
                    "actions": sceneActionsProperty,
                ],
                required: ["kind", "homeId", "name"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)
        ),
        Tool(
            name: "update",
            description: WriteToolRegistry.updateDescription,
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
            description: WriteToolRegistry.renameDescription,
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
            description: WriteToolRegistry.deleteDescription,
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
            /// The room an accessory sits in — the extra context a match
            /// via room name or service type needs to be recognizable.
            /// Nil for the non-accessory kinds.
            public var roomName: String?

            init(kind: DetailKind, id: String, name: String, roomName: String? = nil) {
                self.type = kind.rawValue
                self.id = id
                self.name = name
                self.roomName = roomName
            }
        }

        public var results: [Match]
    }

    // MARK: - Tokenized query matching (shared by both search projections)

    /// The `query` argument's description — one text for both search
    /// projections (the registry's own and the adapter's), so the model
    /// hears the same thing from either surface.
    public static let queryDescription =
        "What to look for — a room, zone, scene, group, trigger, or accessory. Simple terms or a room name work best; multi-word queries are supported (e.g. \"office lights\")."

    /// A natural-language query, split into lowercase terms with the
    /// trailing "s" stripped ("lights" → "light"). A multi-word query
    /// matches an entity when EVERY term matches — so "office lights"
    /// finds lights in the Office instead of failing the whole-string
    /// contains() the old matcher used.
    public static func searchTerms(_ query: String) -> [String] {
        query.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .map { term in
                if term.count > 3, term.hasSuffix("ies") { return String(term.dropLast(3)) + "y" }
                if term.count > 3, term.hasSuffix("ches") || term.hasSuffix("shes")
                    || term.hasSuffix("sses") || term.hasSuffix("xes") {
                    return String(term.dropLast(2))
                }
                if term.count > 1, term.hasSuffix("s"), !term.hasSuffix("ss") {
                    return String(term.dropLast())
                }
                return term
            }
    }

    /// Whole-entity name matching: every term must appear in the name.
    public static func nameMatches(_ terms: [String], name: String) -> Bool {
        let lowered = name.lowercased()
        return terms.allSatisfy { lowered.contains($0) }
    }

    /// Accessory matching: every term must match any of the accessory's
    /// own name, its owning room's name, or a plain keyword for one of its
    /// service types ("light" → Lightbulb service) — so "office lights"
    /// reaches a Lightbulb named Office Lights from either direction.
    public static func accessoryMatches(
        _ terms: [String], name: String, roomName: String, serviceTypes: [String]
    ) -> Bool {
        let loweredName = name.lowercased()
        let loweredRoom = roomName.lowercased()
        let codes = Set(serviceTypes.compactMap(serviceTypeCode))
        return terms.allSatisfy { term in
            loweredName.contains(term) || loweredRoom.contains(term)
                || !codes.isDisjoint(with: Self.serviceCodes(for: term))
        }
    }

    /// HAP service type (short code, lowercased) → the plain words a
    /// query might use for it. The lightbulb, thermostat, fan, television,
    /// outlet, and motion-sensor codes are confirmed against live captures
    /// where the capture names the service; the rest are from the HAP
    /// specification. Only consulted when a query term equals one of the
    /// words, so an over-broad entry can only ever add a match.
    static let serviceTypeWords: [String: Set<String>] = [
        "00000043": ["light"],         // Lightbulb
        "00000040": ["fan"],            // Fan (deprecated)
        "000000b7": ["fan"],            // FanV2
        "00000044": ["lock"],           // Lock Mechanism
        "00000064": ["lock"],           // Lock Management
        "0000004a": ["thermostat"],     // Thermostat
        "000000bd": ["thermostat"],     // Heater/Cooler
        "00000113": ["speaker"],        // Smart Speaker
        "000000d8": ["tv"],             // Television
        "00000110": ["camera"],         // Camera RTP Stream Management
        "00000112": ["camera"],         // Camera control cluster
        "00000121": ["doorbell"],       // Doorbell
        "00000041": ["garage", "door"], // Garage Door Opener
        "00000047": ["outlet"],         // Outlet
        "00000049": ["switch"],         // Switch
        "00000096": ["switch"],         // Stateful Programmable Switch
        "000000cc": ["switch"],         // Stateless Programmable Switch
        "00000080": ["sensor"],         // Contact Sensor
        "00000085": ["sensor"],         // Motion Sensor
        "00000087": ["sensor"],         // Carbon Monoxide Sensor
        "00000088": ["sensor"],         // Smoke Sensor
        "00000089": ["sensor"],         // Occupancy Sensor
        "0000008a": ["sensor"],         // Humidity Sensor
        "0000008d": ["sensor"],         // Air Quality Sensor
    ]

    /// The service short codes a query term can stand for — the inverse
    /// of `serviceTypeWords`.
    static func serviceCodes(for term: String) -> Set<String> {
        Set(serviceTypeWords.filter { $0.value.contains(term) }.keys)
    }

    /// The lowercase HAP short code of a service type string — full UUID
    /// ("00000043-0000-1000-8000-0026BB765291"), short hex ("00000043"),
    /// or the 0x-prefixed form ("0x0043"). Nil when not a hex type code.
    static func serviceTypeCode(_ serviceType: String) -> String? {
        var lowered = serviceType.lowercased()
        if let dash = lowered.firstIndex(of: "-") { lowered = String(lowered[..<dash]) }
        if lowered.hasPrefix("0x") { lowered = String(lowered.dropFirst(2)) }
        guard !lowered.isEmpty, lowered.count <= 8, lowered.allSatisfy(\.isHexDigit) else { return nil }
        return String(repeating: "0", count: 8 - lowered.count) + lowered
    }

    /// Tokenized matching across rooms, zones, scenes, groups, triggers,
    /// and accessories, in graph order — deterministic so callers see
    /// stable output. Accessories match on name, owning room name, and
    /// service type; every other kind matches on its own name.
    public static func search(query: String, graph: HomeGraph) -> SearchResults {
        let terms = searchTerms(query)
        typealias Match = SearchResults.Match
        var matches: [Match] = []
        for home in graph.homes {
            for room in home.rooms where nameMatches(terms, name: room.name) {
                matches.append(Match(kind: .room, id: room.id, name: room.name))
            }
            for zone in home.zones where nameMatches(terms, name: zone.name) {
                matches.append(Match(kind: .zone, id: zone.id, name: zone.name))
            }
            for scene in home.scenes where nameMatches(terms, name: scene.name) {
                matches.append(Match(kind: .scene, id: scene.id, name: scene.name))
            }
            for group in home.serviceGroups where nameMatches(terms, name: group.name) {
                matches.append(Match(kind: .group, id: group.id, name: group.name))
            }
            for trigger in home.triggers where nameMatches(terms, name: trigger.name) {
                matches.append(Match(kind: .trigger, id: trigger.id, name: trigger.name))
            }
            for room in home.rooms {
                for accessory in room.accessories
                where accessoryMatches(
                    terms,
                    name: accessory.name,
                    roomName: room.name,
                    serviceTypes: accessory.services.compactMap(\.serviceType)
                ) {
                    matches.append(
                        Match(kind: .accessory, id: accessory.id, name: accessory.name, roomName: room.name)
                    )
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
            return try fullDetails(kind: kind, id: id, graph: graph)
        }
    }

    public enum LeanSummaryOrFull: Encodable, Sendable {
        case leanSummary(LeanSummary)
        case fullObject(any Encodable & Sendable)

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .leanSummary(let summary): try container.encode(summary)
            case .fullObject(let object): try container.encode(object)
            }
        }
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

    private static func fullDetails(kind: DetailKind, id: String, graph: HomeGraph) throws -> LeanSummaryOrFull {
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
                return .fullObject(RoomDetail(
                    id: room.id, homeId: home.id, homeName: home.name, name: room.name,
                    zones: home.zones.filter { $0.roomIds.contains(room.id) }.map(\.name),
                    accessories: room.accessories
                ))
            }
            if let zone = home.zones.first(where: { $0.id == id }), kind == .zone { return .fullObject(zone) }
            if let scene = home.scenes.first(where: { $0.id == id }), kind == .scene { return .fullObject(scene) }
            if let group = home.serviceGroups.first(where: { $0.id == id }), kind == .group {
                let groupedAccessoryIds = Set(group.services.compactMap(\.accessoryId))
                return .fullObject(GroupDetail(
                    id: group.id, homeId: home.id, homeName: home.name, name: group.name,
                    accessories: home.rooms.flatMap(\.accessories)
                        .filter { groupedAccessoryIds.contains($0.id) }
                ))
            }
            if let trigger = home.triggers.first(where: { $0.id == id }), kind == .trigger {
                return .fullObject(trigger)
            }
            if let accessory = home.rooms.flatMap(\.accessories).first(where: { $0.id == id }),
                kind == .accessory
            {
                return .fullObject(accessory)
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

}