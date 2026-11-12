import Foundation

// MARK: - Device home view

/// Everything the resolver needs to know about the live home database,
/// extracted from `HMHomeManager` objects into pure data.
///
/// `HMHome` and friends cannot be constructed in unit tests, so the resolver
/// never sees them — it reads this snapshot instead. Tests build fixtures
/// directly; the executor builds it from the live manager right before each
/// operation. IDs are HomeKit `uniqueIdentifier` strings, the same ids the
/// read side's `HomeGraph` exposes.
struct DeviceHomeView: Equatable, Sendable {
    struct Home: Equatable, Sendable {
        var id: String
        var name: String
        var rooms: [Room] = []
        var zones: [Zone] = []
        var scenes: [Scene] = []
        var serviceGroups: [ServiceGroup] = []
        var triggers: [Trigger] = []
        var accessories: [Accessory] = []
    }

    struct Room: Equatable, Sendable {
        var id: String
        var name: String
        var accessoryIds: [String] = []
    }

    struct Zone: Equatable, Sendable {
        var id: String
        var name: String
        var roomIds: [String] = []
    }

    /// A scene's actions as the diff keys the read side computes — matching a
    /// removal against existing actions uses the same identity.
    struct Scene: Equatable, Sendable {
        var id: String
        var name: String
        var actionKeys: [SceneActionKey] = []
    }

    struct ServiceGroup: Equatable, Sendable {
        var id: String
        var name: String
        var serviceIds: [String] = []
    }

    struct Trigger: Equatable, Sendable {
        var id: String
        var name: String
        var isEnabled: Bool
        /// Nil for event triggers; timers always have a fire date.
        var timerFireDate: Date?
        var timerRecurrence: [String: Int] = [:]
        /// Scenes linked via `HMTrigger.actionSets` — preserved across a
        /// remove+re-add schedule update.
        var linkedSceneIds: [String] = []

        var isTimer: Bool { timerFireDate != nil }
    }

    struct Accessory: Equatable, Sendable {
        var id: String
        var name: String
        /// `HMAccessory.supportsIdentify` — false means the accessory has no
        /// Identify characteristic and cannot flash or beep. Nil in fixtures
        /// that predate the field; nil stays permissive like other
        /// capability data.
        var supportsIdentify: Bool?
        var services: [Service] = []
    }

    struct Service: Equatable, Sendable {
        var id: String
        var name: String?
        var serviceType: String
        var characteristics: [Characteristic] = []
    }

    struct Characteristic: Equatable, Sendable {
        var id: String
        /// The HomeKit characteristic type string — the type UUID in live
        /// data, e.g. `00000008-0000-1000-8000-0026BB765291`.
        var type: String
        /// The characteristic's friendly name, e.g. `Brightness` — nil when
        /// HomeKit exposes none.
        var name: String?
        /// The value family the characteristic's metadata declares.
        var kind: ValueKind = .unknown
        /// The declared value constraints — bounds and valid values the
        /// direct-write check enforces. Nil when HomeKit exposes none;
        /// nil stays permissive, like other capability data.
        var metadata: HomeGraph.CharacteristicMetadata?
    }

    /// How a characteristic renders values, from `HMCharacteristicMetadata.format`.
    enum ValueKind: Equatable, Sendable {
        /// `HMCharacteristicMetadataFormatString` — writes must be NSString.
        case string
        /// Bool, int, float, and uint formats — writes must be NSNumber.
        case number
        /// No metadata (or an unrecognized format): accept either rendering.
        case unknown
    }

    var homes: [Home] = []
}

extension DeviceHomeView.ValueKind {
    /// The rendering family a metadata format string implies — one
    /// derivation shared by the graph reads and the device view. A test
    /// pins these literals to the HomeKit format constants.
    init(format: String?) {
        switch format {
        case "string": self = .string
        case "bool", "int", "float", "uint8", "uint16", "uint32", "uint64": self = .number
        default: self = .unknown
        }
    }
}

// MARK: - Resolved steps

/// One concretely-resolved HomeKit call: every staged id has been matched
/// against the view and every value has its rendering kind chosen. The
/// executor re-resolves the referenced ids against the live manager
/// immediately before each call (never cached across the run).
enum DeviceWriteStep: Equatable, Sendable {
    case addRoom(homeId: String, name: String)
    case renameRoom(homeId: String, roomId: String, to: String)
    case removeRoom(homeId: String, roomId: String)
    case updateZoneRooms(homeId: String, zoneId: String, addRoomIds: [String], removeRoomIds: [String])
    case createZone(homeId: String, name: String)
    case renameZone(homeId: String, zoneId: String, to: String)
    case removeZone(homeId: String, zoneId: String)
    case createActionSet(homeId: String, name: String, actions: [ResolvedAction])
    case updateSceneActions(homeId: String, sceneId: String, add: [ResolvedAction], remove: [SceneActionKey])
    case renameActionSet(homeId: String, sceneId: String, to: String)
    case removeActionSet(homeId: String, sceneId: String)
    case executeActionSet(homeId: String, sceneId: String)
    case addServiceGroup(homeId: String, name: String, serviceIds: [String])
    case updateServiceGroupMembers(homeId: String, groupId: String, addServiceIds: [String], removeServiceIds: [String])
    case renameServiceGroup(homeId: String, groupId: String, to: String)
    case removeServiceGroup(homeId: String, groupId: String)
    case createTimerTrigger(homeId: String, name: String, fireDate: Date, recurrence: DateComponents?, sceneId: String?)
    case createEventTrigger(
        homeId: String, name: String, events: [ResolvedEvent], endEvents: [ResolvedEvent],
        executeOnce: Bool, sceneId: String?
    )
    case updateEventTrigger(
        homeId: String, triggerId: String, events: [ResolvedEvent], endEvents: [ResolvedEvent]?,
        recurrences: [DateComponents]?, executeOnce: Bool?, sceneId: String?
    )
    case setTriggerEnabled(homeId: String, triggerId: String, enabled: Bool)
    /// `HMTimerTrigger.fireDate` is readonly — a schedule change removes the
    /// old trigger and re-adds a new one with the same shape, then restores
    /// the prior enabled state (the only place a write may arm a trigger, and
    /// only because a human already approved it). Returns the new id.
    case replaceTimerTrigger(
        homeId: String, triggerId: String, fireDate: Date, recurrence: DateComponents?,
        wasEnabled: Bool, linkedSceneIds: [String]
    )
    case removeTrigger(homeId: String, triggerId: String)
    case renameAccessory(homeId: String, accessoryId: String, to: String)
    case identifyAccessory(homeId: String, accessoryId: String)
    case assignAccessoryToRoom(homeId: String, accessoryId: String, roomId: String)
    case unblockAccessory(homeId: String, accessoryId: String)
    case removeAccessory(homeId: String, accessoryId: String)
    case writeCharacteristic(homeId: String, action: ResolvedAction)
}

