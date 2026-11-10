import Foundation
import MCP

/// The read-only MCP tools over the home graph, and their dispatch.
///
/// Read tools answer in-band (spec): each call takes one consistent
/// `HomeKitService` snapshot and projects a slice of it — no proposal, no
/// staging.
///
/// Two tools are the consolidated read surface (Blueprint art_34OYtrUm,
/// "Read layer"): `search(query)` resolves names to typed candidates with
/// ids, and `get_details` is lean by default (no-argument: a whole-home
/// summary with no characteristic payloads) and full per object
/// (kind + id), capped — an oversized deep read comes back explicitly
/// marked truncated, never silently shortened.
///
/// The six per-type tools predate the consolidated surface and stay
/// registered and functional for compatibility; their descriptions mark
/// them deprecated in favor of `search` + `get_details`. All six take no
/// arguments and return their slice across every home.
///
/// The transport layer composes this registry into the MCP server: it wires
/// `tools` into its `tools/list` result and routes `tools/call` for these
/// names to `call(name:arguments:)`.
public struct ReadToolRegistry: Sendable {
    public let service: any HomeKitService

    public init(service: any HomeKitService) {
        self.service = service
    }

    /// The read tools, in listing order.
    public var tools: [Tool] { Self.toolDefinitions }

    /// The names `call` answers.
    public var toolNames: Set<String> {
        // get_rooms is special-cased in call() — its optional filters don't
        // fit the projection table — but it is a served read tool, and the
        // dispatcher routes by name. search and get_details are dispatched
        // in call() the same way: their optional arguments do not fit the
        // no-argument projection table.
        var names = Set(Self.projections.keys)
        names.insert("get_rooms")
        names.insert("search")
        names.insert("get_details")
        return names
    }

    /// The full registry tool definitions — the source of truth the agent
    /// toolset generator projects into session tools.
    public var toolDefinitions: [Tool] { Self.toolDefinitions }

    /// Answers one `tools/call` for a read tool. Unknown tool names and graph
    /// read failures return `isError` results rather than throwing, so the
    /// agent sees the failure in-band.
    public func call(name: String, arguments: [String: Value]? = nil) async -> CallTool.Result {
        do {
            let graph = try await service.snapshot()
            if name == "search" {
                guard let query = arguments?["query"]?.stringValue, !query.isEmpty else {
                    return Self.errorResult(
                        "Invalid arguments: search needs a \"query\" string — the name to look for."
                    )
                }
                return try Self.result(Self.searchView(graph, query: query))
            }
            if name == "get_details" {
                // `detailsView` returns a finished `CallTool.Result` (cap
                // handling can downgrade to an in-band error) — return it
                // directly. Passing it through `result(_:)` would encode the
                // CallTool.Result envelope as the projection, double-wrapping
                // the summary under a "content" key.
                return Self.detailsView(
                    graph,
                    kind: arguments?["kind"]?.stringValue,
                    id: arguments?["id"]?.stringValue
                )
            }
            if name == "get_rooms" {
                let detail = arguments?["detail"]?.stringValue ?? Self.leanDetail
                guard detail == Self.leanDetail || detail == Self.fullDetail else {
                    return Self.errorResult("Invalid arguments: detail must be \"\(Self.leanDetail)\" or \"\(Self.fullDetail)\".")
                }
                return try Self.result(Self.roomsView(
                    graph,
                    detail: detail,
                    roomId: arguments?["roomId"]?.stringValue,
                    accessoryId: arguments?["accessoryId"]?.stringValue
                ))
            }
            guard let project = Self.projections[name] else {
                let known = Self.projections.keys.sorted().joined(separator: ", ")
                return Self.errorResult(
                    "Unknown tool \(name). Available read tools: search, get_details, \(known), get_rooms"
                )
            }
            return try Self.result(project(graph))
        } catch {
            return Self.errorResult("Failed to read the home graph: \(error)")
        }
    }

    // MARK: - Tool definitions

