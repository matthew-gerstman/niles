import Foundation
import MCP

/// The typed form of one write-tool call, parsed from MCP arguments.
///
/// Parsing is the tool layer's job (the planner is pure over typed input);
/// failures throw `ProposalStoreError.invalidArguments` with the offending
/// argument or action index named, so agents can fix and retry in-band.
public enum WriteRequest: Sendable, Equatable {
    case createRoom(homeId: String, name: String)
    case renameRoom(roomId: String, name: String)
    case deleteRoom(roomId: String)
    case setZoneRooms(zoneId: String, roomIds: [String])
    case createZone(homeId: String, name: String)
    case renameZone(zoneId: String, name: String)
    case deleteZone(zoneId: String)
    case createScene(homeId: String, name: String, actions: [SceneActionSpec])
    case setSceneActions(sceneId: String, actions: [SceneActionSpec])
    case renameScene(sceneId: String, name: String)
    case deleteScene(sceneId: String, deleteLinkedTriggers: Bool)
    case executeScene(sceneId: String)
    case createServiceGroup(homeId: String, name: String)
    case renameServiceGroup(groupId: String, name: String)
    case setServiceGroupMembers(groupId: String, serviceIds: [String])
    case deleteServiceGroup(groupId: String)
    case createTimerTrigger(
        homeId: String, name: String, fireDate: Date, recurrence: [String: Int]?, sceneId: String?
    )
    case createEventTrigger(homeId: String, name: String, events: [TriggerEventSpec], sceneId: String?)
    case setTriggerState(triggerId: String, enabled: Bool, fireDate: Date?, recurrence: [String: Int]?)
    case deleteTrigger(triggerId: String)
    case renameAccessory(accessoryId: String, name: String)
    case identifyAccessory(accessoryId: String)
    case assignAccessoryToRoom(accessoryId: String, roomId: String)
    case unblockAccessory(accessoryId: String)
    case removeAccessory(accessoryId: String)

    public static func parse(tool: String, arguments: [String: MCP.Value]?) throws -> WriteRequest {
        let args = Args(arguments)
        switch tool {
        case "create_room":
            return .createRoom(homeId: try args.string("homeId"), name: try args.string("name"))
        case "rename_room":
            return .renameRoom(roomId: try args.string("roomId"), name: try args.string("name"))
        case "delete_room":
            return .deleteRoom(roomId: try args.string("roomId"))
        case "set_zone_rooms":
            return .setZoneRooms(zoneId: try args.string("zoneId"), roomIds: try args.stringArray("roomIds"))
        case "create_zone":
            return .createZone(homeId: try args.string("homeId"), name: try args.string("name"))
        case "rename_zone":
            return .renameZone(zoneId: try args.string("zoneId"), name: try args.string("name"))
        case "delete_zone":
            return .deleteZone(zoneId: try args.string("zoneId"))
        case "create_scene":
            return .createScene(
                homeId: try args.string("homeId"),
                name: try args.string("name"),
                actions: try args.actionArray("actions")
            )
        case "set_scene_actions":
            return .setSceneActions(sceneId: try args.string("sceneId"), actions: try args.actionArray("actions"))
        case "rename_scene":
            return .renameScene(sceneId: try args.string("sceneId"), name: try args.string("name"))
        case "delete_scene":
            return .deleteScene(
                sceneId: try args.string("sceneId"),
                deleteLinkedTriggers: try args.optionalBool("deleteLinkedTriggers") ?? false
            )
        case "execute_scene":
            return .executeScene(sceneId: try args.string("sceneId"))
        case "create_service_group":
            return .createServiceGroup(homeId: try args.string("homeId"), name: try args.string("name"))
        case "rename_service_group":
            return .renameServiceGroup(groupId: try args.string("groupId"), name: try args.string("name"))
        case "set_service_group_members":
            return .setServiceGroupMembers(
                groupId: try args.string("groupId"),
                serviceIds: try args.stringArray("serviceIds")
            )
        case "delete_service_group":
            return .deleteServiceGroup(groupId: try args.string("groupId"))
        case "create_timer_trigger":
            return .createTimerTrigger(
                homeId: try args.string("homeId"),
                name: try args.string("name"),
                fireDate: try args.isoDate("fireDate"),
                recurrence: try args.optionalRecurrence("recurrence"),
                sceneId: try args.optionalString("sceneId")
            )
        case "create_event_trigger":
            return .createEventTrigger(
                homeId: try args.string("homeId"),
                name: try args.string("name"),
                events: try args.eventArray("events"),
                sceneId: try args.optionalString("sceneId")
            )
        case "set_trigger_state":
            return .setTriggerState(
                triggerId: try args.string("triggerId"),
                enabled: try args.bool("enabled"),
                fireDate: try args.optionalIsoDate("fireDate"),
                recurrence: try args.optionalRecurrence("recurrence")
            )
        case "delete_trigger":
            return .deleteTrigger(triggerId: try args.string("triggerId"))
        case "rename_accessory":
            return .renameAccessory(accessoryId: try args.string("accessoryId"), name: try args.string("name"))
        case "identify_accessory":
            return .identifyAccessory(accessoryId: try args.string("accessoryId"))
        case "assign_accessory_to_room":
            return .assignAccessoryToRoom(
                accessoryId: try args.string("accessoryId"),
                roomId: try args.string("roomId")
            )
        case "unblock_accessory":
            return .unblockAccessory(accessoryId: try args.string("accessoryId"))
        case "remove_accessory":
            return .removeAccessory(accessoryId: try args.string("accessoryId"))
        default:
            throw ProposalStoreError.unknownTool(tool)
        }
    }
}

