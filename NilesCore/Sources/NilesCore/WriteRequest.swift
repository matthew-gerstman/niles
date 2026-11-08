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
    case createScene(homeId: String, name: String, actions: [SceneActionSpec])
    case setSceneActions(sceneId: String, actions: [SceneActionSpec])
    case createServiceGroup(homeId: String, name: String)
    case setServiceGroupMembers(groupId: String, serviceIds: [String])
    case deleteServiceGroup(groupId: String)

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
        case "create_scene":
            return .createScene(
                homeId: try args.string("homeId"),
                name: try args.string("name"),
                actions: try args.actionArray("actions")
            )
        case "set_scene_actions":
            return .setSceneActions(sceneId: try args.string("sceneId"), actions: try args.actionArray("actions"))
        case "create_service_group":
            return .createServiceGroup(homeId: try args.string("homeId"), name: try args.string("name"))
        case "set_service_group_members":
            return .setServiceGroupMembers(
                groupId: try args.string("groupId"),
                serviceIds: try args.stringArray("serviceIds")
            )
        case "delete_service_group":
            return .deleteServiceGroup(groupId: try args.string("groupId"))
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
