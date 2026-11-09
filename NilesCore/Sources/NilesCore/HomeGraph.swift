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
    /// The app's HomeKit authorization, rendered from
    /// `HMHomeManager.authorizationStatus` — manager-level, not per-home
    /// (there is one grant for the whole app, not one per home).
    public var authorizationStatus: String?

    public init(homes: [Home] = [], authorizationStatus: String? = nil) {
        self.homes = homes
        self.authorizationStatus = authorizationStatus
    }

    public struct Home: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        /// Home hub availability for this home, rendered from
        /// `HMHome.homeHubState` ("notAvailable" / "connected" /
        /// "disconnected") — what makes remote control and trigger
        /// evaluation possible.
        public var homeHubState: String?
        public var rooms: [Room]
        public var zones: [Zone]
        public var scenes: [Scene]
        public var serviceGroups: [ServiceGroup]
        public var triggers: [Trigger]

        public init(
            id: String,
            name: String,
            homeHubState: String? = nil,
            rooms: [Room] = [],
            zones: [Zone] = [],
            scenes: [Scene] = [],
            serviceGroups: [ServiceGroup] = [],
            triggers: [Trigger] = []
        ) {
            self.id = id
            self.name = name
            self.homeHubState = homeHubState
            self.rooms = rooms
            self.zones = zones
            self.scenes = scenes
            self.serviceGroups = serviceGroups
            self.triggers = triggers
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, homeHubState, rooms, zones, scenes, serviceGroups, triggers
        }

        /// Graphs captured before read depth must still decode; the new
        /// fields default to their "no information" values.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            homeHubState = try container.decodeIfPresent(String.self, forKey: .homeHubState)
            rooms = try container.decodeIfPresent([Room].self, forKey: .rooms) ?? []
            zones = try container.decodeIfPresent([Zone].self, forKey: .zones) ?? []
            scenes = try container.decodeIfPresent([Scene].self, forKey: .scenes) ?? []
            serviceGroups =
                try container.decodeIfPresent([ServiceGroup].self, forKey: .serviceGroups) ?? []
            triggers = try container.decodeIfPresent([Trigger].self, forKey: .triggers) ?? []
        }
    }

    public struct Accessory: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        /// True while the accessory responds on the network. A write can be
        /// staged for an unreachable accessory but will not take effect.
        public var reachable: Bool
        /// True when the accessory is reached through a bridge rather than
        /// directly (a bridge itself is `bridged == false`).
        public var bridged: Bool
        /// HomeKit category type (e.g. "com.apple.hap.lightbulb"); the
        /// stable identity, not the localized description.
        public var category: String?
        public var firmwareVersion: String?
        /// `HMAccessory.supportsIdentify` — whether the accessory can flash
        /// or beep when identified. Nil when unknown (graphs captured before
        /// the field existed decode as nil and staging stays permissive).
        public var supportsIdentify: Bool?
        /// The services this accessory exposes, each with the characteristics
        /// it supports — the capability surface agents consult before
        /// staging writes (e.g. is Brightness supported at all?).
        public var services: [AccessoryService]

        public init(
            id: String,
            name: String,
            supportsIdentify: Bool? = nil,
            reachable: Bool = true,
            bridged: Bool = false,
            category: String? = nil,
            firmwareVersion: String? = nil,
            services: [AccessoryService] = []
        ) {
            self.id = id
            self.name = name
            self.supportsIdentify = supportsIdentify
            self.reachable = reachable
            self.bridged = bridged
            self.category = category
            self.firmwareVersion = firmwareVersion
            self.services = services
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, reachable, bridged, category, firmwareVersion, supportsIdentify, services
        }

        /// Graphs captured before the read-depth fields existed must still
        /// decode; the flags default to their "no information" values.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            reachable = try container.decodeIfPresent(Bool.self, forKey: .reachable) ?? true
            bridged = try container.decodeIfPresent(Bool.self, forKey: .bridged) ?? false
            category = try container.decodeIfPresent(String.self, forKey: .category)
            firmwareVersion = try container.decodeIfPresent(String.self, forKey: .firmwareVersion)
            supportsIdentify = try container.decodeIfPresent(Bool.self, forKey: .supportsIdentify)
            services = try container.decode([AccessoryService].self, forKey: .services)
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
        /// Current value, rendered with the one read-side rule (shared with
        /// scene actions: `String(describing:)`). Nil means unknown — the
        /// on-demand read has not been taken or failed — never a literal
        /// "nil" value.
        public var valueDescription: String?
        /// Declared range and units. Nil when the accessory exposes no
        /// metadata.
        public var metadata: CharacteristicMetadata?

        public init(
            id: String,
            type: String,
            name: String? = nil,
            valueDescription: String? = nil,
            metadata: CharacteristicMetadata? = nil
        ) {
            self.id = id
            self.type = type
            self.name = name
            self.valueDescription = valueDescription
            self.metadata = metadata
        }
    }

    /// The declared range and units of a characteristic, from
    /// `HMCharacteristicMetadata` — what an agent consults before staging a
    /// value ("can Brightness take 30?"). `validValues` enumerates the legal
    /// discrete values when the format has them.
    public struct CharacteristicMetadata: Codable, Sendable, Equatable {
        /// HomeKit metadata format ("bool", "int", "float", "string", ...).
        public var format: String?
        /// HomeKit catalog units ("percentage", "celsius", ...).
        public var units: String?
        public var minValue: Double?
        public var maxValue: Double?
        public var step: Double?
        public var validValues: [Int]?

        public init(
            format: String? = nil,
            units: String? = nil,
            minValue: Double? = nil,
            maxValue: Double? = nil,
            step: Double? = nil,
            validValues: [Int]? = nil
        ) {
            self.format = format
            self.units = units
            self.minValue = minValue
            self.maxValue = maxValue
            self.step = step
            self.validValues = validValues
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
        /// When the scene last ran (HomeKit-stamped); nil when never run.
        public var lastExecutionDate: Date?
        public var actions: [SceneAction]

        public init(
            id: String,
            name: String,
            type: String? = nil,
            lastExecutionDate: Date? = nil,
            actions: [SceneAction] = []
        ) {
            self.id = id
            self.name = name
            self.type = type
            self.lastExecutionDate = lastExecutionDate
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
        /// (it has nothing to run), so arming proposals check this. The
        /// delete-scene card also names these triggers; HomeKit itself
        /// detaches a removed action set, but the agent and the human should
        /// see the link before approving.
        public var linkedSceneIds: [String] = []
        /// `HMEventTrigger.triggerActivationState` raw value — why an event
        /// trigger is or is not active (0 disabled, 1 disabledNoHomeHub,
        /// 2 disabledNoCompatibleHomeHub, 3 disabledNoLocationServices
        /// Authorization, 4 enabled). Nil for timer triggers, which have no
        /// activation state.
        public var triggerActivationState: Int?
        public var detail: Detail

        public init(
            id: String, name: String, isEnabled: Bool, linkedSceneIds: [String] = [],
            triggerActivationState: Int? = nil, detail: Detail
        ) {
            self.id = id
            self.name = name
            self.isEnabled = isEnabled
            self.linkedSceneIds = linkedSceneIds
            self.triggerActivationState = triggerActivationState
            self.detail = detail
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, isEnabled, linkedSceneIds, triggerActivationState, detail
        }

        /// Graphs captured before `linkedSceneIds` and
        /// `triggerActivationState` existed must still decode.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
            linkedSceneIds = try container.decodeIfPresent([String].self, forKey: .linkedSceneIds) ?? []
            triggerActivationState = try container.decodeIfPresent(Int.self, forKey: .triggerActivationState)
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
        /// The accessory the watched characteristic belongs to — how a
        /// destructive staging card attributes trigger events to an
        /// accessory. Nil on graphs captured before the field existed.
        public var accessoryId: String?

        public init(
            type: String,
            characteristicType: String?,
            valueDescription: String?,
            accessoryId: String? = nil
        ) {
            self.type = type
            self.characteristicType = characteristicType
            self.valueDescription = valueDescription
            self.accessoryId = accessoryId
        }
    }
}
