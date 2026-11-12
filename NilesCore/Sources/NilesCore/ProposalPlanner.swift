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
        /// No room, zone, scene, service group, trigger, or accessory in the
        /// graph carries this id — the unified verbs' resolution failure.
        case unknownEntity(String)

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
            case .unknownEntity(let id):
                "No room, zone, scene, service group, trigger, or accessory with id “\(id)”. "
                    + "Resolve ids with search or get_details first."
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
        case .createServiceGroup(let homeId, let name, let serviceIds):
            return try createServiceGroup(homeId: homeId, name: name, serviceIds: serviceIds, graph: graph)
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
    /// decoded tool arguments, then plan against the graph. Unified verbs
    /// (Blueprint art_34OYtrUm, write layer) resolve here to their per-type
    /// tool — the exact tool name and arguments `parse` already answers — so
    /// a unified verb shares the per-type code path by construction and
    /// cannot grow a dispatch of its own.
    public static var planFunction: ProposalStore.PlanFunction {
        { tool, arguments, graph in
            if let unified = try resolveUnified(tool: tool, arguments: arguments, graph: graph) {
                return try plan(
                    WriteRequest.parse(tool: unified.tool, arguments: unified.arguments),
                    graph: graph
                )
            }
            return try plan(WriteRequest.parse(tool: tool, arguments: arguments), graph: graph)
        }
    }

}

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
        lifetime: TimeInterval = 24 * 60 * 60,
        persistence: ProposalStoreFile? = nil
    ) {
        self.init(
            homeKit: homeKit, planWith: ProposalPlanner.planFunction,
            now: now, lifetime: lifetime, persistence: persistence
        )
    }
}