/// Argument accessors with precise, agent-readable failure messages.
private struct Args {
    let raw: [String: MCP.Value]?

    init(_ raw: [String: MCP.Value]?) {
        self.raw = raw
    }

    func string(_ name: String) throws -> String {
        guard let value = raw?[name] else {
            throw ProposalStoreError.invalidArguments("Missing required argument “\(name)”.")
        }
        guard let string = value.stringValue else {
            throw ProposalStoreError.invalidArguments("Argument “\(name)” must be a string.")
        }
        return string
    }

    func stringArray(_ name: String) throws -> [String] {
        guard let value = raw?[name] else {
            throw ProposalStoreError.invalidArguments("Missing required argument “\(name)”.")
        }
        guard let array = value.arrayValue else {
            throw ProposalStoreError.invalidArguments("Argument “\(name)” must be an array of strings.")
        }
        return try array.enumerated().map { index, element in
            guard let string = element.stringValue else {
                throw ProposalStoreError.invalidArguments(
                    "Argument “\(name)”: element \(index) must be a string."
                )
            }
            return string
        }
    }

    func optionalString(_ name: String) throws -> String? {
        guard let rawValue = raw?[name] else { return nil }
        guard let string = rawValue.stringValue else {
            throw ProposalStoreError.invalidArguments("Argument “\(name)” must be a string.")
        }
        return string.isEmpty ? nil : string
    }

    /// An optional boolean flag; absent means false.
    func optionalBool(_ name: String) throws -> Bool? {
        guard let value = raw?[name] else { return nil }
        guard case .bool(let bool) = value else {
            throw ProposalStoreError.invalidArguments("Argument “\(name)” must be a boolean.")
        }
        return bool
    }

    func bool(_ name: String) throws -> Bool {
        guard let value = raw?[name] else {
            throw ProposalStoreError.invalidArguments("Missing required argument “\(name)”.")
        }
        guard case .bool(let bool) = value else {
            throw ProposalStoreError.invalidArguments("Argument “\(name)” must be a boolean.")
        }
        return bool
    }

    /// An ISO-8601 timestamp, e.g. `2026-11-09T07:30:00Z`.
    func isoDate(_ name: String) throws -> Date {
        guard let date = try optionalIsoDate(name) else {
            throw ProposalStoreError.invalidArguments("Missing required argument “\(name)”.")
        }
        return date
    }

    func optionalIsoDate(_ name: String) throws -> Date? {
        guard let string = try optionalString(name) else { return nil }
        guard let date = ISOTimestamps.parse(string) else {
            throw ProposalStoreError.invalidArguments(
                "Argument “\(name)” must be ISO-8601, e.g. \(Self.isoExample)."
            )
        }
        return date
    }

    /// An optional DateComponents dictionary, e.g. `{"hour": 7, "minute": 30}` —
    /// the same shape `get_triggers` renders. Component names are HomeKit's
    /// date components; unknown names are rejected so agents fix the request
    /// instead of staging a recurrence that silently never matches.
    func optionalRecurrence(_ name: String) throws -> [String: Int]? {
        guard let value = raw?[name] else { return nil }
        guard let object = value.objectValue else {
            throw ProposalStoreError.invalidArguments(
                "Argument “\(name)” must be an object of date components, e.g. {\"hour\": 7, \"minute\": 30}."
            )
        }
        var components: [String: Int] = [:]
        for (key, rawValue) in object {
            guard Self.recurrenceKeys.contains(key) else {
                throw ProposalStoreError.invalidArguments(
                    "Argument “\(name)”: unknown component “\(key)”. Valid components: \(Self.recurrenceKeys.sorted().joined(separator: ", "))."
                )
            }
            guard case .int(let int) = rawValue else {
                throw ProposalStoreError.invalidArguments(
                    "Argument “\(name)”: component “\(key)” must be a number."
                )
            }
            components[key] = int
        }
        return components
    }

