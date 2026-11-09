import Foundation
import MCP

/// The read-only MCP tools over the home graph, and their dispatch.
///
/// Read tools answer in-band (spec): each call takes one consistent
/// `HomeKitService` snapshot and projects a slice of it — no proposal, no
/// staging. All six tools take no arguments and return their slice across
/// every home; filtering arrives with the write tools that need IDs.
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
    public var toolNames: Set<String> { Set(Self.projections.keys) }

    /// Answers one `tools/call` for a read tool. Unknown tool names and graph
    /// read failures return `isError` results rather than throwing, so the
    /// agent sees the failure in-band.
    public func call(name: String, arguments: [String: Value]? = nil) async -> CallTool.Result {
        guard let project = Self.projections[name] else {
            let known = Self.projections.keys.sorted().joined(separator: ", ")
            return Self.errorResult("Unknown tool \(name). Available read tools: \(known)")
        }
        do {
            let graph = try await service.snapshot()
            return try Self.result(project(graph))
        } catch {
            return Self.errorResult("Failed to read the home graph: \(error)")
        }
    }

    // MARK: - Tool definitions

    private static let toolDefinitions: [Tool] = [
        Tool(
            name: "get_homes",
            description: "List every home with counts of its rooms, zones, accessories, scenes, service groups, and triggers, plus each home's home hub state and the app's HomeKit authorization status. Call this first to discover home IDs.",
            inputSchema: emptyObjectSchema,
            annotations: Tool.Annotations(readOnlyHint: true)
        ),
        Tool(
            name: "get_rooms",
            description: "List rooms across all homes with their assigned accessories and zone membership. Each accessory names its services and the characteristics each service supports — each characteristic shows its current value and declared metadata (format, units, min/max/step, validValues), and each accessory shows reachability, bridging, category, and firmware. Check this before staging a characteristic write. Rooms group accessories; zones (see get_zones) group rooms.",
            inputSchema: emptyObjectSchema,
            annotations: Tool.Annotations(readOnlyHint: true)
        ),
        Tool(
            name: "get_zones",
            description: "List zones across all homes with their member rooms. Zones group rooms (e.g. 'Upstairs').",
            inputSchema: emptyObjectSchema,
            annotations: Tool.Annotations(readOnlyHint: true)
        ),
        Tool(
            name: "get_scenes",
            description: "List scenes (HomeKit action sets) with their characteristic-write actions, target values, and when each last ran (lastExecutionDate).",
            inputSchema: emptyObjectSchema,
            annotations: Tool.Annotations(readOnlyHint: true)
        ),
        Tool(
            name: "get_service_groups",
            description: "List service groups with their member services — services, not accessories; each service names the accessory that provides it (e.g. one 'Desk Lamps' group spanning several lamps).",
            inputSchema: emptyObjectSchema,
            annotations: Tool.Annotations(readOnlyHint: true)
        ),
        Tool(
            name: "get_triggers",
            description: "List automations with their enabled state, event-trigger activation state (why an event trigger is or is not active — e.g. no home hub), timer triggers (fire date + recurrence), and event triggers (characteristic events + optional predicate).",
            inputSchema: emptyObjectSchema,
            annotations: Tool.Annotations(readOnlyHint: true)
        ),
    ]

    private static let emptyObjectSchema: Value = .object([
        "type": .string("object"),
        "properties": .object([:]),
    ])

    private static let projections: [String: @Sendable (HomeGraph) throws -> any Codable & Sendable] = [
        "get_homes": homesView,
        "get_rooms": roomsView,
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

    struct RoomsProjection: Codable, Sendable, Equatable {
        var rooms: [RoomSummary]
    }

    struct RoomSummary: Codable, Sendable, Equatable {
        var id: String
        var homeId: String
        var homeName: String
        var name: String
        var zoneId: String?
        var zoneName: String?
        var accessories: [HomeGraph.Accessory]
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

    private static func roomsView(_ graph: HomeGraph) -> RoomsProjection {
        RoomsProjection(rooms: graph.homes.flatMap { home -> [RoomSummary] in
            let zoneByRoomId = Dictionary(
                home.zones.flatMap { zone in zone.roomIds.map { ($0, zone) } },
                uniquingKeysWith: { first, _ in first }
            )
            return home.rooms.map { room in
                let zone = zoneByRoomId[room.id]
                return RoomSummary(
                    id: room.id,
                    homeId: home.id,
                    homeName: home.name,
                    name: room.name,
                    zoneId: zone?.id,
                    zoneName: zone?.name,
                    accessories: room.accessories
                )
            }
        })
    }

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
