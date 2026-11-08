import Foundation
import HomeKit

// The graph model's types are nested under `HomeGraph` by design; short
// aliases keep the mapping functions readable without weakening the model.
private typealias Home = HomeGraph.Home
private typealias Room = HomeGraph.Room
private typealias Zone = HomeGraph.Zone
private typealias Accessory = HomeGraph.Accessory
private typealias Scene = HomeGraph.Scene
private typealias SceneAction = HomeGraph.SceneAction
private typealias ServiceGroup = HomeGraph.ServiceGroup
private typealias ServiceRef = HomeGraph.ServiceRef
private typealias Trigger = HomeGraph.Trigger
private typealias EventRef = HomeGraph.EventRef

/// `HomeKitService` backed by the real shared home database.
///
/// Owns an `HMHomeManager` and walks its object graph into a `HomeGraph`
/// snapshot on demand. iOS suspends HomeKit apps in the background, so this
/// service runs while Niles is foregrounded — the same constraint the MCP
/// server lives under (spec: foreground-only serving).
public actor HomeManagerHomeKitService: HomeKitService {
    private let manager = HMHomeManager()
    private let loadTimeout: Duration

    public init(loadTimeout: Duration = .seconds(5)) {
        self.loadTimeout = loadTimeout
    }

    public func snapshot() async throws -> HomeGraph {
        try await waitForInitialLoad()
        return HomeGraph(homes: manager.homes.map(Self.home(from:)))
    }

    /// `HMHomeManager` loads its home database asynchronously with no
    /// completion callback, so give the first load a bounded wait. A timeout
    /// throws instead of returning an empty graph — an agent acting on a
    /// false "no homes" is worse than a retryable error.
    private func waitForInitialLoad() async throws {
        if !manager.homes.isEmpty { return }
        let deadline = ContinuousClock.now + loadTimeout
        while manager.homes.isEmpty {
            guard ContinuousClock.now < deadline else {
                throw HomeKitServiceError.homeLoadTimedOut
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - HomeKit object graph -> HomeGraph

    private static func home(from home: HMHome) -> Home {
        // A room belongs to at most one zone; build the room -> zone index
        // once per home so room serialization carries zone membership.
        let zoneByRoom = Dictionary(
            home.zones.flatMap { zone in zone.rooms.map { ($0.uniqueIdentifier, zone) } },
            uniquingKeysWith: { first, _ in first }
        )
        return Home(
            id: home.uniqueIdentifier.uuidString,
            name: home.name,
            rooms: home.rooms.map { Self.room(from: $0, zoneByRoom: zoneByRoom) },
            zones: home.zones.map(Self.zone(from:)),
            scenes: home.actionSets.map(Self.scene(from:)),
            serviceGroups: home.serviceGroups.map(Self.serviceGroup(from:)),
            triggers: home.triggers.map(Self.trigger(from:))
        )
    }

    private static func room(from room: HMRoom, zoneByRoom: [UUID: HMZone]) -> Room {
        Room(
            id: room.uniqueIdentifier.uuidString,
            name: room.name,
            accessories: room.accessories.map(Self.accessory(from:))
        )
    }

    private static func zone(from zone: HMZone) -> Zone {
        Zone(
            id: zone.uniqueIdentifier.uuidString,
            name: zone.name,
            roomIds: zone.rooms.map { $0.uniqueIdentifier.uuidString }
        )
    }

    private static func accessory(from accessory: HMAccessory) -> Accessory {
        Accessory(
            id: accessory.uniqueIdentifier.uuidString,
            name: accessory.name
        )
    }

    private static func scene(from actionSet: HMActionSet) -> Scene {
        Scene(
            id: actionSet.uniqueIdentifier.uuidString,
            name: actionSet.name,
            type: actionSet.actionSetType.isEmpty ? nil : actionSet.actionSetType,
            actions: actionSet.actions.compactMap(Self.sceneAction(from:))
        )
    }

    /// `HMCharacteristicWriteAction` is generic over its target value, and
    /// Swift cannot cast `HMAction` to an unknown specialization. Read the
    /// two public properties through KVC — the one uniform way to render
    /// every specialization (`<NSNumber>`, `<NSString>`, ...) without
    /// enumerating them. Only characteristic-write actions exist today;
    /// unknown future action types are omitted rather than misrendered.
    private static func sceneAction(from action: HMAction) -> SceneAction? {
        guard let characteristic = action.value(forKey: "characteristic") as? HMCharacteristic else {
            return nil
        }
        let value = action.value(forKey: "targetValue")
        return SceneAction(
            accessoryId: characteristic.service?.accessory?.uniqueIdentifier.uuidString,
            accessoryName: characteristic.service?.accessory?.name,
            service: characteristic.service?.name,
            characteristic: characteristic.characteristicType,
            characteristicName: characteristic.localizedDescription,
            valueDescription: value.map(String.init(describing:)) ?? "nil"
        )
    }

    private static func serviceGroup(from group: HMServiceGroup) -> ServiceGroup {
        ServiceGroup(
            id: group.uniqueIdentifier.uuidString,
            name: group.name,
            services: group.services.map { service in
                ServiceRef(
                    id: service.uniqueIdentifier.uuidString,
                    name: service.name,
                    serviceType: service.serviceType,
                    accessoryId: service.accessory?.uniqueIdentifier.uuidString,
                    accessoryName: service.accessory?.name
                )
            }
        )
    }

    private static func trigger(from trigger: HMTrigger) -> Trigger {
        Trigger(
            id: trigger.uniqueIdentifier.uuidString,
            name: trigger.name,
            isEnabled: trigger.isEnabled,
            detail: Self.detail(from: trigger)
        )
    }

    private static func detail(from trigger: HMTrigger) -> Trigger.Detail {
        if let timer = trigger as? HMTimerTrigger {
            return .timer(
                fireDate: timer.fireDate,
                recurrence: Self.recurrenceValues(from: timer.recurrence)
            )
        }
        if let eventTrigger = trigger as? HMEventTrigger {
            return .event(
                events: eventTrigger.events.map(Self.eventRef(from:)),
                predicate: eventTrigger.predicate?.description
            )
        }
        return .unknown(kind: String(describing: type(of: trigger)))
    }

    /// Non-zero date components as a JSON-friendly dictionary, e.g.
    /// `{"hour": 7, "minute": 30}`. Nil and zero components are dropped.
    static func recurrenceValues(from components: DateComponents?) -> [String: Int] {
        guard let components else { return [:] }
        var values: [String: Int] = [:]
        let namedComponents: [(String, Int?)] = [
            ("year", components.year),
            ("month", components.month),
            ("weekday", components.weekday),
            ("day", components.day),
            ("hour", components.hour),
            ("minute", components.minute),
            ("second", components.second),
        ]
        for (name, value) in namedComponents where value.map({ $0 != 0 }) == true {
            values[name] = value
        }
        return values
    }

    private static func eventRef(from event: HMEvent) -> EventRef {
        // `HMCharacteristicEvent` is generic over its target value type and
        // has no public non-generic base, so match the concrete
        // specializations HomeKit actually produces.
        if let numberEvent = event as? HMCharacteristicEvent<NSNumber> {
            return eventRef(characteristic: numberEvent.characteristic, value: numberEvent.triggerValue)
        }
        if let stringEvent = event as? HMCharacteristicEvent<NSString> {
            return eventRef(characteristic: stringEvent.characteristic, value: stringEvent.triggerValue)
        }
        if let nullEvent = event as? HMCharacteristicEvent<NSNull> {
            return eventRef(characteristic: nullEvent.characteristic, value: nullEvent.triggerValue)
        }
        return EventRef(
            type: String(describing: type(of: event)),
            characteristicType: nil,
            valueDescription: nil
        )
    }

    private static func eventRef(characteristic: HMCharacteristic, value: Any?) -> EventRef {
        EventRef(
            type: "characteristic",
            characteristicType: characteristic.characteristicType,
            valueDescription: value.map(String.init(describing:))
        )
    }
}
