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
        /// The HomeKit characteristic type string, e.g. `On` or `Brightness`.
        var type: String
        /// The value family the characteristic's metadata declares.
        var kind: ValueKind = .unknown
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
    case createActionSet(homeId: String, name: String, actions: [ResolvedAction])
    case updateSceneActions(homeId: String, sceneId: String, add: [ResolvedAction], remove: [SceneActionKey])
    case addServiceGroup(homeId: String, name: String)
    case updateServiceGroupMembers(homeId: String, groupId: String, addServiceIds: [String], removeServiceIds: [String])
    case removeServiceGroup(homeId: String, groupId: String)
    case createTimerTrigger(homeId: String, name: String, fireDate: Date, recurrence: DateComponents?, sceneId: String?)
    case createEventTrigger(homeId: String, name: String, events: [ResolvedEvent], sceneId: String?)
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
            if home.rooms.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                throw HomeKitWriteError.duplicateName("Home already has a room named “\(name)”.")
            }
            return [.addRoom(homeId: home.id, name: name)]
        case .renameRoom(let homeId, let roomId, let to):
            let home = try home(id: homeId, in: view)
            let room = try resolvedRoom(id: roomId, in: home)
            return [.renameRoom(homeId: home.id, roomId: room.id, to: to)]
        case .removeRoom(let homeId, let roomId):
            let home = try home(id: homeId, in: view)
            let room = try resolvedRoom(id: roomId, in: home)
            return [.removeRoom(homeId: home.id, roomId: room.id)]
        case .setZoneRooms(let homeId, let zoneId, let addRoomIds, let removeRoomIds):
            return [try resolveZoneRooms(homeId: homeId, zoneId: zoneId, addRoomIds: addRoomIds, removeRoomIds: removeRoomIds, in: view)]
        case .addActionSet(let homeId, let name, let actions):
            return [try resolveCreateActionSet(homeId: homeId, name: name, actions: actions, in: view)]
        case .setSceneActions(let homeId, let sceneId, let add, let remove):
            return [try resolveSceneActions(homeId: homeId, sceneId: sceneId, add: add, remove: remove, in: view)]
        case .addServiceGroup(let homeId, let name):
            let home = try home(id: homeId, in: view)
            if home.serviceGroups.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                throw HomeKitWriteError.duplicateName("Home already has a service group named “\(name)”.")
            }
            return [.addServiceGroup(homeId: home.id, name: name)]
        case .setServiceGroupMembers(let homeId, let groupId, let addServiceIds, let removeServiceIds):
            return [try resolveServiceGroupMembers(homeId: homeId, groupId: groupId, addServiceIds: addServiceIds, removeServiceIds: removeServiceIds, in: view)]
        case .removeServiceGroup(let homeId, let groupId):
            let home = try home(id: homeId, in: view)
            let group = try serviceGroup(id: groupId, in: home)
            return [.removeServiceGroup(homeId: home.id, groupId: group.id)]
        case .addTimerTrigger(let homeId, let name, let fireDate, let recurrence, let sceneId):
            return [try resolveCreateTimerTrigger(homeId: homeId, name: name, fireDate: fireDate, recurrence: recurrence, sceneId: sceneId, in: view)]
        case .addEventTrigger(let homeId, let name, let events, let sceneId):
            return [try resolveCreateEventTrigger(homeId: homeId, name: name, events: events, sceneId: sceneId, in: view)]
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
        homeId: String, name: String, events: [TriggerEventSpec], sceneId: String?, in view: DeviceHomeView
    ) throws -> DeviceWriteStep {
        let home = try home(id: homeId, in: view)
        let resolved = try resolveEvents(events, in: home)
        let scene = try optionalScene(id: sceneId, in: home)
        return .createEventTrigger(homeId: home.id, name: name, events: resolved, sceneId: scene?.id)
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
    /// carrying the characteristic) -> characteristic (by type), with the
    /// value rendering kind picked from metadata.
    private static func resolveAction(_ spec: SceneActionSpec, in home: DeviceHomeView.Home) throws -> ResolvedAction {
        guard let accessory = accessory(id: spec.accessoryId, in: home) else {
            throw HomeKitWriteError.objectMissing("No accessory \(spec.accessoryId) in home “\(home.name)”.")
        }
        let characteristic: DeviceHomeView.Characteristic
        let service: DeviceHomeView.Service
        if let wanted = spec.service {
            let matching = accessory.services.filter {
                $0.name.map { $0.caseInsensitiveCompare(wanted) == .orderedSame } == true
                    || $0.serviceType.caseInsensitiveCompare(wanted) == .orderedSame
            }
            guard let matched = matching.first(where: { $0.characteristics.contains { $0.type == spec.characteristic } })
                ?? matching.first else {
                throw HomeKitWriteError.objectMissing(
                    "Accessory “\(accessory.name)” has no service “\(wanted)” with characteristic \(spec.characteristic)."
                )
            }
            service = matched
        } else if let matched = accessory.services.first(where: { $0.characteristics.contains { $0.type == spec.characteristic } }) {
            service = matched
        } else {
            throw HomeKitWriteError.objectMissing(
                "Accessory “\(accessory.name)” has no service with characteristic \(spec.characteristic)."
            )
        }
        guard let matched = service.characteristics.first(where: { $0.type == spec.characteristic }) else {
            throw HomeKitWriteError.objectMissing(
                "Service “\(service.name ?? service.serviceType)” has no characteristic \(spec.characteristic)."
            )
        }
        characteristic = matched
        return ResolvedAction(
            accessoryId: accessory.id,
            serviceId: service.id,
            characteristicId: characteristic.id,
            characteristicType: characteristic.type,
            kind: characteristic.kind,
            value: try checkedValue(spec.value, kind: characteristic.kind, characteristic: spec.characteristic)
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
                guard let accessory = accessory(id: accessoryId, in: home) else {
                    throw HomeKitWriteError.objectMissing("No accessory \(accessoryId) in home “\(home.name)”.")
                }
                guard let characteristic = accessory.services.flatMap(\.characteristics)
                    .first(where: { $0.type == characteristicType }) else {
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

    /// Characteristic metadata decides the rendering; a mismatch between the
    /// characteristic's kind and the agent's value is a typed error, not a
    /// runtime HomeKit surprise.
    private static func checkedValue(
        _ value: HomeKitValue, kind: DeviceHomeView.ValueKind, characteristic: String
    ) throws -> HomeKitValue {
        switch (kind, value) {
        case (.string, .string):
            return value
        case (.number, .bool), (.number, .int), (.number, .double):
            return value
        case (.unknown, _):
            return value
        case (.string, let wrong), (.number, let wrong):
            throw HomeKitWriteError.invalidOperation(
                "Characteristic \(characteristic) cannot take the value \(wrong.rendered)."
            )
        }
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

    private static func accessory(id: String, in home: DeviceHomeView.Home) -> DeviceHomeView.Accessory? {
        home.accessories.first { $0.id == id }
    }

    private static func service(id: String, in home: DeviceHomeView.Home) -> DeviceHomeView.Service? {
        home.accessories.flatMap(\.services).first { $0.id == id }
    }
}