/// A scene action with its characteristic resolved and its value's rendering
/// kind chosen from the characteristic's metadata.
struct ResolvedAction: Equatable, Sendable {
    var accessoryId: String
    var serviceId: String
    var characteristicId: String
    var characteristicType: String
    var kind: DeviceHomeView.ValueKind
    var value: HomeKitValue
}

/// An event trigger member with the generic specialization chosen — the same
/// set the read side enumerates (`HMCharacteristicEvent<NSNumber/NSString/
/// NSNull>`, `HMPresenceEvent`).
enum ResolvedEvent: Equatable, Sendable {
    case characteristic(id: String, type: String, value: ResolvedTriggerValue)
    case presence(atHome: Bool)
}

/// The chosen specialization and value for a characteristic event.
enum ResolvedTriggerValue: Equatable, Sendable {
    /// `HMCharacteristicEvent<NSNumber>` with the value converted.
    case number(HomeKitValue)
    /// `HMCharacteristicEvent<NSString>`.
    case string(String)
    /// `HMCharacteristicEvent<NSNull>` with a nil trigger value — the event
    /// fires on any change of the characteristic.
    case anyChange
}

// MARK: - Resolver

/// Pure translation of staged `HomeKitOperation`s into ordered, concretely
/// resolved `DeviceWriteStep`s — the CI-testable half of the device executor.
///
/// Resolves every staged graph id against a `DeviceHomeView` snapshot of the
/// live manager (throwing `HomeKitWriteError.objectMissing` on drift),
/// pre-checks duplicate names the way HomeKit does (throwing
/// `.duplicateName`), validates timer constraints HomeKit enforces at
/// addTrigger time, and picks the value/event specializations from
/// characteristic metadata (`.invalidOperation` on type mismatches). The
/// executor re-resolves ids against the live manager before each call —
/// the view is a decision input, never a cache across the run.
enum DeviceWriteResolver {
    static func resolve(_ operation: HomeKitOperation, in view: DeviceHomeView) throws -> [DeviceWriteStep] {
        switch operation {
        case .addRoom(let homeId, let name):
            let home = try home(id: homeId, in: view)
            if let why = nameViolation(name) {
                throw HomeKitWriteError.invalidOperation("New room name “\(name)” in “\(home.name)”: \(why).")
            }
            if home.rooms.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                throw HomeKitWriteError.duplicateName("Home already has a room named “\(name)”.")
            }
            return [.addRoom(homeId: home.id, name: name)]
        case .renameRoom(let homeId, let roomId, let to):
            let home = try home(id: homeId, in: view)
            let room = try resolvedRoom(id: roomId, in: home)
            if let why = nameViolation(to) {
                throw HomeKitWriteError.invalidOperation("Room “\(room.name)” cannot be renamed to “\(to)”: \(why).")
            }
            return [.renameRoom(homeId: home.id, roomId: room.id, to: to)]
        case .removeRoom(let homeId, let roomId):
            let home = try home(id: homeId, in: view)
            let room = try resolvedRoom(id: roomId, in: home)
            return [.removeRoom(homeId: home.id, roomId: room.id)]
        case .setZoneRooms(let homeId, let zoneId, let addRoomIds, let removeRoomIds):
            return [try resolveZoneRooms(homeId: homeId, zoneId: zoneId, addRoomIds: addRoomIds, removeRoomIds: removeRoomIds, in: view)]
        case .createZone(let homeId, let name):
            let home = try home(id: homeId, in: view)
            if let why = nameViolation(name) {
                throw HomeKitWriteError.invalidOperation("New zone name “\(name)” in “\(home.name)”: \(why).")
            }
            if home.zones.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                throw HomeKitWriteError.duplicateName("Home already has a zone named “\(name)”.")
            }
            return [.createZone(homeId: home.id, name: name)]
        case .renameZone(let homeId, let zoneId, let to):
            let home = try home(id: homeId, in: view)
            let zone = try zone(id: zoneId, in: home)
            if let why = nameViolation(to) {
                throw HomeKitWriteError.invalidOperation("Zone “\(zone.name)” cannot be renamed to “\(to)”: \(why).")
            }
            // Zone names are unique within a home; the new name cannot
            // collide with another zone — this one included.
            if home.zones.contains(where: { $0.id != zone.id && $0.name.caseInsensitiveCompare(to) == .orderedSame }) {
                throw HomeKitWriteError.duplicateName("Home already has a zone named “\(to)”.")
            }
            return [.renameZone(homeId: home.id, zoneId: zone.id, to: to)]
        case .removeZone(let homeId, let zoneId):
            let home = try home(id: homeId, in: view)
            let zone = try zone(id: zoneId, in: home)
            // Rooms survive untouched — removing a zone dissolves only the
            // grouping; the review card says so.
            return [.removeZone(homeId: home.id, zoneId: zone.id)]
        case .addActionSet(let homeId, let name, let actions):
            return [try resolveCreateActionSet(homeId: homeId, name: name, actions: actions, in: view)]
        case .setSceneActions(let homeId, let sceneId, let add, let remove):
            return [try resolveSceneActions(homeId: homeId, sceneId: sceneId, add: add, remove: remove, in: view)]
        case .renameActionSet(let homeId, let sceneId, let to):
            return [try resolveRenameActionSet(homeId: homeId, sceneId: sceneId, to: to, in: view)]
        case .removeActionSet(let homeId, let sceneId):
            let home = try home(id: homeId, in: view)
            let scene = try scene(id: sceneId, in: home)
            // Triggers linking this scene keep pointing at it — HomeKit
            // detaches the action set itself; the card says so. Keeping is
            // legal, so nothing here blocks or warns.
            return [.removeActionSet(homeId: home.id, sceneId: scene.id)]
        case .executeActionSet(let homeId, let sceneId):
            let home = try home(id: homeId, in: view)
            let scene = try scene(id: sceneId, in: home)
            if scene.actionKeys.isEmpty {
                throw HomeKitWriteError.invalidOperation(
                    "Scene “\(scene.name)” has no actions — HomeKit refuses to execute an empty scene."
                )
            }
            return [.executeActionSet(homeId: home.id, sceneId: scene.id)]
        case .addServiceGroup(let homeId, let name, let serviceIds):
            let home = try home(id: homeId, in: view)
            if let why = nameViolation(name) {
                throw HomeKitWriteError.invalidOperation("New service group name “\(name)” in “\(home.name)”: \(why).")
            }
            if home.serviceGroups.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                throw HomeKitWriteError.duplicateName("Home already has a service group named “\(name)”.")
            }
            // Member services are validated against the live view so a stale
            // id fails before anything is staged for execution.
            let knownServiceIds = Set(home.accessories.flatMap(\.services).map(\.id))
            let unknown = Set(serviceIds).subtracting(knownServiceIds).sorted()
            guard unknown.isEmpty else {
                throw HomeKitWriteError.objectMissing(
                    "No service \(unknown.joined(separator: ", ")) in “\(home.name)”."
                )
            }
            return [.addServiceGroup(homeId: home.id, name: name, serviceIds: serviceIds)]
        case .setServiceGroupMembers(let homeId, let groupId, let addServiceIds, let removeServiceIds):
            return [try resolveServiceGroupMembers(homeId: homeId, groupId: groupId, addServiceIds: addServiceIds, removeServiceIds: removeServiceIds, in: view)]
        case .removeServiceGroup(let homeId, let groupId):
            let home = try home(id: homeId, in: view)
            let group = try serviceGroup(id: groupId, in: home)
            return [.removeServiceGroup(homeId: home.id, groupId: group.id)]
        case .renameServiceGroup(let homeId, let groupId, let to):
            let home = try home(id: homeId, in: view)
            let group = try serviceGroup(id: groupId, in: home)
            if let why = nameViolation(to) {
                throw HomeKitWriteError.invalidOperation("Service group “\(group.name)” cannot be renamed to “\(to)”: \(why).")
            }
            // Group names are unique within a home; the new name cannot
            // collide with another group — this one included.
            if home.serviceGroups.contains(where: { $0.id != group.id && $0.name.caseInsensitiveCompare(to) == .orderedSame }) {
                throw HomeKitWriteError.duplicateName("Home already has a service group named “\(to)”.")
            }
            return [.renameServiceGroup(homeId: home.id, groupId: group.id, to: to)]
        case .addTimerTrigger(let homeId, let name, let fireDate, let recurrence, let sceneId):
            return [try resolveCreateTimerTrigger(homeId: homeId, name: name, fireDate: fireDate, recurrence: recurrence, sceneId: sceneId, in: view)]
        case .addEventTrigger(let homeId, let name, let events, let endEvents, let executeOnce, let sceneId):
            return [try resolveCreateEventTrigger(
                homeId: homeId, name: name, events: events, endEvents: endEvents,
                executeOnce: executeOnce, sceneId: sceneId, in: view
            )]
        case .updateEventTrigger(
            let homeId, let triggerId, let events, let endEvents, let recurrences, let executeOnce, let sceneId
        ):
            return [try resolveUpdateEventTrigger(
                homeId: homeId, triggerId: triggerId, events: events, endEvents: endEvents,
                recurrences: recurrences, executeOnce: executeOnce, sceneId: sceneId, in: view
            )]
        case .setTriggerEnabled(let homeId, let triggerId, let enabled):
            let resolvedHome = try home(id: homeId, in: view)
            let resolvedTrigger = try trigger(id: triggerId, in: view)
            // Device law: HomeKit refuses to enable a trigger with no
            // registered action sets (HMError "No registered action sets for
            // trigger"). Reject it here — where the error reaches the agent
            // as an actionable message — instead of a raw HomeKit error
            // after approval. Disabling is always allowed.
            if enabled, resolvedTrigger.linkedSceneIds.isEmpty {
                throw HomeKitWriteError.invalidOperation(
                    "Trigger “\(resolvedTrigger.name)” has no action sets — HomeKit cannot enable an automation that runs nothing. Recreate it with a scene (sceneId), then arm it."
                )
            }
            return [.setTriggerEnabled(homeId: resolvedHome.id, triggerId: resolvedTrigger.id, enabled: enabled)]
        case .updateTimerTrigger(let homeId, let triggerId, let fireDate, let recurrence):
            return [try resolveReplaceTimerTrigger(homeId: homeId, triggerId: triggerId, fireDate: fireDate, recurrence: recurrence, in: view)]
        case .removeTrigger(let homeId, let triggerId):
            return [.removeTrigger(homeId: try home(id: homeId, in: view).id, triggerId: try trigger(id: triggerId, in: view).id)]
        case .renameAccessory(let homeId, let accessoryId, let to):
            let resolvedHome = try home(id: homeId, in: view)
            let resolvedAccessory = try accessory(id: accessoryId, in: resolvedHome)
            // Device law: HomeKit refuses names that do not start and end
            // with a letter or digit (HMError 60 felled the QA rename to
            // “Office Lights (QA)”). Rejecting here — naming the accessory
            // and the offending characters — keeps a passing proposal from
            // failing at execution.
            if let why = nameViolation(to) {
                throw HomeKitWriteError.invalidOperation(
                    "Accessory “\(resolvedAccessory.name)” cannot be renamed to “\(to)”: \(why)."
                )
            }
            return [.renameAccessory(homeId: resolvedHome.id, accessoryId: resolvedAccessory.id, to: to)]
        case .identifyAccessory(let homeId, let accessoryId):
            let resolvedHome = try home(id: homeId, in: view)
            let resolvedAccessory = try accessory(id: accessoryId, in: resolvedHome)
            // Device law: identifying means flashing the Identify
            // characteristic; accessories without one reject the call. Say
            // so at resolution where the typed error reaches the agent.
            if resolvedAccessory.supportsIdentify == false {
                throw HomeKitWriteError.invalidOperation(
                    "Accessory “\(resolvedAccessory.name)” does not support identify — it has no Identify characteristic."
                )
            }
            return [.identifyAccessory(homeId: resolvedHome.id, accessoryId: resolvedAccessory.id)]
        case .assignAccessoryToRoom(let homeId, let accessoryId, let roomId):
            let resolvedHome = try home(id: homeId, in: view)
            let resolvedAccessory = try accessory(id: accessoryId, in: resolvedHome)
            let resolvedRoom = try resolvedRoom(id: roomId, in: resolvedHome)
            return [.assignAccessoryToRoom(homeId: resolvedHome.id, accessoryId: resolvedAccessory.id, roomId: resolvedRoom.id)]
        case .unblockAccessory(let homeId, let accessoryId):
            let resolvedHome = try home(id: homeId, in: view)
            let resolvedAccessory = try accessory(id: accessoryId, in: resolvedHome)
            // Blocked state is not tracked in the view (the read flags are
            // the read-depth group's); unblocking an unblocked accessory is
            // a harmless no-op in HomeKit, so only existence is checked.
            return [.unblockAccessory(homeId: resolvedHome.id, accessoryId: resolvedAccessory.id)]
        case .removeAccessory(let homeId, let accessoryId):
            let resolvedHome = try home(id: homeId, in: view)
            let resolvedAccessory = try accessory(id: accessoryId, in: resolvedHome)
            return [.removeAccessory(homeId: resolvedHome.id, accessoryId: resolvedAccessory.id)]
        case .writeCharacteristic(let homeId, let spec):
            let home = try home(id: homeId, in: view)
            let target = try resolveTarget(spec, in: home)
            // The same value check staging runs — a proposal that passes
            // staging must execute, and one that fails staging must fail
            // everywhere.
            if let why = valueViolation(spec.value, kind: target.characteristic.kind, metadata: target.characteristic.metadata) {
                throw HomeKitWriteError.invalidOperation(
                    "Characteristic \(spec.characteristic) on “\(target.accessory.name)” cannot take \(spec.value.rendered): \(why)."
                )
            }
            return [.writeCharacteristic(
                homeId: home.id,
                action: ResolvedAction(
                    accessoryId: target.accessory.id,
                    serviceId: target.service.id,
                    characteristicId: target.characteristic.id,
                    characteristicType: target.characteristic.type,
                    kind: target.characteristic.kind,
                    value: spec.value
                )
            )]
        }
    }

    // MARK: Per-operation resolution

    private static func resolveZoneRooms(
        homeId: String, zoneId: String, addRoomIds: [String], removeRoomIds: [String], in view: DeviceHomeView
    ) throws -> DeviceWriteStep {
        let home = try home(id: homeId, in: view)
        let zone = try zone(id: zoneId, in: home)
        for roomId in removeRoomIds where !zone.roomIds.contains(roomId) {
            throw HomeKitWriteError.objectMissing("Zone “\(zone.name)” does not contain room \(roomId).")
        }
        for roomId in addRoomIds where room(id: roomId, in: home) == nil {
            throw HomeKitWriteError.objectMissing("No room \(roomId) to add to zone “\(zone.name)”.")
        }
        return .updateZoneRooms(homeId: home.id, zoneId: zone.id, addRoomIds: addRoomIds, removeRoomIds: removeRoomIds)
    }

    private static func resolveCreateActionSet(
        homeId: String, name: String, actions: [SceneActionSpec], in view: DeviceHomeView
    ) throws -> DeviceWriteStep {
        let home = try home(id: homeId, in: view)
        // Duplicate scene names are rejected the way HomeKit's are, across
        // all homes — the same rule the fake and the evidence read-back use.
        if let why = nameViolation(name) {
            throw HomeKitWriteError.invalidOperation("New scene name “\(name)” in “\(home.name)”: \(why).")
        }
        if view.homes.contains(where: { $0.scenes.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } }) {
            throw HomeKitWriteError.duplicateName("Home already has a scene named “\(name)”.")
        }
        let resolved = try actions.map { try resolveAction($0, in: home) }
        return .createActionSet(homeId: home.id, name: name, actions: resolved)
    }

    private static func resolveSceneActions(
        homeId: String, sceneId: String, add: [SceneActionSpec], remove: [SceneActionKey], in view: DeviceHomeView
    ) throws -> DeviceWriteStep {
        let home = try home(id: homeId, in: view)
        let scene = try scene(id: sceneId, in: home)
        let resolved = try add.map { try resolveAction($0, in: home) }
        return .updateSceneActions(homeId: home.id, sceneId: scene.id, add: resolved, remove: remove)
    }
    private static func resolveRenameActionSet(
        homeId: String, sceneId: String, to: String, in view: DeviceHomeView
    ) throws -> DeviceWriteStep {
        let home = try home(id: homeId, in: view)
        let scene = try scene(id: sceneId, in: home)
        if let why = nameViolation(to) {
            throw HomeKitWriteError.invalidOperation("Scene “\(scene.name)” cannot be renamed to “\(to)”: \(why).")
        }
        if scene.name.caseInsensitiveCompare(to) == .orderedSame {
            return .renameActionSet(homeId: home.id, sceneId: scene.id, to: to)
        }
        // Duplicate scene names are rejected the way HomeKit's are, across
        // all homes — the renamed scene cannot collide with another.
        if view.homes.contains(where: {
            $0.scenes.contains { $0.id != scene.id && $0.name.caseInsensitiveCompare(to) == .orderedSame }
        }) {
            throw HomeKitWriteError.duplicateName("Home already has a scene named “\(to)”.")
        }
        return .renameActionSet(homeId: home.id, sceneId: scene.id, to: to)
    }

    private static func resolveServiceGroupMembers(
        homeId: String, groupId: String, addServiceIds: [String], removeServiceIds: [String], in view: DeviceHomeView
    ) throws -> DeviceWriteStep {
        let home = try home(id: homeId, in: view)
        let group = try serviceGroup(id: groupId, in: home)
        for serviceId in removeServiceIds where !group.serviceIds.contains(serviceId) {
            throw HomeKitWriteError.objectMissing("Group “\(group.name)” does not contain service \(serviceId).")
        }
        for serviceId in addServiceIds where service(id: serviceId, in: home) == nil {
            throw HomeKitWriteError.invalidOperation("No service \(serviceId) in any accessory of this home.")
        }
        return .updateServiceGroupMembers(
            homeId: home.id, groupId: group.id, addServiceIds: addServiceIds, removeServiceIds: removeServiceIds
        )
    }

    private static func resolveCreateTimerTrigger(
        homeId: String, name: String, fireDate: Date, recurrence: [String: Int], sceneId: String?, in view: DeviceHomeView
    ) throws -> DeviceWriteStep {
        let home = try home(id: homeId, in: view)
        let components = try timerComponents(fireDate: fireDate, recurrence: recurrence)
        let scene = try optionalScene(id: sceneId, in: home)
        return .createTimerTrigger(homeId: home.id, name: name, fireDate: fireDate, recurrence: components, sceneId: scene?.id)
    }

    private static func resolveCreateEventTrigger(
        homeId: String, name: String, events: [TriggerEventSpec], endEvents: [TriggerEventSpec],
        executeOnce: Bool, sceneId: String?, in view: DeviceHomeView
    ) throws -> DeviceWriteStep {
        let home = try home(id: homeId, in: view)
        let resolved = try resolveEvents(events, in: home)
        let resolvedEndEvents = try resolveEvents(endEvents, in: home)
        let scene = try optionalScene(id: sceneId, in: home)
        return .createEventTrigger(
            homeId: home.id, name: name, events: resolved, endEvents: resolvedEndEvents,
            executeOnce: executeOnce, sceneId: scene?.id
        )
    }

    private static func resolveUpdateEventTrigger(
        homeId: String, triggerId: String, events: [TriggerEventSpec], endEvents: [TriggerEventSpec]?,
        recurrences: [[String: Int]]?, executeOnce: Bool?, sceneId: String?, in view: DeviceHomeView
    ) throws -> DeviceWriteStep {
        let home = try home(id: homeId, in: view)
        let old = try trigger(id: triggerId, in: view)
        guard !old.isTimer else {
            throw HomeKitWriteError.invalidOperation(
                "Trigger \(old.name) is a timer trigger — set_trigger_state moves its schedule; event triggers have no fire date."
            )
        }
        let resolvedEvents = try resolveEvents(events, in: home)
        let resolvedEndEvents = try endEvents.map { try resolveEvents($0, in: home) }
        let components = try eventTriggerRecurrences(recurrences)
        let scene = try optionalScene(id: sceneId, in: home)
        return .updateEventTrigger(
            homeId: home.id, triggerId: old.id, events: resolvedEvents,
            endEvents: resolvedEndEvents, recurrences: components,
            executeOnce: executeOnce, sceneId: scene?.id
        )
    }

    /// Event-trigger recurrences are days of the week — HomeKit honors only
    /// the `weekday` component (`HMEventTrigger.updateRecurrences`). The same
    /// JSON shape timers use, one weekday (1…7, 1 = Sunday) per entry; an
    /// empty array clears the recurrence.
    private static func eventTriggerRecurrences(_ recurrences: [[String: Int]]?) throws -> [DateComponents]? {
        guard let recurrences else { return nil }
        return try recurrences.map { components in
            guard components.count == 1, let weekday = components["weekday"], (1...7).contains(weekday) else {
                throw HomeKitWriteError.invalidOperation(
                    "Event-trigger recurrences are days of the week — one “weekday” component (1…7, 1 = Sunday) per entry."
                )
            }
            var dateComponents = DateComponents()
            dateComponents.weekday = weekday
            return dateComponents
        }
    }

    private static func resolveReplaceTimerTrigger(
        homeId: String, triggerId: String, fireDate: Date, recurrence: [String: Int], in view: DeviceHomeView
    ) throws -> DeviceWriteStep {
        let home = try home(id: homeId, in: view)
        let old = try trigger(id: triggerId, in: view)
        guard old.isTimer else {
            throw HomeKitWriteError.invalidOperation("Trigger “\(old.name)” is not a timer trigger; it has no fire date.")
        }
        let components = try timerComponents(fireDate: fireDate, recurrence: recurrence)
        return .replaceTimerTrigger(
            homeId: home.id, triggerId: old.id, fireDate: fireDate, recurrence: components,
            wasEnabled: old.isEnabled, linkedSceneIds: old.linkedSceneIds
        )
    }

    // MARK: Shared resolution helpers

    /// The heavy lookup: accessory -> service (by name or type, else the one
    /// carrying the characteristic) -> characteristic (by type or name).
    private static func resolveTarget(
        _ spec: SceneActionSpec, in home: DeviceHomeView.Home
    ) throws -> (accessory: DeviceHomeView.Accessory, service: DeviceHomeView.Service, characteristic: DeviceHomeView.Characteristic) {
        let accessory = try accessory(id: spec.accessoryId, in: home)
        if let wanted = spec.service {
            let matching = accessory.services.filter {
                $0.name.map { $0.caseInsensitiveCompare(wanted) == .orderedSame } == true
                    || $0.serviceType.caseInsensitiveCompare(wanted) == .orderedSame
            }
            guard let matched = matching.first(
                where: { $0.characteristics.contains { characteristicMatches($0, spec.characteristic) } }
            ) ?? matching.first else {
                throw HomeKitWriteError.objectMissing(
                    "Accessory “\(accessory.name)” has no service “\(wanted)” with characteristic \(spec.characteristic)."
                )
            }
            guard let characteristic = matched.characteristics.first(where: { characteristicMatches($0, spec.characteristic) }) else {
                throw HomeKitWriteError.objectMissing(
                    "Service “\(matched.name ?? matched.serviceType)” has no characteristic \(spec.characteristic)."
                )
            }
            return (accessory, matched, characteristic)
        }
        guard let matched = accessory.services.first(
            where: { $0.characteristics.contains { characteristicMatches($0, spec.characteristic) } }
        ) else {
            throw HomeKitWriteError.objectMissing(
                "Accessory “\(accessory.name)” has no service with characteristic \(spec.characteristic)."
            )
        }
        guard let characteristic = matched.characteristics.first(where: { characteristicMatches($0, spec.characteristic) }) else {
            throw HomeKitWriteError.objectMissing(
                "Service “\(matched.name ?? matched.serviceType)” has no characteristic \(spec.characteristic)."
            )
        }
        return (accessory, matched, characteristic)
    }

    private static func resolveAction(_ spec: SceneActionSpec, in home: DeviceHomeView.Home) throws -> ResolvedAction {
        let (accessory, service, characteristic) = try resolveTarget(spec, in: home)
        // The same full metadata check staging runs (kind, bounds, step,
        // valid values) — a proposal that passes staging must execute, and
        // one that fails staging must fail everywhere.
        if let why = valueViolation(spec.value, kind: characteristic.kind, metadata: characteristic.metadata) {
            throw HomeKitWriteError.invalidOperation(
                "Characteristic \(spec.characteristic) on “\(accessory.name)” cannot take \(spec.value.rendered): \(why)."
            )
        }
        return ResolvedAction(
            accessoryId: accessory.id,
            serviceId: service.id,
            characteristicId: characteristic.id,
            characteristicType: characteristic.type,
            kind: characteristic.kind,
            value: spec.value
        )
    }

    private static func resolveEvents(_ events: [TriggerEventSpec], in home: DeviceHomeView.Home) throws -> [ResolvedEvent] {
        let kinds = events.map(\.presenceAtHome)
        guard kinds.allSatisfy({ $0 == nil }) || kinds.allSatisfy({ $0 != nil }) else {
            throw HomeKitWriteError.invalidOperation(
                "An event trigger is one kind of event per member — presence and characteristic events cannot mix."
            )
        }
        return try events.map { event in
            switch event {
            case .characteristic(let accessoryId, let characteristicType, let value):
                let accessory = try accessory(id: accessoryId, in: home)
                guard let characteristic = accessory.services.flatMap(\.characteristics)
                    .first(where: { characteristicMatches($0, characteristicType) }) else {
                    throw HomeKitWriteError.objectMissing(
                        "Accessory “\(accessory.name)” has no characteristic \(characteristicType)."
                    )
                }
                let resolved: ResolvedTriggerValue
                switch value {
                case nil:
                    resolved = .anyChange
                case .some(.string(let string)):
                    guard characteristic.kind != .number else {
                        throw HomeKitWriteError.invalidOperation(
                            "Characteristic \(characteristicType) holds numbers, not the string “\(string)”.")
                    }
                    resolved = .string(string)
                case .some(let numeric):
                    guard characteristic.kind != .string else {
                        throw HomeKitWriteError.invalidOperation(
                            "Characteristic \(characteristicType) holds strings, not \(numeric.rendered).")
                    }
                    resolved = .number(numeric)
                }
                return .characteristic(id: characteristic.id, type: characteristic.type, value: resolved)
            case .presence(let atHome):
                return .presence(atHome: atHome)
            }
        }
    }

    /// Agents spell the target either way the read side exposes it: the
    /// HomeKit type string (a UUID in live data) or the friendly name.
    private static func characteristicMatches(
        _ characteristic: DeviceHomeView.Characteristic, _ wanted: String
    ) -> Bool {
        characteristic.type.caseInsensitiveCompare(wanted) == .orderedSame
            || characteristic.name?.caseInsensitiveCompare(wanted) == .orderedSame
    }

    /// Whether a value's type fits a characteristic's rendering family — one
    /// rule for scene actions and direct writes alike. Strings that widen
    /// into a numeric format conform after conversion (see `valueViolation`);
    /// the kind check itself stays strict.
    static func isKindCompatible(_ value: HomeKitValue, kind: DeviceHomeView.ValueKind) -> Bool {
        switch (kind, value) {
        case (.string, .string): true
        case (.number, .bool), (.number, .int), (.number, .double): true
        case (.unknown, _): true
        case (.string, _), (.number, _): false
        }
    }

    /// Does the value fit the characteristic's declared metadata? The ONE
    /// check staging (planner, over the graph) and resolution (executor,
    /// over the device view) both run — a proposal that passes staging must
    /// execute, and one that fails staging must fail everywhere. Returns the
    /// reason the value is invalid, or nil when it fits.
    ///
    /// One widening applies: a numeric string for a numeric format conforms
    /// after conversion — '30' for a brightness int writes as 30. Booleans
    /// never widen: a string '0' is a type error, not a false (the Power
    /// State '0' failure the Nov 12 Duo QA run caught at execution).
    static func valueViolation(
        _ value: HomeKitValue, kind: DeviceHomeView.ValueKind, metadata: HomeGraph.CharacteristicMetadata?
    ) -> String? {
        guard isKindCompatible(value, kind: kind) else {
            if case .string(let text) = value, kind == .number {
                // Kind .number is derived from the metadata format, so a
                // number-kind characteristic carries a format string here;
                // stay defensive when it does not.
                if let format = metadata?.format, Self.isNumericFormat(format) {
                    guard let converted = Self.numericValue(in: text) else {
                        return "holds numbers, not the string “\(text)”"
                    }
                    return Self.numericViolation(converted, rendered: value.rendered, metadata: metadata)
                }
                if metadata?.format == "bool" {
                    return "takes a boolean (true or false), not the string “\(text)”"
                }
                return "holds numbers, not the string “\(text)”"
            }
            switch value {
            case .string(let text): return "holds numbers, not the string “\(text)”"
            case .bool, .int, .double: return "holds strings, not \(value.rendered)"
            }
        }
        let numeric: Double?
        switch value {
        case .bool(let flag): numeric = flag ? 1 : 0
        case .int(let int): numeric = Double(int)
        case .double(let double): numeric = double
        case .string: numeric = nil
        }
        guard let numeric else { return nil }
        return Self.numericViolation(numeric, rendered: value.rendered, metadata: metadata)
    }

    /// The numeric-constraint half of `valueViolation` — bounds, step, and
    /// valid values — shared by the direct and the widened (converted
    /// string) paths.
    private static func numericViolation(
        _ numeric: Double, rendered: String, metadata: HomeGraph.CharacteristicMetadata?
    ) -> String? {
        guard let metadata else { return nil }
        if let minimum = metadata.minValue, let maximum = metadata.maxValue {
            if numeric < minimum || numeric > maximum {
                return "takes \(minimum)…\(maximum), so \(rendered) is out of range"
            }
        } else if let minimum = metadata.minValue, numeric < minimum {
            return "takes at least \(minimum), so \(rendered) is out of range"
        } else if let maximum = metadata.maxValue, numeric > maximum {
            return "takes at most \(maximum), so \(rendered) is out of range"
        }
        if let step = metadata.step, step > 0 {
            let base = metadata.minValue ?? 0
            let remainder = (numeric - base).truncatingRemainder(dividingBy: step)
            let skew = min(remainder, step - remainder)
            // Tolerance for binary-float drift on declared decimal steps.
            if skew > 0.000_001 {
                return "moves in steps of \(step) from \(base), so \(rendered) is not a step the characteristic accepts"
            }
        }
        if let valid = metadata.validValues, !valid.isEmpty,
           !valid.contains(where: { Double($0) == numeric }) {
            return "takes only \(valid.map(String.init).joined(separator: ", ")), and \(rendered) is not one of them"
        }
        return nil
    }

    /// Whether a metadata format is a numeric (non-bool) family — the
    /// formats a numeric string may widen into.
    private static func isNumericFormat(_ format: String) -> Bool {
        ["int", "float", "uint8", "uint16", "uint32", "uint64"].contains(format)
    }

    /// The number a numeric string spells, or nil when it is not a number —
    /// the widening conversion shared by staging, resolution, and the
    /// executor's Cocoa rendering.
    static func numericValue(in text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Fire dates must sit on the minute boundary and recurrences must be
    /// whole-minute intervals of at least 5 minutes and at most 5 weeks —
    /// `HMHome.addTrigger` returns HMError errors otherwise, so the resolver
    /// rejects them up front where the agent can fix them before approval.
    private static func timerComponents(fireDate: Date, recurrence: [String: Int]) throws -> DateComponents? {
        guard Calendar.current.dateComponents([.second], from: fireDate).second == 0 else {
            throw HomeKitWriteError.invalidOperation(
                "Timer fire dates must fall on the minute boundary — \(fireDate) has a seconds component."
            )
        }
        guard !recurrence.isEmpty else { return nil }
        var components = DateComponents()
        var minimumSeconds = 0.0
        var maximumSeconds = 0.0
        for (key, value) in recurrence {
            let unit: (Double, Double)
            switch key {
            case "year":
                components.year = value
                unit = (365 * 86400, 366 * 86400)
            case "month":
                components.month = value
                unit = (28 * 86400, 31 * 86400)
            case "weekday":
                components.weekday = value
                unit = (7 * 86400, 7 * 86400)
            case "day":
                components.day = value
                unit = (86400, 86400)
            case "hour":
                components.hour = value
                unit = (3600, 3600)
            case "minute":
                components.minute = value
                unit = (60, 60)
            case "second":
                guard value == 0 else {
                    throw HomeKitWriteError.invalidOperation(
                        "Timer recurrences must be whole minutes — \(value) seconds is not."
                    )
                }
                components.second = value
                unit = (1, 1)
            default:
                throw HomeKitWriteError.invalidOperation("Unknown recurrence component “\(key)”.")
            }
            if value != 0 {
                minimumSeconds += unit.0 * Double(value)
                maximumSeconds += unit.1 * Double(value)
            }
        }
        if maximumSeconds > 0, maximumSeconds < 5 * 60 {
            throw HomeKitWriteError.invalidOperation("Timer recurrence must be at least 5 minutes.")
        }
        if minimumSeconds > 5 * 7 * 86400 {
            throw HomeKitWriteError.invalidOperation("Timer recurrence must be at most 5 weeks.")
        }
        return components
    }

    /// Why HomeKit would refuse this name for a room, zone, scene, service
    /// group, or accessory, or nil when the name fits.
    ///
    /// HomeKit's rules (the HomeKit HIG, and the HMError family the live QA
    /// rename hit — code 60, “Name does not end with valid characters”): a
    /// name must be non-empty, at most 64 characters (the HAP Name
    /// characteristic cap), and start and end with a letter or digit.
    /// Interior punctuation the Home app itself tolerates (`&!-_:;()/+`) is
    /// deliberately not policed — refusing interior characters would reject
    /// names HomeKit accepts, the skew in mirror image. Trigger names are
    /// not written through the `updateName` family, so they are not held to
    /// this.
    static func nameViolation(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "names must not be empty"
        }
        if trimmed.count > maximumHomeKitNameLength {
            return "names are at most \(maximumHomeKitNameLength) characters, and this one is \(trimmed.count)"
        }
        if let first = trimmed.first, !isNameCharacter(first) {
            return "names must start with a letter or digit, and “\(first)” is neither"
        }
        if let last = trimmed.last, !isNameCharacter(last) {
            return "names must end with a letter or digit, and “\(last)” is neither"
        }
        return nil
    }

    private static let maximumHomeKitNameLength = 64

    private static func isNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    // MARK: View lookups

    private static func home(id: String, in view: DeviceHomeView) throws -> DeviceHomeView.Home {
        guard let home = view.homes.first(where: { $0.id == id }) else {
            throw HomeKitWriteError.objectMissing("No home \(id).")
        }
        return home
    }

    private static func room(id: String, in home: DeviceHomeView.Home) -> DeviceHomeView.Room? {
        home.rooms.first { $0.id == id }
    }

    private static func resolvedRoom(id: String, in home: DeviceHomeView.Home) throws -> DeviceHomeView.Room {
        guard let room = room(id: id, in: home) else {
            throw HomeKitWriteError.objectMissing("No room \(id).")
        }
        return room
    }

    private static func zone(id: String, in home: DeviceHomeView.Home) throws -> DeviceHomeView.Zone {
        guard let zone = home.zones.first(where: { $0.id == id }) else {
            throw HomeKitWriteError.objectMissing("No zone \(id).")
        }
        return zone
    }

    private static func scene(id: String, in home: DeviceHomeView.Home) throws -> DeviceHomeView.Scene {
        guard let scene = home.scenes.first(where: { $0.id == id }) else {
            throw HomeKitWriteError.objectMissing("No scene \(id).")
        }
        return scene
    }

    private static func optionalScene(id: String?, in home: DeviceHomeView.Home) throws -> DeviceHomeView.Scene? {
        guard let id else { return nil }
        return try scene(id: id, in: home)
    }

    private static func serviceGroup(id: String, in home: DeviceHomeView.Home) throws -> DeviceHomeView.ServiceGroup {
        guard let group = home.serviceGroups.first(where: { $0.id == id }) else {
            throw HomeKitWriteError.objectMissing("No service group \(id).")
        }
        return group
    }

    private static func trigger(id: String, in view: DeviceHomeView) throws -> DeviceHomeView.Trigger {
        guard let trigger = view.homes.flatMap(\.triggers).first(where: { $0.id == id }) else {
            throw HomeKitWriteError.objectMissing("No trigger \(id).")
        }
        return trigger
    }

    private static func accessory(id: String, in home: DeviceHomeView.Home) throws -> DeviceHomeView.Accessory {
        guard let accessory = home.accessories.first(where: { $0.id == id }) else {
            throw HomeKitWriteError.objectMissing("No accessory \(id) in home “\(home.name)”.")
        }
        return accessory
    }

    private static func service(id: String, in home: DeviceHomeView.Home) -> DeviceHomeView.Service? {
        home.accessories.flatMap(\.services).first { $0.id == id }
    }
}
