import Foundation

/// A serializable snapshot of the HomeKit configuration graph.
///
/// This is the value model every read tool projects from: homes, rooms and
/// their accessory assignments, zones and their member rooms, scenes (action
/// sets), service groups, and triggers. Rooms group *accessories* while
/// service groups group *services* — the two membership edges are kept
/// distinct so agents cannot conflate them (a "Desk Lamps" group contains the
/// light service of several accessories, not the accessories themselves).
public struct HomeGraph: Codable, Sendable, Equatable {
    public var homes: [Home]

    public init(homes: [Home] = []) {
        self.homes = homes
    }

    public struct Home: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var rooms: [Room]
        public var zones: [Zone]
        public var scenes: [Scene]
        public var serviceGroups: [ServiceGroup]
        public var triggers: [Trigger]

        public init(
            id: String,
            name: String,
            rooms: [Room] = [],
            zones: [Zone] = [],
            scenes: [Scene] = [],
            serviceGroups: [ServiceGroup] = [],
            triggers: [Trigger] = []
        ) {
            self.id = id
            self.name = name
            self.rooms = rooms
            self.zones = zones
            self.scenes = scenes
            self.serviceGroups = serviceGroups
            self.triggers = triggers
        }
    }

    public struct Accessory: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        /// The services this accessory exposes, each with the characteristics
        /// it supports — the capability surface agents consult before
        /// staging writes (e.g. is Brightness supported at all?).
        public var services: [AccessoryService]

        public init(id: String, name: String, services: [AccessoryService] = []) {
            self.id = id
            self.name = name
            self.services = services
        }
    }

    /// One service of an accessory (lightbulb, switch, ...). Distinct from
    /// `ServiceRef`, which names a service as a service-group member.
    public struct AccessoryService: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        /// HomeKit service type UUID (e.g. 0x0043, lightbulb); nil when unset.
        public var serviceType: String?
        public var characteristics: [CharacteristicRef]

        public init(
            id: String,
            name: String,
            serviceType: String? = nil,
            characteristics: [CharacteristicRef] = []
        ) {
            self.id = id
            self.name = name
            self.serviceType = serviceType
            self.characteristics = characteristics
        }
    }

    /// A characteristic a service supports. `type` is the HomeKit
    /// characteristic type string — the stable identity to match staged
    /// writes against; `name` is the human-readable form when known.
    public struct CharacteristicRef: Codable, Sendable, Equatable {
        public var id: String
        public var type: String
        public var name: String?

        public init(id: String, type: String, name: String? = nil) {
            self.id = id
            self.type = type
            self.name = name
        }
    }

    public struct Room: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        /// The accessories assigned to this room. Rooms own accessories.
        public var accessories: [Accessory]

        public init(id: String, name: String, accessories: [Accessory] = []) {
            self.id = id
            self.name = name
            self.accessories = accessories
        }
    }

    public struct Zone: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        /// Member rooms, by id. Zones group rooms.
        public var roomIds: [String]

        public init(id: String, name: String, roomIds: [String] = []) {
            self.id = id
            self.name = name
            self.roomIds = roomIds
        }
    }

    public struct Scene: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        /// HomeKit's action-set type (e.g. "AppleScene"); nil when unset.
        public var type: String?
        public var actions: [SceneAction]

        public init(id: String, name: String, type: String? = nil, actions: [SceneAction] = []) {
            self.id = id
            self.name = name
            self.type = type
            self.actions = actions
        }
    }

    public struct SceneAction: Codable, Sendable, Equatable {
        public var accessoryId: String?
        public var accessoryName: String?
        public var service: String?
        public var characteristic: String
        public var characteristicName: String?
        /// The target value rendered as a string; HomeKit values are untyped.
        public var valueDescription: String

        public init(
            accessoryId: String?,
            accessoryName: String?,
            service: String?,
            characteristic: String,
            characteristicName: String?,
            valueDescription: String
        ) {
            self.accessoryId = accessoryId
            self.accessoryName = accessoryName
            self.service = service
            self.characteristic = characteristic
            self.characteristicName = characteristicName
            self.valueDescription = valueDescription
        }
    }

    public struct ServiceGroup: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        /// Member services — not accessories. A service carries the accessory
        /// it belongs to, so one group can span several accessories.
        public var services: [ServiceRef]

        public init(id: String, name: String, services: [ServiceRef] = []) {
            self.id = id
            self.name = name
            self.services = services
        }
    }

    public struct ServiceRef: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var serviceType: String?
        public var accessoryId: String?
        public var accessoryName: String?

        public init(
            id: String,
            name: String,
            serviceType: String?,
            accessoryId: String?,
            accessoryName: String?
        ) {
            self.id = id
            self.name = name
            self.serviceType = serviceType
            self.accessoryId = accessoryId
            self.accessoryName = accessoryName
        }
    }

    public struct Trigger: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var isEnabled: Bool
        /// The scenes (action sets) registered on this trigger — what it runs
        /// when it fires. HomeKit refuses to enable a trigger with none
        /// (it has nothing to run), so arming proposals check this.
        public var linkedSceneIds: [String]
        public var detail: Detail

        public init(id: String, name: String, isEnabled: Bool, linkedSceneIds: [String] = [], detail: Detail) {
            self.id = id
            self.name = name
            self.isEnabled = isEnabled
            self.linkedSceneIds = linkedSceneIds
            self.detail = detail
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, isEnabled, linkedSceneIds, detail
        }

        /// Graphs captured before `linkedSceneIds` existed must still decode.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
            linkedSceneIds = try container.decodeIfPresent([String].self, forKey: .linkedSceneIds) ?? []
            detail = try container.decode(Detail.self, forKey: .detail)
        }

        /// Timer and event triggers are a discriminated union: a trigger is
        /// one kind, never both. Encodes as `{"timer": {...}}` or
        /// `{"event": {...}}`. Trigger kinds HomeKit may add later surface
        /// as `.unknown` rather than being misrendered as a kind they are not.
        public enum Detail: Codable, Sendable, Equatable {
            case timer(fireDate: Date, recurrence: [String: Int])
            case event(events: [EventRef], predicate: String?)
            case unknown(kind: String)
        }
    }

    public struct EventRef: Codable, Sendable, Equatable {
        /// Which `HMEvent` kind fired this ("characteristic", ...).
        public var type: String
        public var characteristicType: String?
        public var valueDescription: String?

        public init(type: String, characteristicType: String?, valueDescription: String?) {
            self.type = type
            self.characteristicType = characteristicType
            self.valueDescription = valueDescription
        }
    }
}
