import Foundation

/// A characteristic target value, as an agent supplies it in a scene action.
///
/// HomeKit characteristic values are untyped `Any` (NSNumber, NSString, ...).
/// This enum is the typed, Codable surface agents write through; `rendered`
/// matches the read side's `String(describing:)` convention for NSNumber and
/// NSString so a proposed action's key compares equal to the same action read
/// back from the graph (e.g. when `set_scene_actions` computes its diff).
public enum HomeKitValue: Codable, Sendable, Equatable, Hashable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    /// The value the way the read side renders HomeKit values. NSNumber
    /// collapses integral doubles ("30.0" -> "30"), so `.double(30)` and
    /// `.int(30)` render identically and diff keys match.
    public var rendered: String {
        switch self {
        case .bool(let value): value ? "1" : "0"
        case .int(let value): String(describing: value)
        case .double(let value): String(describing: NSNumber(value: value))
        case .string(let value): value
        }
    }
}

/// One characteristic-write action an agent proposes for a scene.
///
/// `service` matches the read side's `HomeGraph.SceneAction.service`: a
/// service name or service type, whichever the agent saw in `get_scenes` or
/// `get_service_groups`. The executor resolves it to an `HMService`.
public struct SceneActionSpec: Codable, Sendable, Equatable, Hashable {
    public let accessoryId: String
    public let service: String?
    public let characteristic: String
    public let value: HomeKitValue

    public init(accessoryId: String, service: String?, characteristic: String, value: HomeKitValue) {
        self.accessoryId = accessoryId
        self.service = service
        self.characteristic = characteristic
        self.value = value
    }
}

/// The identity of a scene action for diffing: same accessory, service,
/// characteristic, and target value is the same action, whatever name the
/// read side rendered for it.
public struct SceneActionKey: Hashable, Sendable {
    public let accessoryId: String?
    public let service: String?
    public let characteristic: String
    public let valueDescription: String

    public init(spec: SceneActionSpec) {
        self.init(
            accessoryId: spec.accessoryId,
            service: spec.service,
            characteristic: spec.characteristic,
            valueDescription: spec.value.rendered
        )
    }

    public init(action: HomeGraph.SceneAction) {
        self.init(
            accessoryId: action.accessoryId,
            service: action.service,
            characteristic: action.characteristic,
            valueDescription: action.valueDescription
        )
    }

    public init(accessoryId: String?, service: String?, characteristic: String, valueDescription: String) {
        self.accessoryId = accessoryId
        self.service = service
        self.characteristic = characteristic
        self.valueDescription = valueDescription
    }
}

/// One event an agent proposes for an event trigger (the spec's `HMEvent`
/// model). A trigger is one kind of event per member, never both.
public enum TriggerEventSpec: Codable, Sendable, Equatable, Hashable {
    /// A characteristic reaching a target value. `value` nil means the event
    /// fires on any change of the characteristic.
    case characteristic(accessoryId: String, characteristic: String, value: HomeKitValue?)
    /// Presence evaluated by HomeKit itself (`HMPresenceEvent`): someone is
    /// at home, or everyone is away. Never asks the app for location access.
    case presence(atHome: Bool)

    /// Whether this event fires when users arrive (vs. leave).
    public var presenceAtHome: Bool? {
        switch self {
        case .characteristic: nil
        case .presence(let atHome): atHome
        }
    }
}

/// One executable HomeKit mutation — the whole vocabulary an approval can
/// run. Declarative tools stage minimal operations; the executor (the fake in
/// tests, `HomeManagerHomeKitService` on device) applies them. Membership
/// operations carry the already-diffed add/remove lists so approval never
/// re-derives intent from a stale graph.
///
/// Trigger operations enforce the spec's locked rule: creation always adds a
/// DISABLED trigger, and arming one is its own `setTriggerEnabled` operation
/// — a separate proposal the human approves separately.
public enum HomeKitOperation: Sendable, Equatable, Hashable {
    case addRoom(homeId: String, name: String)
    case renameRoom(homeId: String, roomId: String, to: String)
    case removeRoom(homeId: String, roomId: String)
    case setZoneRooms(homeId: String, zoneId: String, addRoomIds: [String], removeRoomIds: [String])
    case createZone(homeId: String, name: String)
    case renameZone(homeId: String, zoneId: String, to: String)
    case removeZone(homeId: String, zoneId: String)
    case addActionSet(homeId: String, name: String, actions: [SceneActionSpec])
    case setSceneActions(homeId: String, sceneId: String, add: [SceneActionSpec], remove: [SceneActionKey])
    case renameActionSet(homeId: String, sceneId: String, to: String)
    case removeActionSet(homeId: String, sceneId: String)
    case executeActionSet(homeId: String, sceneId: String)
    case addServiceGroup(homeId: String, name: String)
    case renameServiceGroup(homeId: String, groupId: String, to: String)
    case setServiceGroupMembers(
        homeId: String, groupId: String, addServiceIds: [String], removeServiceIds: [String]
    )
    case removeServiceGroup(homeId: String, groupId: String)
    case addTimerTrigger(
        homeId: String, name: String, fireDate: Date, recurrence: [String: Int], sceneId: String?
    )
    case addEventTrigger(homeId: String, name: String, events: [TriggerEventSpec], sceneId: String?)
    case setTriggerEnabled(homeId: String, triggerId: String, enabled: Bool)
    case updateTimerTrigger(homeId: String, triggerId: String, fireDate: Date, recurrence: [String: Int])
    case removeTrigger(homeId: String, triggerId: String)
    case renameAccessory(homeId: String, accessoryId: String, to: String)
    case identifyAccessory(homeId: String, accessoryId: String)
    case assignAccessoryToRoom(homeId: String, accessoryId: String, roomId: String)
    case unblockAccessory(homeId: String, accessoryId: String)
    case removeAccessory(homeId: String, accessoryId: String)
}

/// Read access plus the mutation vocabulary proposals execute.
///
/// Conformed by `FakeHomeKitService` (unit tests and previews) and
/// `HomeManagerHomeKitService` (the real shared home database). Operations
/// are not transactional — HomeKit has no rollback — so an executor applies
/// them in order and the caller records what actually applied.
public protocol HomeKitWriting: HomeKitService {
    /// Applies one operation, returning the created object's id when the
    /// operation creates one (a new room, scene, or service group).
    ///
    /// Throws when HomeKit rejects the operation — including when the graph
    /// changed between staging and approval so the staged reference no longer
    /// resolves. The proposal store records the failure on the proposal.
    func perform(_ operation: HomeKitOperation) async throws -> String?
}

/// Why an executor refused or failed an operation. Executors throw this; the
/// proposal store records the message on the proposal for agent and human.
public enum HomeKitWriteError: Error, Equatable, Sendable {
    /// The staged reference (room, zone, scene, group, home) no longer resolves.
    case objectMissing(String)
    /// HomeKit rejects duplicate names for rooms, scenes, and groups.
    case duplicateName(String)
    /// The operation is malformed (e.g. an unknown service in a group diff).
    case invalidOperation(String)

    public var message: String {
        switch self {
        case .objectMissing(let detail): detail
        case .duplicateName(let detail): detail
        case .invalidOperation(let detail): detail
        }
    }
}