    func eventArray(_ name: String) throws -> [TriggerEventSpec] {
        guard let value = raw?[name] else {
            throw ProposalStoreError.invalidArguments("Missing required argument “\(name)”.")
        }
        guard let array = value.arrayValue else {
            throw ProposalStoreError.invalidArguments(
                "Argument “\(name)” must be an array of {accessoryId, characteristic, value?} or {presence} objects."
            )
        }
        return try array.enumerated().map { index, element in try event(element, at: index, in: name) }
    }

    private func event(_ element: MCP.Value, at index: Int, in name: String) throws -> TriggerEventSpec {
        let prefix = "Event \(index + 1): "
        guard let object = element.objectValue else {
            throw ProposalStoreError.invalidArguments(
                prefix + "must be an object with accessoryId and characteristic, or with presence."
            )
        }
        if let presence = object["presence"]?.stringValue {
            switch presence {
            case "atHome": return .presence(atHome: true)
            case "away": return .presence(atHome: false)
            default:
                throw ProposalStoreError.invalidArguments(
                    prefix + "presence must be “atHome” or “away”."
                )
            }
        }
        guard let accessoryId = object["accessoryId"]?.stringValue else {
            throw ProposalStoreError.invalidArguments(
                prefix + "accessoryId is required (string), or pass presence instead."
            )
        }
        guard let characteristic = object["characteristic"]?.stringValue else {
            throw ProposalStoreError.invalidArguments(prefix + "characteristic is required (string).")
        }
        let value: HomeKitValue?
        if let rawValue = object["value"] {
            switch rawValue {
            case .bool(let bool): value = .bool(bool)
            case .int(let int): value = .int(int)
            case .double(let double): value = .double(double)
            case .string(let string): value = .string(string)
            case .null, .data, .array, .object:
                throw ProposalStoreError.invalidArguments(
                    prefix + "value must be a number, string, or boolean."
                )
            }
        } else {
            value = nil
        }
        return .characteristic(accessoryId: accessoryId, characteristic: characteristic, value: value)
    }

    private static let recurrenceKeys: Set<String> = [
        "year", "month", "weekday", "day", "hour", "minute", "second",
    ]

    private static let isoExample = "2026-11-09T07:30:00Z"

    func actionArray(_ name: String) throws -> [SceneActionSpec] {
        guard let value = raw?[name] else {
            throw ProposalStoreError.invalidArguments("Missing required argument “\(name)”.")
        }
        guard let array = value.arrayValue else {
            throw ProposalStoreError.invalidArguments(
                "Argument “\(name)” must be an array of {accessoryId, service, characteristic, value} objects."
            )
        }
        return try array.enumerated().map { index, element in try action(element, at: index) }
    }

    private func action(_ element: MCP.Value, at index: Int) throws -> SceneActionSpec {
        let prefix = "Action \(index + 1): "
        guard let object = element.objectValue else {
            throw ProposalStoreError.invalidArguments(
                prefix + "must be an object with accessoryId, characteristic, and value."
            )
        }
        guard let accessoryId = object["accessoryId"]?.stringValue else {
            throw ProposalStoreError.invalidArguments(prefix + "accessoryId is required (string).")
        }
        guard let characteristic = object["characteristic"]?.stringValue else {
            throw ProposalStoreError.invalidArguments(prefix + "characteristic is required (string).")
        }
        let service = object["service"]?.stringValue
        guard let rawValue = object["value"] else {
            throw ProposalStoreError.invalidArguments(prefix + "value is required.")
        }
        let value: HomeKitValue
        switch rawValue {
        case .bool(let bool): value = .bool(bool)
        case .int(let int): value = .int(int)
        case .double(let double): value = .double(double)
        case .string(let string): value = .string(string)
        case .null, .data, .array, .object:
            throw ProposalStoreError.invalidArguments(
                prefix + "value must be a number, string, or boolean."
            )
        }
        return SceneActionSpec(
            accessoryId: accessoryId,
            service: service,
            characteristic: characteristic,
            value: value
        )
    }
}
