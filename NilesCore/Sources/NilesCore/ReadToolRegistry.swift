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
/// (kind + id). List-bearing reads — search, deep `get_details`,
/// `get_rooms(detail: "full")` — are paginated (Blueprint art_cALBqyxV):
/// every page is a bounded serialization under the response cap, continued
/// with an opaque `nextCursor` until it is absent, so nothing is truncated
/// or refused for scale. The cap remains as a backstop for defects (a
/// single list item too big to return).
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
                guard let limit = Self.pageLimit(arguments) else {
                    return Self.errorResult("Invalid arguments: limit must be a positive integer.")
                }
                return Self.searchResult(graph, query: query, arguments: arguments, limit: limit)
            }
            if name == "get_details" {
                guard let limit = Self.pageLimit(arguments) else {
                    return Self.errorResult("Invalid arguments: limit must be a positive integer.")
                }
                // `detailsView` returns a finished `CallTool.Result` (cap
                // handling can downgrade to an in-band error) — return it
                // directly. Passing it through `result(_:)` would encode the
                // CallTool.Result envelope as the projection, double-wrapping
                // the summary under a "content" key.
                return Self.detailsView(
                    graph,
                    kind: arguments?["kind"]?.stringValue,
                    id: arguments?["id"]?.stringValue,
                    arguments: arguments,
                    limit: limit
                )
            }
            if name == "get_rooms" {
                let detail = arguments?["detail"]?.stringValue ?? Self.leanDetail
                guard detail == Self.leanDetail || detail == Self.fullDetail else {
                    return Self.errorResult("Invalid arguments: detail must be \"\(Self.leanDetail)\" or \"\(Self.fullDetail)\".")
                }
                let roomId = arguments?["roomId"]?.stringValue
                let accessoryId = arguments?["accessoryId"]?.stringValue
                guard detail == Self.fullDetail else {
                    // The lean read fits at real-home scale — no pagination.
                    return try Self.result(Self.roomsView(graph, roomId: roomId, accessoryId: accessoryId))
                }
                guard let limit = Self.pageLimit(arguments) else {
                    return Self.errorResult("Invalid arguments: limit must be a positive integer.")
                }
                return Self.fullRoomsResult(
                    graph, roomId: roomId, accessoryId: accessoryId,
                    arguments: arguments, limit: limit
                )
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
                        "description": .string(NilesAgentSurface.queryDescription),
                    ]),
                    "cursor": .object([
                        "type": .string("string"),
                        "description": .string(Self.cursorArgDescription),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string(Self.limitArgDescription),
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
                    "cursor": .object([
                        "type": .string("string"),
                        "description": .string(Self.cursorArgDescription),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string(Self.limitArgDescription),
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
            description: "DEPRECATED — prefer search and get_details (kind \"room\"), which read one object at a time. List rooms with their accessories. Default output is LEAN — rooms, zones, and accessories as names and ids only (a whole home in full detail exceeds any model's context window at real-home scale). Pass detail \"full\" to include each accessory's services and characteristics (values and metadata) plus reachability state — check that before staging a characteristic write. Full detail paginates: pass cursor from the previous nextCursor until it is absent; limit (default 100 rooms per page) tunes the page size. Rooms group accessories; zones (see get_zones) group rooms.",
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
                    "cursor": .object([
                        "type": .string("string"),
                        "description": .string(Self.cursorArgDescription),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string(Self.limitArgDescription),
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
        "Find objects across the home: rooms, zones, scenes, accessory groups, triggers, and accessories. Queries may be multi-word — every word must match, so prefer simple terms or a room name (e.g. \"office lights\"). Accessories also match their owning room's name and their service type (lights, fans, locks, thermostats, speakers, TVs, cameras, doorbells, garage doors, sensors, switches, outlets). When several match, ask which one they mean. Long result lists paginate: pass cursor from the previous nextCursor until it is absent; limit (default 100) tunes the page size."
    static let getDetailsDescription =
        "Read home state. No arguments: a lean whole-home summary — homes with counts, rooms with accessory names, zones, scenes as action counts, groups, and triggers, without characteristics. With kind and id: one object in full, including its characteristics. Deep list reads paginate: pass cursor from the previous nextCursor until it is absent; limit (default 100) tunes the page size."

    /// Shared pagination-argument descriptions — one text for every
    /// paginated tool's schema (the MCP server lists them verbatim).
    static let cursorArgDescription =
        "Opaque pagination cursor from the previous page's nextCursor. Omit for page one; repeat the same read (same query, or kind + id) until nextCursor is absent."
    static let limitArgDescription =
        "Page size as a hint, default 100: the response cap can return fewer whole items than requested, and the note says so."

    /// Maximum characters a single read response may serialize. The lean
    /// summary for a Syracuse-scale home (71 accessories / 1,179
    /// characteristics) stays well under this. List-bearing reads paginate
    /// under this ceiling (default 100 items per page, fit to the cap), so
    /// it bites only as a backstop: a single list item whose own
    /// serialization exceeds the cap — a defect, not a size.
    static let responseCap = 20_000

    /// The default page size for paginated reads; callers override it with
    /// the `limit` argument.
    static let defaultPageLimit = 100


    /// Kinds `get_details(kind, id)` reads one object of.
    enum DetailKind: String, Sendable, CaseIterable {
        case home, room, zone, scene, group, trigger, accessory
    }

    // MARK: - Consolidated read surface (search / get_details)

    /// One page of search hits. `nextCursor` continues the match list
    /// (absent on the last page); `note` reports a cursor advance or a
    /// cap-bound clamp.
    struct SearchProjection: Codable, Sendable, Equatable {
        var query: String
        var results: [SearchHit]
        var nextCursor: String?
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

    /// All search hits for `query`, in stable graph order — the list
    /// `search` pages over.
    private static func searchHits(_ graph: HomeGraph, query: String) -> [SearchHit] {
        let terms = NilesAgentSurface.searchTerms(query)
        var hits: [SearchHit] = []
        func add(_ hit: SearchHit) { hits.append(hit) }
        for home in graph.homes {
            for room in home.rooms where NilesAgentSurface.nameMatches(terms, name: room.name) {
                add(SearchHit(
                    kind: "room", id: room.id, name: room.name, homeId: home.id, homeName: home.name,
                    context: "\(room.accessories.count) accessories"
                ))
            }
            for zone in home.zones where NilesAgentSurface.nameMatches(terms, name: zone.name) {
                add(SearchHit(
                    kind: "zone", id: zone.id, name: zone.name, homeId: home.id, homeName: home.name,
                    context: "zone of \(zone.roomIds.count) rooms"
                ))
            }
            for scene in home.scenes where NilesAgentSurface.nameMatches(terms, name: scene.name) {
                add(SearchHit(
                    kind: "scene", id: scene.id, name: scene.name, homeId: home.id, homeName: home.name,
                    context: "scene with \(scene.actions.count) actions"
                ))
            }
            for group in home.serviceGroups where NilesAgentSurface.nameMatches(terms, name: group.name) {
                add(SearchHit(
                    kind: "group", id: group.id, name: group.name, homeId: home.id, homeName: home.name,
                    context: "group of \(group.services.count) services"
                ))
            }
            for trigger in home.triggers where NilesAgentSurface.nameMatches(terms, name: trigger.name) {
                add(SearchHit(
                    kind: "trigger", id: trigger.id, name: trigger.name, homeId: home.id, homeName: home.name,
                    context: trigger.isEnabled ? "enabled automation" : "disabled automation"
                ))
            }
            for room in home.rooms {
                for accessory in room.accessories
                where NilesAgentSurface.accessoryMatches(
                    terms,
                    name: accessory.name,
                    roomName: room.name,
                    serviceTypes: accessory.services.compactMap(\.serviceType)
                ) {
                    add(SearchHit(
                        kind: "accessory", id: accessory.id, name: accessory.name,
                        homeId: home.id, homeName: home.name,
                        context: "in room \(room.name)"
                    ))
                }
            }
        }
        return hits
    }

    /// Serves one page of search hits; the cursor anchors on the query.
    private static func searchResult(
        _ graph: HomeGraph, query: String, arguments: [String: Value]?, limit: Int
    ) -> CallTool.Result {
        Self.pagedResult(
            plainUnits(searchHits(graph, query: query)),
            arguments: arguments,
            tool: "search",
            anchorId: query,
            listPath: "results",
            limit: limit
        ) { slice, nextCursor, note in
            SearchProjection(query: query, results: slice, nextCursor: nextCursor, note: note)
        }
    }

    /// The no-argument `get_details` shape: the lean whole-home summary. No
    /// characteristic payloads anywhere — rooms list accessories as names
    /// and ids, scenes as action counts — so a Syracuse-scale home fits any
    /// model's context window.
    struct SummaryProjection: Codable, Sendable, Equatable {
        var homes: [HomeOverview]
        var authorizationStatus: String?
        /// Present only when the summary is paginated over its rooms list.
        var nextCursor: String?
        var note: String?
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
            /// Set when HomeKit reports the group holds no member services —
            /// see `membershipNote(for:)`.
            var membershipNote: String?
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
                    services: $0.services.map { NameRef(id: $0.id, name: $0.name) },
                    membershipNote: ReadToolRegistry.membershipNote(for: $0.services)
                )
            }
            self.triggers = home.triggers.map {
                TriggerLine(id: $0.id, name: $0.name, enabled: $0.isEnabled, detail: $0.detail)
            }
        }
    }

    /// One object read — the `get_details(kind, id)` shape. List-bearing
    /// reads are paginated: `nextCursor` continues the object's list
    /// (absent on the last page) and `note` reports a cursor advance or a
    /// cap-bound clamp.
    struct FullObject<T: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
        var kind: String
        var id: String
        var nextCursor: String?
        var note: String?
        var object: T
    }

    /// The accessory body of a paginated deep read — identity and state,
    /// the total service count, and one page of the service list (each
    /// service carrying its characteristics).
    struct AccessoryPage: Codable, Sendable, Equatable {
        var id: String
        var name: String
        var reachable: Bool?
        var bridged: Bool?
        var category: String?
        var firmwareVersion: String?
        /// Total services on the accessory, across all pages.
        var serviceCount: Int
        var services: [HomeGraph.AccessoryService]
    }

    /// An accessory read page with its place in the home.
    struct AccessoryDetail: Codable, Sendable, Equatable {
        var id: String
        var homeId: String
        var homeName: String
        var roomId: String
        var roomName: String
        var accessory: AccessoryPage
    }

    /// `get_details` dispatch: no arguments → the lean summary; kind + id →
    /// one object in full, its list paginated. Returns a `CallTool.Result`
    /// because backstop handling can downgrade to an in-band error (never a
    /// silent shortening).
    private static func detailsView(
        _ graph: HomeGraph, kind: String?, id: String?,
        arguments: [String: Value]?, limit: Int
    ) -> CallTool.Result {
        switch (kind?.lowercased(), id) {
        case (nil, nil):
            // The lean summary is list-bearing (each home's rooms), so at
            // real-home scale it pages its rooms list instead of refusing —
            // every room stays reachable one page at a time. A summary that
            // fits the cap comes back as a single page with no cursor,
            // identical to an unpaginated one.
            return Self.pagedSummary(graph, arguments: arguments, limit: limit)
        case (nil, _), (_, nil):
            return Self.errorResult("Invalid arguments: provide kind and id together, or neither.")
        case (let kindRaw?, let id?):
            guard let kind = DetailKind(rawValue: kindRaw) else {
                let known = DetailKind.allCases.map(\.rawValue).joined(separator: ", ")
                return Self.errorResult("Unknown kind \(kindRaw) — use \(known).")
            }
            return Self.objectDetails(graph, kind: kind, id: id, arguments: arguments, limit: limit)
        }
    }

    /// The lean no-argument summary. Only the first home's rooms list
    /// pages today — it dominates the summary's size at evidenced scale;
    /// the remaining homes' overviews stay whole.
    private static func pagedSummary(
        _ graph: HomeGraph, arguments: [String: Value]?, limit: Int
    ) -> CallTool.Result {
        let summaries = graph.homes.map(HomeOverview.init)
        guard let primary = summaries.first else {
            return Self.cappedResult(
                SummaryProjection(
                    homes: summaries, authorizationStatus: graph.authorizationStatus
                ),
                hint: "Use search and get_details with kind and id to read one object at a time."
            )
        }
        return Self.pagedResult(
            plainUnits(primary.rooms), arguments: arguments,
            tool: "get_details", anchorId: "summary", listPath: "rooms", limit: limit
        ) { slice, nextCursor, note in
            var paged = summaries
            paged[0].rooms = slice
            return SummaryProjection(
                homes: paged, authorizationStatus: graph.authorizationStatus,
                nextCursor: nextCursor, note: note
            )
        }
    }

    /// Deep-read dispatch per kind. Every list-bearing kind pages its list
    /// (accessories, services, rooms, actions); the page envelope keeps the
    /// object's identity, so a continued page reads like the same read,
    /// continued. Trigger reads have no list and answer whole.
    private static func objectDetails(
        _ graph: HomeGraph, kind: DetailKind, id: String,
        arguments: [String: Value]?, limit: Int
    ) -> CallTool.Result {
        // The cursor's anchor names kind and id — a page from one read
        // cannot be passed to another.
        let anchorId = "\(kind.rawValue):\(id)"
        for home in graph.homes {
            if kind == .home, home.id == id {
                let overview = HomeOverview(home)
                return Self.pagedResult(
                    plainUnits(overview.rooms), arguments: arguments,
                    tool: "get_details", anchorId: anchorId, listPath: "rooms", limit: limit
                ) { slice, nextCursor, note in
                    var paged = overview
                    paged.rooms = slice
                    return Self.FullObject(
                        kind: kind.rawValue, id: id, nextCursor: nextCursor, note: note,
                        object: paged
                    )
                }
            }
            if let room = home.rooms.first(where: { $0.id == id }), kind == .room {
                let zone = home.zones.first { $0.roomIds.contains(room.id) }
                return Self.pagedResult(
                    room.accessories.flatMap { accessoryUnits($0) }, arguments: arguments,
                    tool: "get_details", anchorId: anchorId, listPath: "accessories", limit: limit
                ) { slice, nextCursor, note in
                    Self.FullObject(
                        kind: kind.rawValue, id: id, nextCursor: nextCursor, note: note,
                        object: RoomSummary(
                            id: room.id, homeId: home.id, homeName: home.name, name: room.name,
                            zoneId: zone?.id, zoneName: zone?.name,
                            accessories: slice
                        )
                    )
                }
            }
            if kind == .accessory,
                let room = home.rooms.first(where: { $0.accessories.contains { $0.id == id } }),
                let accessory = room.accessories.first(where: { $0.id == id })
            {
                return Self.pagedResult(
                    accessory.services.flatMap { serviceUnits($0) }, arguments: arguments,
                    tool: "get_details", anchorId: anchorId, listPath: "services", limit: limit
                ) { slice, nextCursor, note in
                    Self.FullObject(
                        kind: kind.rawValue, id: id, nextCursor: nextCursor, note: note,
                        object: AccessoryDetail(
                            id: accessory.id, homeId: home.id, homeName: home.name,
                            roomId: room.id, roomName: room.name,
                            accessory: AccessoryPage(
                                id: accessory.id, name: accessory.name,
                                reachable: accessory.reachable, bridged: accessory.bridged,
                                category: accessory.category,
                                firmwareVersion: accessory.firmwareVersion,
                                serviceCount: accessory.services.count,
                                services: slice
                            )
                        )
                    )
                }
            }
            if let zone = home.zones.first(where: { $0.id == id }), kind == .zone {
                let roomIds = Set(zone.roomIds)
                return Self.pagedResult(
                    plainUnits(home.rooms.filter { roomIds.contains($0.id) }
                        .map { RoomRef(id: $0.id, name: $0.name) }),
                    arguments: arguments,
                    tool: "get_details", anchorId: anchorId, listPath: "rooms", limit: limit
                ) { slice, nextCursor, note in
                    Self.FullObject(
                        kind: kind.rawValue, id: id, nextCursor: nextCursor, note: note,
                        object: ZoneSummary(
                            id: zone.id, homeId: home.id, homeName: home.name, name: zone.name,
                            rooms: slice
                        )
                    )
                }
            }
            if let scene = home.scenes.first(where: { $0.id == id }), kind == .scene {
                return Self.pagedResult(
                    plainUnits(scene.actions), arguments: arguments,
                    tool: "get_details", anchorId: anchorId, listPath: "actions", limit: limit
                ) { slice, nextCursor, note in
                    Self.FullObject(
                        kind: kind.rawValue, id: id, nextCursor: nextCursor, note: note,
                        object: SceneSummary(
                            id: scene.id, homeId: home.id, homeName: home.name, name: scene.name,
                            type: scene.type, lastExecutionDate: scene.lastExecutionDate,
                            actions: slice
                        )
                    )
                }
            }
            if let group = home.serviceGroups.first(where: { $0.id == id }), kind == .group {
                return Self.pagedResult(
                    plainUnits(group.services), arguments: arguments,
                    tool: "get_details", anchorId: anchorId, listPath: "services", limit: limit
                ) { slice, nextCursor, note in
                    Self.FullObject(
                        kind: kind.rawValue, id: id, nextCursor: nextCursor, note: note,
                        object: ServiceGroupSummary(
                            id: group.id, homeId: home.id, homeName: home.name, name: group.name,
                            services: slice
                        )
                    )
                }
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
                    hint: "A trigger read has no list to paginate."
                )
            }
        }
        // The anchor of a cursor page that no longer exists gets the
        // restart error, with the object named — never a partial page.
        if arguments?["cursor"] != nil {
            return Self.errorResult(
                "No \(kind.rawValue) \(id) — the object this cursor anchors no longer exists. Restart the read from page one (get_details without a cursor)."
            )
        }
        return Self.errorResult("No \(kind.rawValue) \(id).")
    }

    /// Encodes `projection` and enforces the response cap as a backstop for
    /// the reads with no list to paginate (the lean summary, the deprecated
    /// whole-graph tools, trigger details): an oversized one is a defect
    /// report naming the cap — never silently shortened.
    private static func cappedResult(_ projection: some Codable & Sendable, hint: String) -> CallTool.Result {
        do {
            let data = try encoder.encode(projection)
            guard data.count <= responseCap else {
                return Self.errorResult(
                    "Backstop: this read has no list to paginate and its \(data.count) characters exceed the \(responseCap)-character response cap, so it was not returned. \(hint)"
                )
            }
            return try Self.textResult(data)
        } catch {
            return Self.errorResult("Failed to encode the read result: \(error)")
        }
    }

    // MARK: - Pagination

    /// The stateless, opaque read cursor: enough to re-derive one list
    /// slice from a fresh snapshot. `limit` travels per request, never
    /// inside the cursor, so a caller can change page size mid-read.
    struct ReadCursor: Codable, Sendable, Equatable {
        var tool: String
        var anchorId: String
        var listPath: String
        var offset: Int
    }

    static func encodeCursor(_ cursor: ReadCursor) -> String {
        // A cursor is three strings and an integer; encoding cannot fail,
        // so the degenerate empty string is unreachable by construction.
        (try? JSONEncoder().encode(cursor))?.base64EncodedString() ?? ""
    }

    static func decodeCursor(_ string: String) -> ReadCursor? {
        guard let data = Data(base64Encoded: string) else { return nil }
        return try? JSONDecoder().decode(ReadCursor.self, from: data)
    }

    /// The caller-settable page size: `limit` when given (a positive
    /// integer), otherwise `defaultPageLimit`. nil = invalid argument.
    static func pageLimit(_ arguments: [String: Value]?) -> Int? {
        guard let value = arguments?["limit"] else { return Self.defaultPageLimit }
        guard let parsed = value.intValue, parsed >= 1 else { return nil }
        return parsed
    }

    /// Validates a caller cursor against the read being served. A cursor
    /// is only meaningful for the same tool, anchor, and list it was
    /// issued from; anything else — including a malformed one — sends the
    /// caller back to page one rather than re-deriving a stale slice.
    enum CursorCheck: Sendable, Equatable {
        case start
        case resume(offset: Int)
        case invalid(String)
    }

    static func cursorCheck(
        _ arguments: [String: Value]?, tool: String, anchorId: String, listPath: String
    ) -> CursorCheck {
        guard let raw = arguments?["cursor"]?.stringValue, !raw.isEmpty else { return .start }
        guard let cursor = Self.decodeCursor(raw) else {
            return .invalid(
                "Invalid cursor — it is not a cursor this server issued. Restart the read from page one (omit `cursor`)."
            )
        }
        guard cursor.tool == tool, cursor.anchorId == anchorId, cursor.listPath == listPath else {
            return .invalid(
                "Cursor does not match this read (tool \(cursor.tool), anchor \(cursor.anchorId), list \(cursor.listPath)) — restart the read from page one (omit `cursor`)."
            )
        }
        return .resume(offset: max(0, cursor.offset))
    }

    /// One paginated entry: the rendered item as it appears in the page
    /// (whole, or one page of an item too large to serve whole) plus the
    /// note that explains a split, when present.
    private struct PageUnit<Item: Codable & Sendable & Equatable> {
        var item: Item
        /// Present only when this unit is one page of an item whose payload
        /// spreads across consecutive units.
        var note: String?
    }

    /// Serialized size budget for one page unit, measured through the
    /// nesting probe: under the cap by enough margin for the page
    /// envelope's identity, note, and cursor, so a slice unit built to
    /// this budget can never trip the backstop on its own page.
    private static let unitBudget = responseCap - 1_024

    /// Fitting probe: a candidate's rendered size depends on its JSON
    /// nesting depth — pretty-printed indentation scales with depth — so a
    /// unit is fitted wrapped at the deepest page envelope's depth
    /// (object → rooms → room → accessories, as get_rooms renders a room
    /// slice), never serialized flat. Shallower envelopes render smaller
    /// than the probe, so fitting against it is safe for every paginated
    /// read.
    private struct UnitProbe<Item: Codable & Sendable>: Codable {
        var object: ObjectEnvelope
        struct ObjectEnvelope: Codable {
            var rooms: [RoomEnvelope]
        }
        struct RoomEnvelope: Codable {
            var accessories: [Item]
        }
    }

    private static func unitFits<Item: Codable & Sendable>(_ item: Item) -> Bool {
        guard let data = try? encoder.encode(UnitProbe(object: .init(rooms: [.init(accessories: [item])]))) else { return false }
        return data.count <= unitBudget
    }

    /// The largest count ≤ `maxCount` whose rendered candidate fits the
    /// unit budget — monotonic in the count, so binary search applies.
    private static func largestFittingPrefix<Item: Codable & Sendable>(
        in maxCount: Int, of candidate: (Int) -> Item
    ) -> Int {
        guard maxCount >= 1, unitFits(candidate(1)) else { return 0 }
        var lo = 1
        var hi = maxCount
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if unitFits(candidate(mid)) { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// One accessory as page units: whole when it fits, otherwise
    /// consecutive units slicing its service list — and a service whose own
    /// payload cannot fit descends to characteristic slices.
    /// Characteristics are leaves and are never split: a single one over
    /// the unit budget reaches the page fitter's backstop as a true defect,
    /// which is the only way scale can reach the backstop.
    private static func accessoryUnits(_ accessory: HomeGraph.Accessory) -> [PageUnit<HomeGraph.Accessory>] {
        guard !unitFits(accessory) else { return [PageUnit(item: accessory, note: nil)] }
        let splitNote = "Accessory \"\(accessory.name)\" is large: its \(accessory.services.count) services are spread across consecutive pages."
        var units: [PageUnit<HomeGraph.Accessory>] = []
        var remaining = accessory.services
        while !remaining.isEmpty {
            let head = remaining[0]
            if unitFits(head) {
                let taken = max(largestFittingPrefix(in: remaining.count) { count in
                    accessory.withServices(Array(remaining.prefix(count)))
                }, 1)
                let isLast = taken == remaining.count
                units.append(PageUnit(
                    item: accessory.withServices(Array(remaining.prefix(taken))),
                    note: isLast ? nil : splitNote
                ))
                remaining = Array(remaining.dropFirst(taken))
            } else {
                // The head service's own payload cannot fit — split its
                // characteristics across units before moving on.
                for unit in serviceUnits(head) {
                    units.append(PageUnit(item: accessory.withServices([unit.item]), note: splitNote))
                }
                remaining = Array(remaining.dropFirst())
            }
        }
        return units
    }

    /// One service as page units: whole when it fits, otherwise
    /// consecutive units slicing its characteristics — never a
    /// characteristic split.
    private static func serviceUnits(_ service: HomeGraph.AccessoryService) -> [PageUnit<HomeGraph.AccessoryService>] {
        guard !unitFits(service) else { return [PageUnit(item: service, note: nil)] }
        let splitNote = "Service \"\(service.name)\" is large: its \(service.characteristics.count) characteristics are spread across consecutive pages."
        var units: [PageUnit<HomeGraph.AccessoryService>] = []
        var remaining = service.characteristics
        while !remaining.isEmpty {
            let taken = largestFittingPrefix(in: remaining.count) { count in
                service.withCharacteristics(Array(remaining.prefix(count)))
            }
            if taken == 0 {
                // A single characteristic over budget is a leaf-sized
                // defect; emit it whole so the page fitter's backstop
                // reports it, and let the read stop there.
                units.append(PageUnit(item: service.withCharacteristics([remaining[0]]), note: nil))
                return units
            }
            let isLast = taken == remaining.count
            units.append(PageUnit(
                item: service.withCharacteristics(Array(remaining.prefix(taken))),
                note: isLast ? nil : splitNote
            ))
            remaining = Array(remaining.dropFirst(taken))
        }
        return units
    }

    /// One full-detail room as page units: whole when it fits, otherwise
    /// consecutive units slicing its accessory list — and an accessory
    /// whose own payload cannot fit descends to service slices.
    private static func roomUnits(_ room: RoomSummary<HomeGraph.Accessory>) -> [PageUnit<RoomSummary<HomeGraph.Accessory>>] {
        func withAccessories(_ accessories: [HomeGraph.Accessory]) -> RoomSummary<HomeGraph.Accessory> {
            RoomSummary(
                id: room.id, homeId: room.homeId, homeName: room.homeName, name: room.name,
                zoneId: room.zoneId, zoneName: room.zoneName, accessories: accessories
            )
        }
        guard !unitFits(room) else { return [PageUnit(item: room, note: nil)] }
        let splitNote = "Room \"\(room.name)\" is large: its \(room.accessories.count) accessories are spread across consecutive pages."
        var units: [PageUnit<RoomSummary<HomeGraph.Accessory>>] = []
        var remaining = room.accessories
        while !remaining.isEmpty {
            let head = remaining[0]
            if unitFits(head) {
                let taken = max(largestFittingPrefix(in: remaining.count) { count in
                    withAccessories(Array(remaining.prefix(count)))
                }, 1)
                let isLast = taken == remaining.count
                units.append(PageUnit(
                    item: withAccessories(Array(remaining.prefix(taken))),
                    note: isLast ? nil : splitNote
                ))
                remaining = Array(remaining.dropFirst(taken))
            } else {
                // The head accessory's own payload cannot fit — flatten it
                // into service-slice units before moving on.
                for unit in accessoryUnits(head) {
                    units.append(PageUnit(item: withAccessories([unit.item]), note: splitNote))
                }
                remaining = Array(remaining.dropFirst())
            }
        }
        return units
    }

    /// Whole-item units for reads whose items are never split — the
    /// expansion helpers above apply only to the deep accessory-bearing
    /// lists whose items can exceed the cap at real-home scale.
    private static func plainUnits<Item: Codable & Sendable & Equatable>(
        _ items: [Item]
    ) -> [PageUnit<Item>] {
        items.map { PageUnit(item: $0, note: nil) }
    }

    /// Serves one page of `units` for a paginated read: validates the
    /// caller's cursor, then returns whole page units from the cursor's
    /// offset until `limit` is reached or serializing one more unit would
    /// exceed the response cap — whichever comes first. A page is never
    /// truncated; a cap-bound clamp is named in the note.
    ///
    /// The `envelope` closure receives the page's items, the `nextCursor`
    /// (nil on the last page), and the note (nil on a quiet first page),
    /// so the fitter measures exactly what will ship.
    private static func pagedResult<Item: Codable & Sendable & Equatable>(
        _ units: [PageUnit<Item>],
        arguments: [String: Value]?,
        tool: String,
        anchorId: String,
        listPath: String,
        limit: Int,
        envelope: ([Item], String?, String?) -> any Codable & Sendable
    ) -> CallTool.Result {
        let offset: Int
        switch Self.cursorCheck(arguments, tool: tool, anchorId: anchorId, listPath: listPath) {
        case .invalid(let message):
            return Self.errorResult(message)
        case .resume(let resumed):
            offset = resumed
        case .start:
            offset = 0
        }
        let total = units.count
        if offset >= total {
            guard offset > 0 else {
                // An empty list at page one is a valid empty page.
                return Self.encodedPage(envelope([], nil, nil))
            }
            // A cursor whose list shrank past its offset between pages.
            return Self.errorResult(
                "Cursor offset \(offset) is past the end of the \(listPath) list (\(total) items now) — the home changed between pages. Restart the read from page one."
            )
        }

        // The page body: the slice, its nextCursor, and its note — so the
        // fitter measures exactly what will ship.
        func page(_ count: Int) -> any Codable & Sendable {
            let end = offset + count
            let slice = Array(units[offset..<end])
            var notes: [String] = []
            for unit in slice {
                if let note = unit.note, !notes.contains(note) {
                    notes.append(note)
                }
            }
            if offset > 0 {
                notes.append("Continuing \(listPath) from offset \(offset) of \(total).")
            }
            if count < limit, end < total {
                notes.append("\(limit) requested, \(count) returned — response-cap bound.")
            }
            let nextCursor = end < total
                ? Self.encodeCursor(ReadCursor(
                    tool: tool, anchorId: anchorId, listPath: listPath, offset: end
                ))
                : nil
            return envelope(slice.map(\.item), nextCursor, notes.isEmpty ? nil : notes.joined(separator: " "))
        }

        // Binary search the largest page that serializes under the cap —
        // page size is monotonic in the item count.
        func fits(_ count: Int) -> Bool {
            guard let data = try? encoder.encode(page(count)) else { return false }
            return data.count <= responseCap
        }
        let maxCount = min(limit, total - offset)
        guard fits(1) else {
            // Backstop: one item alone exceeds the cap — a defect, not a
            // size, so the page is refused loudly with the item named.
            return Self.errorResult(
                "Response defect: a single \(listPath) item in this \(tool) read for \"\(anchorId)\" (offset \(offset)) exceeds the \(responseCap)-character response cap and cannot be returned. Pagination cannot split an item — this is a bug worth reporting."
            )
        }
        var lo = 1
        var hi = maxCount
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if fits(mid) { lo = mid } else { hi = mid - 1 }
        }
        return Self.encodedPage(page(lo))
    }

    private static func encodedPage(_ projection: some Codable & Sendable) -> CallTool.Result {
        do {
            let data = try encoder.encode(projection)
            return try Self.textResult(data)
        } catch {
            return Self.errorResult("Failed to encode the read result: \(error)")
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
        /// Continues the room list of a full-detail read — absent on the
        /// last page. The lean read always answers whole.
        var nextCursor: String?
        var note: String?
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

    /// The note a group read carries when HomeKit reports no member
    /// services. `HMServiceGroup.services` is a plain synchronous property
    /// over the HomeKit daemon's state, and the framework's public surface
    /// offers no refresh or reload on `HMServiceGroup` or `HMHome` — there
    /// is no call that would force unhydrated membership to populate, so
    /// `snapshot()` (which already walks the live manager) is all the read
    /// path can do. An empty list is therefore ambiguous — genuinely empty,
    /// or unhydrated in this process — and every group projection says so
    /// instead of presenting bare emptiness as fact. Device evidence (all
    /// 20 Syracuse groups reading `servicesPopulated: false`, 2026-11-10)
    /// is what made this note necessary; the diagnostic proposal
    /// (`prop_7fd0487e6054`) decides which of the two it is.
    static func membershipNote(for services: [HomeGraph.ServiceRef]) -> String? {
        guard services.isEmpty else { return nil }
        return "membership unavailable — HomeKit reported no members"
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

    /// The lean get_rooms read: rooms with names and ids only — it fits at
    /// real-home scale, so it never paginates.
    private static func roomsView(
        _ graph: HomeGraph, roomId: String?, accessoryId: String?
    ) -> RoomsProjection<AccessoryRef> {
        RoomsProjection(
            rooms: Self.filteredRooms(graph, roomId: roomId, accessoryId: accessoryId).map { entry in
                RoomSummary(
                    id: entry.room.id, homeId: entry.homeId, homeName: entry.homeName,
                    name: entry.room.name, zoneId: entry.zone?.id, zoneName: entry.zone?.name,
                    accessories: entry.room.accessories.map { AccessoryRef(id: $0.id, name: $0.name) }
                )
            },
            nextCursor: nil, note: nil
        )
    }

    /// One matching room with its home identity and zone — the item source
    /// for both `get_rooms` depths.
    struct RoomEntry: Sendable {
        var room: HomeGraph.Room
        var zone: HomeGraph.Zone?
        var homeId: String
        var homeName: String
    }

    /// The graph's rooms matching the optional filters, with each room's
    /// zone, in stable graph order.
    private static func filteredRooms(
        _ graph: HomeGraph, roomId: String?, accessoryId: String?
    ) -> [RoomEntry] {
        graph.homes.flatMap { home in
            let zoneByRoomId = Dictionary(
                home.zones.flatMap { zone in zone.roomIds.map { ($0, zone) } },
                uniquingKeysWith: { first, _ in first }
            )
            return home.rooms
                .filter { roomId == nil || $0.id == roomId }
                .filter { accessoryId == nil || $0.accessories.contains { $0.id == accessoryId } }
                .map { room in
                    RoomEntry(
                        room: room, zone: zoneByRoomId[room.id],
                        homeId: home.id, homeName: home.name
                    )
                }
        }
    }

    /// Serves one page of `get_rooms(detail: "full")`: the matching rooms,
    /// each with full accessory payloads, paged at room granularity — the
    /// list-bearing part of the projection.
    private static func fullRoomsResult(
        _ graph: HomeGraph, roomId: String?, accessoryId: String?,
        arguments: [String: Value]?, limit: Int
    ) -> CallTool.Result {
        // The filters are part of the cursor's anchor — a page composed
        // with different filters re-derives a different list.
        let anchorId = "rooms filter room=\(roomId ?? "*") accessory=\(accessoryId ?? "*")"
        let rooms = Self.filteredRooms(graph, roomId: roomId, accessoryId: accessoryId).map { entry in
            RoomSummary(
                id: entry.room.id, homeId: entry.homeId, homeName: entry.homeName,
                name: entry.room.name, zoneId: entry.zone?.id, zoneName: entry.zone?.name,
                accessories: entry.room.accessories
            )
        }
        return Self.pagedResult(
            rooms.flatMap { roomUnits($0) }, arguments: arguments,
            tool: "get_rooms", anchorId: anchorId, listPath: "rooms", limit: limit
        ) { slice, nextCursor, note in
            RoomsProjection(rooms: slice, nextCursor: nextCursor, note: note)
        }
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
                    services: group.services,
                    membershipNote: Self.membershipNote(for: group.services)
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

// MARK: - Unit-copy conveniences for the pagination expansion helpers

private extension HomeGraph.Accessory {
    func withServices(_ services: [HomeGraph.AccessoryService]) -> HomeGraph.Accessory {
        HomeGraph.Accessory(
            id: id, name: name, supportsIdentify: supportsIdentify,
            reachable: reachable, bridged: bridged, category: category,
            firmwareVersion: firmwareVersion, services: services
        )
    }
}

private extension HomeGraph.AccessoryService {
    func withCharacteristics(_ characteristics: [HomeGraph.CharacteristicRef]) -> HomeGraph.AccessoryService {
        HomeGraph.AccessoryService(
            id: id, name: name, serviceType: serviceType, characteristics: characteristics
        )
    }
}