    private static let toolDefinitions: [Tool] = [
        Tool(
            name: "search",
            description: Self.searchDescription,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("The name to look for — a room, zone, scene, group, trigger, or accessory."),
                    ]),
                ]),
                "required": .array([.string("query")]),
            ]),
            annotations: Tool.Annotations(readOnlyHint: true)
        ),
        Tool(
            name: "get_details",
            description: Self.getDetailsDescription,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "kind": .object([
                        "type": .string("string"),
                        "description": .string("home, room, zone, scene, group, trigger, or accessory — required with id."),
                    ]),
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("The object's id — required with kind."),
                    ]),
                ]),
            ]),
            annotations: Tool.Annotations(readOnlyHint: true)
        ),
        Tool(
            name: "get_homes",
            description: "DEPRECATED — prefer search and get_details, which resolve names and read one object at a time instead of returning whole-home slices. Lists every home with counts of its rooms, zones, accessories, scenes, service groups, and triggers, plus each home's home hub state and the app's HomeKit authorization status. Call this first to discover home IDs.",
            inputSchema: emptyObjectSchema,
            annotations: Tool.Annotations(readOnlyHint: true)
        ),
        Tool(
            name: "get_rooms",
            description: "DEPRECATED — prefer search and get_details (kind \"room\"), which read one object at a time. List rooms with their accessories. Default output is LEAN — rooms, zones, and accessories as names and ids only (a whole home in full detail exceeds any model's context window at real-home scale). Pass detail \"full\" to include each accessory's services and characteristics (values and metadata) plus reachability state — check that before staging a characteristic write. Rooms group accessories; zones (see get_zones) group rooms.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "roomId": .object([
                        "type": .string("string"),
                        "description": .string("Optional: return only the room with this id (from a previous lean get_rooms)."),
                    ]),
                    "accessoryId": .object([
                        "type": .string("string"),
                        "description": .string("Optional: return only rooms that contain this accessory."),
                    ]),
                    "detail": .object([
                        "type": .string("string"),
                        "description": .string("Optional: \"lean\" (default) or \"full\". Full adds each accessory's services, characteristics, and state."),
                    ]),
                ]),
            ]),
            annotations: Tool.Annotations(readOnlyHint: true)
        ),
        Tool(
            name: "get_zones",
            description: "DEPRECATED — prefer search and get_details (kind \"zone\"). List zones across all homes with their member rooms. Zones group rooms (e.g. 'Upstairs').",
            inputSchema: emptyObjectSchema,
            annotations: Tool.Annotations(readOnlyHint: true)
        ),
        Tool(
            name: "get_scenes",
            description: "DEPRECATED — prefer search and get_details (kind \"scene\"). List scenes (HomeKit action sets) with their characteristic-write actions, target values, and when each last ran (lastExecutionDate).",
            inputSchema: emptyObjectSchema,
            annotations: Tool.Annotations(readOnlyHint: true)
        ),
        Tool(
            name: "get_service_groups",
            description: "DEPRECATED — prefer search and get_details (kind \"group\"). List service groups with their member services — services, not accessories; each service names the accessory that provides it (e.g. one 'Desk Lamps' group spanning several lamps).",
            inputSchema: emptyObjectSchema,
            annotations: Tool.Annotations(readOnlyHint: true)
        ),
        Tool(
            name: "get_triggers",
            description: "DEPRECATED — prefer search and get_details (kind \"trigger\"), which also carry end events, execute-once, and the structured presence read with its readable flag. List automations with their enabled state, event-trigger activation state (why an event trigger is or is not active — e.g. no home hub), timer triggers (fire date + recurrence), and event triggers (characteristic events + optional predicate).",
            inputSchema: emptyObjectSchema,
            annotations: Tool.Annotations(readOnlyHint: true)
        ),
    ]

    private static let emptyObjectSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([:]),
    ])

    /// Shared plain-language descriptions — the compact text proven in the
    /// v9 agent catalog, carried so both projections say the same thing
    /// about the same tool (the MCP server lists it verbatim).
    static let searchDescription =
        "Find objects by name across the home: rooms, zones, scenes, accessory groups, triggers, and accessories. The user's words may name any of these; when several match, ask which one they mean."
    static let getDetailsDescription =
        "Read home state. No arguments: a lean whole-home summary — homes with counts, rooms with accessory names, zones, scenes, groups, and triggers, without characteristics. With kind and id: one object in full, including its characteristics. Deep reads are capped; an oversized one comes back explicitly marked truncated, never silently shortened."

    /// Maximum characters a single read response may serialize. The lean
    /// summary for a Syracuse-scale home (71 accessories / 1,179
    /// characteristics) stays well under this; a deep read that does not
    /// fit comes back explicitly marked truncated instead.
    static let responseCap = 20_000

    /// Maximum search hits returned before the list is marked truncated.
    static let searchResultCap = 50

    /// Kinds `get_details(kind, id)` reads one object of.
    enum DetailKind: String, Sendable, CaseIterable {
        case home, room, zone, scene, group, trigger, accessory
    }

    // MARK: - Consolidated read surface (search / get_details)

    struct SearchProjection: Codable, Sendable, Equatable {
        var query: String
        var results: [SearchHit]
        /// True when more matches existed than the result cap — the list is
        /// incomplete, not the home.
        var truncated: Bool?
        var note: String?
    }

    /// One typed candidate: the id a write tool needs, the kind that says
    /// which tool, and where the object lives. Ambiguous names surface as
    /// several hits — the caller's signal to ask the human which one.
    struct SearchHit: Codable, Sendable, Equatable {
        var kind: String
        var id: String
        var name: String
        var homeId: String
        var homeName: String
        /// A one-line qualifier — the room an accessory sits in, a zone's
        /// room count, a trigger's enabled state.
        var context: String?
    }

    private static func searchView(_ graph: HomeGraph, query: String) -> SearchProjection {
        let needle = query.lowercased()
        var hits: [SearchHit] = []
        var overflow = false
        func add(_ hit: SearchHit) {
            if hits.count >= Self.searchResultCap {
                overflow = true
            } else {
                hits.append(hit)
            }
        }
        for home in graph.homes {
            for room in home.rooms where room.name.lowercased().contains(needle) {
                add(SearchHit(
                    kind: "room", id: room.id, name: room.name, homeId: home.id, homeName: home.name,
                    context: "\(room.accessories.count) accessories"
                ))
            }
            for zone in home.zones where zone.name.lowercased().contains(needle) {
                add(SearchHit(
                    kind: "zone", id: zone.id, name: zone.name, homeId: home.id, homeName: home.name,
                    context: "zone of \(zone.roomIds.count) rooms"
                ))
            }
            for scene in home.scenes where scene.name.lowercased().contains(needle) {
                add(SearchHit(
                    kind: "scene", id: scene.id, name: scene.name, homeId: home.id, homeName: home.name,
                    context: "scene with \(scene.actions.count) actions"
                ))
            }
            for group in home.serviceGroups where group.name.lowercased().contains(needle) {
                add(SearchHit(
                    kind: "group", id: group.id, name: group.name, homeId: home.id, homeName: home.name,
                    context: "group of \(group.services.count) services"
                ))
            }
            for trigger in home.triggers where trigger.name.lowercased().contains(needle) {
                add(SearchHit(
                    kind: "trigger", id: trigger.id, name: trigger.name, homeId: home.id, homeName: home.name,
                    context: trigger.isEnabled ? "enabled automation" : "disabled automation"
                ))
            }
            for room in home.rooms {
                for accessory in room.accessories where accessory.name.lowercased().contains(needle) {
                    add(SearchHit(
                        kind: "accessory", id: accessory.id, name: accessory.name,
                        homeId: home.id, homeName: home.name,
                        context: "in room \(room.name)"
                    ))
                }
            }
        }
        return SearchProjection(
            query: query,
            results: hits,
            truncated: overflow ? true : nil,
            note: overflow
                ? "More than \(Self.searchResultCap) matches — refine the query to see the rest."
                : nil
        )
    }

    /// The no-argument `get_details` shape: the lean whole-home summary. No
    /// characteristic payloads anywhere — rooms list accessories as names
    /// and ids, scenes as action counts — so a Syracuse-scale home fits any
    /// model's context window.
    struct SummaryProjection: Codable, Sendable, Equatable {
        var homes: [HomeOverview]
        var authorizationStatus: String?
    }

    struct HomeOverview: Codable, Sendable, Equatable {
        var id: String
        var name: String
        var homeHubState: String?
        var counts: Counts
        var rooms: [RoomLine]
        var zones: [ZoneLine]
        var scenes: [SceneLine]
        var serviceGroups: [GroupLine]
        var triggers: [TriggerLine]

        struct Counts: Codable, Sendable, Equatable {
            var rooms: Int
            var zones: Int
            var accessories: Int
            var scenes: Int
            var serviceGroups: Int
            var triggers: Int
        }

        struct NameRef: Codable, Sendable, Equatable {
            var id: String
            var name: String
        }

        struct RoomLine: Codable, Sendable, Equatable {
            var id: String
            var name: String
            var accessories: [NameRef]
        }

        struct ZoneLine: Codable, Sendable, Equatable {
            var id: String
            var name: String
            var rooms: [NameRef]
        }

        struct SceneLine: Codable, Sendable, Equatable {
            var id: String
            var name: String
            var actions: Int
        }

        struct GroupLine: Codable, Sendable, Equatable {
            var id: String
            var name: String
            var services: [NameRef]
        }

        struct TriggerLine: Codable, Sendable, Equatable {
            var id: String
            var name: String
            var enabled: Bool
            /// "timer", "event", or the unsupported kind's debug name —
            /// what a follow-up `get_details(kind: "trigger")` will find.
            var kind: String

            init(id: String, name: String, enabled: Bool, detail: HomeGraph.Trigger.Detail) {
                self.id = id
                self.name = name
                self.enabled = enabled
                switch detail {
                case .timer: self.kind = "timer"
                case .event: self.kind = "event"
                case .unknown(let kindName): self.kind = kindName
                }
            }
        }

        init(_ home: HomeGraph.Home) {
            let roomNames = Dictionary(uniqueKeysWithValues: home.rooms.map { ($0.id, $0.name) })
            self.id = home.id
            self.name = home.name
            self.homeHubState = home.homeHubState
            self.counts = Counts(
                rooms: home.rooms.count,
                zones: home.zones.count,
                accessories: home.rooms.reduce(0) { $0 + $1.accessories.count },
                scenes: home.scenes.count,
                serviceGroups: home.serviceGroups.count,
                triggers: home.triggers.count
            )
            self.rooms = home.rooms.map {
                RoomLine(
                    id: $0.id, name: $0.name,
                    accessories: $0.accessories.map { NameRef(id: $0.id, name: $0.name) }
                )
            }
            self.zones = home.zones.map {
                ZoneLine(
                    id: $0.id, name: $0.name,
                    rooms: $0.roomIds.compactMap { roomId in
                        roomNames[roomId].map { NameRef(id: roomId, name: $0) }
                    }
                )
            }
            self.scenes = home.scenes.map {
                SceneLine(id: $0.id, name: $0.name, actions: $0.actions.count)
            }
            self.serviceGroups = home.serviceGroups.map {
                GroupLine(
                    id: $0.id, name: $0.name,
                    services: $0.services.map { NameRef(id: $0.id, name: $0.name) }
                )
            }
            self.triggers = home.triggers.map {
                TriggerLine(id: $0.id, name: $0.name, enabled: $0.isEnabled, detail: $0.detail)
            }
        }
    }

    /// One object in full — the `get_details(kind, id)` shape. `truncated`
    /// true (with a `note`) means deep payloads were dropped to fit the
    /// response cap; the object above is incomplete, and the note says what
    /// is gone.
    struct FullObject<T: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
        var kind: String
        var id: String
        var truncated: Bool?
        var note: String?
        var object: T
    }

    /// The reduced accessory read: identity and state, with counts standing
    /// in for the service and characteristic lists — what a deep read
    /// collapses to when its full form exceeds the response cap.
    struct AccessoryOverview: Codable, Sendable, Equatable {
        var id: String
        var name: String
        var reachable: Bool?
        var bridged: Bool?
        var category: String?
        var firmwareVersion: String?
        var serviceCount: Int
        var characteristicCount: Int

        init(_ accessory: HomeGraph.Accessory) {
            self.id = accessory.id
            self.name = accessory.name
            self.reachable = accessory.reachable
            self.bridged = accessory.bridged
            self.category = accessory.category
            self.firmwareVersion = accessory.firmwareVersion
            self.serviceCount = accessory.services.count
            self.characteristicCount = accessory.services.reduce(0) { $0 + $1.characteristics.count }
        }
    }

    /// An accessory read with its place in the home.
    struct AccessoryDetail<Accessory: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
        var id: String
        var homeId: String
        var homeName: String
        var roomId: String
        var roomName: String
        var accessory: Accessory
    }

    /// `get_details` dispatch: no arguments → the lean summary; kind + id →
    /// one object in full. Returns a `CallTool.Result` because cap handling
    /// can downgrade to an in-band error (never a silent shortening).
    private static func detailsView(_ graph: HomeGraph, kind: String?, id: String?) -> CallTool.Result {
        switch (kind?.lowercased(), id) {
        case (nil, nil):
            return Self.cappedResult(
                SummaryProjection(
                    homes: graph.homes.map(HomeOverview.init),
                    authorizationStatus: graph.authorizationStatus
                ),
                hint: "Use search and get_details with kind and id to read one object at a time."
            )
        case (nil, _), (_, nil):
            return Self.errorResult("Invalid arguments: provide kind and id together, or neither.")
        case (let kindRaw?, let id?):
            guard let kind = DetailKind(rawValue: kindRaw) else {
                let known = DetailKind.allCases.map(\.rawValue).joined(separator: ", ")
                return Self.errorResult("Unknown kind \\(kindRaw) — use \\(known).")
            }
            return Self.objectDetails(graph, kind: kind, id: id)
        }
    }

    private static func objectDetails(_ graph: HomeGraph, kind: DetailKind, id: String) -> CallTool.Result {
        for home in graph.homes {
            if kind == .home, home.id == id {
                return Self.cappedResult(
                    HomeOverview(home),
                    hint: "Use search and get_details with kind and id to read one object at a time."
                )
            }
            if let room = home.rooms.first(where: { $0.id == id }), kind == .room {
                let zone = home.zones.first { $0.roomIds.contains(room.id) }
                return Self.reducedResult(
                    full: RoomSummary(
                        id: room.id, homeId: home.id, homeName: home.name, name: room.name,
                        zoneId: zone?.id, zoneName: zone?.name,
                        accessories: room.accessories
                    ),
                    reduced: RoomSummary(
                        id: room.id, homeId: home.id, homeName: home.name, name: room.name,
                        zoneId: zone?.id, zoneName: zone?.name,
                        accessories: room.accessories.map(AccessoryOverview.init)
                    ),
                    kind: kind.rawValue, id: id,
                    note: "Characteristics were dropped to fit the response cap — each accessory lists service and characteristic counts. Read one accessory at a time for full detail."
                )
            }
            if let accessoryIndex = home.rooms.enumerated().first(where: { _, room in
                room.accessories.contains { $0.id == id }
            }),
                kind == .accessory,
                let accessory = home.rooms[accessoryIndex.offset].accessories.first(where: { $0.id == id })
            {
                let room = home.rooms[accessoryIndex.offset]
                return Self.reducedResult(
                    full: AccessoryDetail(
                        id: accessory.id, homeId: home.id, homeName: home.name,
                        roomId: room.id, roomName: room.name, accessory: accessory
                    ),
                    reduced: AccessoryDetail(
                        id: accessory.id, homeId: home.id, homeName: home.name,
                        roomId: room.id, roomName: room.name, accessory: AccessoryOverview(accessory)
                    ),
                    kind: kind.rawValue, id: id,
                    note: "Services and characteristics were dropped to fit the response cap — counts stand in for the lists. Narrow to one service through get_rooms(detail: \"full\", roomId:) if you need the payloads."
                )
            }
            if let zone = home.zones.first(where: { $0.id == id }), kind == .zone {
                let roomIds = Set(zone.roomIds)
                return Self.cappedResult(
                    ZoneSummary(
                        id: zone.id, homeId: home.id, homeName: home.name, name: zone.name,
                        rooms: home.rooms.filter { roomIds.contains($0.id) }.map { RoomRef(id: $0.id, name: $0.name) }
                    ),
                    hint: "Read the member rooms with get_details(kind: \"room\", id:)."
                )
            }
            if let scene = home.scenes.first(where: { $0.id == id }), kind == .scene {
                return Self.cappedResult(
                    SceneSummary(
                        id: scene.id, homeId: home.id, homeName: home.name, name: scene.name,
                        type: scene.type, lastExecutionDate: scene.lastExecutionDate, actions: scene.actions
                    ),
                    hint: "Read the actions' accessories with get_details(kind: \"accessory\", id:)."
                )
            }
            if let group = home.serviceGroups.first(where: { $0.id == id }), kind == .group {
                return Self.cappedResult(
                    ServiceGroupSummary(
                        id: group.id, homeId: home.id, homeName: home.name, name: group.name,
                        services: group.services
                    ),
                    hint: "Read a member accessory with get_details(kind: \"accessory\", id:)."
                )
            }
            if let trigger = home.triggers.first(where: { $0.id == id }), kind == .trigger {
                return Self.cappedResult(
                    TriggerSummary(
                        id: trigger.id, homeId: home.id, homeName: home.name, name: trigger.name,
                        isEnabled: trigger.isEnabled,
                        triggerActivationState: trigger.triggerActivationState,
                        activationStateName: trigger.triggerActivationState.map {
                            HomeManagerHomeKitService.activationStateDescription(rawValue: $0)
                        },
                        detail: trigger.detail
                    ),
                    hint: ""
                )
            }
        }
        return Self.errorResult("No \\(kind.rawValue) \\(id).")
    }

    /// Encodes `projection` and enforces the response cap: an oversized
    /// payload returns as an in-band error naming the cap — never silently
    /// shortened. The `hint` says how to narrow the read.
    private static func cappedResult(_ projection: some Codable & Sendable, hint: String) -> CallTool.Result {
        do {
            let data = try encoder.encode(projection)
            guard data.count <= responseCap else {
                return Self.errorResult(
                    "Response exceeds the \\(responseCap)-character cap (\\(data.count) characters) and was not returned. \\(hint)"
                )
            }
            return try Self.textResult(data)
        } catch {
            return Self.errorResult("Failed to encode the read result: \\(error)")
        }
    }

    /// Encodes the full deep read; when it exceeds the response cap, encodes
    /// the reduced form and marks it truncated — never silently shortened.
    private static func reducedResult<Full: Codable & Sendable & Equatable, Reduced: Codable & Sendable & Equatable>(
        full: Full, reduced: Reduced, kind: String, id: String, note: String
    ) -> CallTool.Result {
        do {
            let fullData = try encoder.encode(FullObject(kind: kind, id: id, truncated: nil, note: nil, object: full))
            guard fullData.count > responseCap else { return try Self.textResult(fullData) }
            let marked = FullObject(kind: kind, id: id, truncated: true, note: note, object: reduced)
            let reducedData = try encoder.encode(marked)
            guard reducedData.count <= responseCap else {
                return Self.errorResult(
                    "Response exceeds the \\(responseCap)-character cap even in reduced form — narrow the read."
                )
            }
            return try Self.textResult(reducedData)
        } catch {
            return Self.errorResult("Failed to encode the read result: \\(error)")
        }
    }

    private static func textResult(_ data: Data) throws -> CallTool.Result {
        // One encode for both channels: the text body and the structured
        // content mirror the same ISO-8601 JSON (the write registry's
        // pattern — the SDK's `Value(_:)` conversion would emit Apple's
        // reference-date doubles).
        let structured = try? JSONDecoder().decode(Value.self, from: data)
        return try CallTool.Result(
            content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)],
            structuredContent: structured ?? .null,
            isError: false
        )
    }

    private static let projections: [String: @Sendable (HomeGraph) throws -> any Codable & Sendable] = [
        "get_homes": homesView,
        "get_zones": zonesView,
        "get_scenes": scenesView,
        "get_service_groups": serviceGroupsView,
        "get_triggers": triggersView,
    ]

    // MARK: - Tool output projections

    struct HomesProjection: Codable, Sendable, Equatable {
        var homes: [HomeSummary]
        /// Manager-level HomeKit authorization for the app ("authorized",
        /// "notDetermined", ...). One grant for the whole app, so it sits
        /// above the per-home summaries.
        var authorizationStatus: String?
    }

    struct HomeSummary: Codable, Sendable, Equatable {
        var id: String
        var name: String
        var homeHubState: String?
        var summary: HomeCounts
    }

    struct HomeCounts: Codable, Sendable, Equatable {
        var rooms: Int
        var zones: Int
        var accessories: Int
        var scenes: Int
        var serviceGroups: Int
        var triggers: Int
    }

    struct RoomsProjection<Accessory: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
        var rooms: [RoomSummary<Accessory>]
    }

    struct RoomSummary<Accessory: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
        var id: String
        var homeId: String
        var homeName: String
        var name: String
        var zoneId: String?
        var zoneName: String?
        var accessories: [Accessory]
    }

    /// The lean accessory shape: names and ids only. The default `get_rooms`
    /// depth — a whole home in full detail does not fit the on-device model's
    /// context window.
    struct AccessoryRef: Codable, Sendable, Equatable {
        var id: String
        var name: String
    }

    struct ZonesProjection: Codable, Sendable, Equatable {
        var zones: [ZoneSummary]
    }

    struct ZoneSummary: Codable, Sendable, Equatable {
        var id: String
        var homeId: String
        var homeName: String
        var name: String
        var rooms: [RoomRef]
    }

    struct RoomRef: Codable, Sendable, Equatable {
        var id: String
        var name: String
    }

    struct ScenesProjection: Codable, Sendable, Equatable {
        var scenes: [SceneSummary]
    }

    struct SceneSummary: Codable, Sendable, Equatable {
        var id: String
        var homeId: String
        var homeName: String
        var name: String
        var type: String?
        /// When the scene last ran; nil when never run.
        var lastExecutionDate: Date?
        var actions: [HomeGraph.SceneAction]
    }

    struct ServiceGroupsProjection: Codable, Sendable, Equatable {
        var serviceGroups: [ServiceGroupSummary]
    }

    struct ServiceGroupSummary: Codable, Sendable, Equatable {
        var id: String
        var homeId: String
        var homeName: String
        var name: String
        var services: [HomeGraph.ServiceRef]
    }

    struct TriggersProjection: Codable, Sendable, Equatable {
        var triggers: [TriggerSummary]
    }

    struct TriggerSummary: Codable, Sendable, Equatable {
        var id: String
        var homeId: String
        var homeName: String
        var name: String
        var isEnabled: Bool
        /// Raw `HMEventTriggerActivationState`; nil for timer triggers.
        var triggerActivationState: Int?
        /// Human-readable form of `triggerActivationState`; nil likewise.
        var activationStateName: String?
        var detail: HomeGraph.Trigger.Detail
    }

    private static func homesView(_ graph: HomeGraph) -> HomesProjection {
        HomesProjection(
            homes: graph.homes.map { home in
                HomeSummary(
                    id: home.id,
                    name: home.name,
                    homeHubState: home.homeHubState,
                    summary: HomeCounts(
                        rooms: home.rooms.count,
                        zones: home.zones.count,
                        accessories: home.rooms.reduce(0) { $0 + $1.accessories.count },
                        scenes: home.scenes.count,
                        serviceGroups: home.serviceGroups.count,
                        triggers: home.triggers.count
                    )
                )
            },
            authorizationStatus: graph.authorizationStatus
        )
    }

    private static func roomsView(
        _ graph: HomeGraph, detail: String, roomId: String?, accessoryId: String?
    ) -> any Codable & Sendable {
        func summary<A: Codable & Sendable & Equatable>(
            _ makeAccessory: (HomeGraph.Accessory) -> A
        ) -> RoomsProjection<A> {
            RoomsProjection(rooms: graph.homes.flatMap { home -> [RoomSummary<A>] in
                let zoneByRoomId = Dictionary(
                    home.zones.flatMap { zone in zone.roomIds.map { ($0, zone) } },
                    uniquingKeysWith: { first, _ in first }
                )
                return home.rooms
                    .filter { roomId == nil || $0.id == roomId }
                    .filter { accessoryId == nil || $0.accessories.contains { $0.id == accessoryId } }
                    .map { room in
                        let zone = zoneByRoomId[room.id]
                        return RoomSummary(
                            id: room.id,
                            homeId: home.id,
                            homeName: home.name,
                            name: room.name,
                            zoneId: zone?.id,
                            zoneName: zone?.name,
                            accessories: room.accessories.map(makeAccessory)
                        )
                    }
            })
        }
        return detail == Self.fullDetail
            ? summary { $0 }
            : summary { AccessoryRef(id: $0.id, name: $0.name) }
    }

    private static let leanDetail = "lean"
    private static let fullDetail = "full"

    private static func zonesView(_ graph: HomeGraph) -> ZonesProjection {
        ZonesProjection(zones: graph.homes.flatMap { home -> [ZoneSummary] in
            home.zones.map { zone in
                let roomIds = Set(zone.roomIds)
                return ZoneSummary(
                    id: zone.id,
                    homeId: home.id,
                    homeName: home.name,
                    name: zone.name,
                    rooms: home.rooms
                        .filter { roomIds.contains($0.id) }
                        .map { RoomRef(id: $0.id, name: $0.name) }
                )
            }
        })
    }

    private static func scenesView(_ graph: HomeGraph) -> ScenesProjection {
        ScenesProjection(scenes: graph.homes.flatMap { home -> [SceneSummary] in
            home.scenes.map { scene in
                SceneSummary(
                    id: scene.id,
                    homeId: home.id,
                    homeName: home.name,
                    name: scene.name,
                    type: scene.type,
                    lastExecutionDate: scene.lastExecutionDate,
                    actions: scene.actions
                )
            }
        })
    }

    private static func serviceGroupsView(_ graph: HomeGraph) -> ServiceGroupsProjection {
        ServiceGroupsProjection(serviceGroups: graph.homes.flatMap { home -> [ServiceGroupSummary] in
            home.serviceGroups.map { group in
                ServiceGroupSummary(
                    id: group.id,
                    homeId: home.id,
                    homeName: home.name,
                    name: group.name,
                    services: group.services
                )
            }
        })
    }

    private static func triggersView(_ graph: HomeGraph) -> TriggersProjection {
        TriggersProjection(triggers: graph.homes.flatMap { home -> [TriggerSummary] in
            home.triggers.map { trigger in
                TriggerSummary(
                    id: trigger.id,
                    homeId: home.id,
                    homeName: home.name,
                    name: trigger.name,
                    isEnabled: trigger.isEnabled,
                    triggerActivationState: trigger.triggerActivationState,
                    activationStateName: trigger.triggerActivationState.map {
                        HomeManagerHomeKitService.activationStateDescription(rawValue: $0)
                    },
                    detail: trigger.detail
                )
            }
        })
    }

    // MARK: - Serialization

    private static func result(_ projection: some Codable & Sendable) throws -> CallTool.Result {
        let data = try encoder.encode(projection)
        return try CallTool.Result(
            content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)],
            structuredContent: try Value(projection),
            isError: false
        )
    }

    private static func errorResult(_ message: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            isError: true
        )
    }

    /// Pretty-printed, key-sorted, ISO-8601 JSON — stable output for agents
    /// and for diffable test assertions.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
