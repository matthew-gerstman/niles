import Foundation
import HomeKit

// The graph model's types are nested under `HomeGraph` by design; short
// aliases keep the mapping functions readable without weakening the model.
// Internal (module-wide) so the trigger-serialization split file shares them.
typealias Home = HomeGraph.Home
typealias Room = HomeGraph.Room
typealias Zone = HomeGraph.Zone
typealias Accessory = HomeGraph.Accessory
typealias Scene = HomeGraph.Scene
typealias SceneAction = HomeGraph.SceneAction
typealias AccessoryService = HomeGraph.AccessoryService
typealias CharacteristicRef = HomeGraph.CharacteristicRef
typealias CharacteristicMetadata = HomeGraph.CharacteristicMetadata
typealias ServiceGroup = HomeGraph.ServiceGroup
typealias ServiceRef = HomeGraph.ServiceRef
typealias Trigger = HomeGraph.Trigger
typealias EventRef = HomeGraph.EventRef

/// `HomeKitService` backed by the real shared home database.
///
/// Owns an `HMHomeManager` and walks its object graph into a `HomeGraph`
/// snapshot on demand. iOS suspends HomeKit apps in the background, so this
/// service runs while Niles is foregrounded — the same constraint the MCP
/// server lives under (spec: foreground-only serving).
public actor HomeManagerHomeKitService: HomeKitService {
    /// Module-internal: the HomeKitWriting executor (its own file) reaches
    /// the live manager directly; nothing outside NilesCore can.
    let manager = HMHomeManager()
    private let loadTimeout: Duration

    public init(loadTimeout: Duration = .seconds(5)) {
        self.loadTimeout = loadTimeout
    }

    public func snapshot() async throws -> HomeGraph {
        try await waitForInitialLoad()
        var graph = HomeGraph(
            homes: manager.homes.map(Self.home(from:)),
            authorizationStatus: Self.authorizationStatusDescription(manager.authorizationStatus)
        )
        // Read depth: every characteristic's current value, read on demand
        // per snapshot (spec group 3 — an agent that cannot see state
        // cannot write safely). A failed read renders as nil, never as an
        // error: an unreachable accessory keeps its shape in the graph;
        // only its value is unknown.
        let rendered = await Self.readCharacteristicValues(in: manager.homes)
        Self.applyingValues(rendered, to: &graph)
        return graph
    }

    /// `HMHomeManager` loads its home database asynchronously with no
    /// completion callback, so give the first load a bounded wait. A timeout
    /// throws instead of returning an empty graph — an agent acting on a
    /// false "no homes" is worse than a retryable error.
    /// Internal: the write executor's `perform` waits the same way.
    func waitForInitialLoad() async throws {
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
            homeHubState: Self.hubStateDescription(home.homeHubState),
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
            name: accessory.name,
            reachable: accessory.isReachable,
            bridged: accessory.isBridged,
            category: accessory.category.categoryType,
            firmwareVersion: accessory.firmwareVersion,
            services: accessory.services.map(Self.accessoryService(from:))
        )
    }

    private static func accessoryService(from service: HMService) -> AccessoryService {
        AccessoryService(
            id: service.uniqueIdentifier.uuidString,
            name: service.name,
            serviceType: service.serviceType,
            characteristics: service.characteristics.map(Self.characteristicRef(from:))
        )
    }

    private static func characteristicRef(from characteristic: HMCharacteristic) -> CharacteristicRef {
        CharacteristicRef(
            id: characteristic.uniqueIdentifier.uuidString,
            type: characteristic.characteristicType,
            name: characteristic.localizedDescription,
            metadata: Self.characteristicMetadata(from: characteristic.metadata)
        )
    }

    private static func scene(from actionSet: HMActionSet) -> Scene {
        Scene(
            id: actionSet.uniqueIdentifier.uuidString,
            name: actionSet.name,
            type: actionSet.actionSetType.isEmpty ? nil : actionSet.actionSetType,
            lastExecutionDate: actionSet.lastExecutionDate,
            actions: actionSet.actions.compactMap(Self.sceneAction(from:))
        )
    }

    /// `HMCharacteristicWriteAction` is generic over its target value, and
    /// Swift cannot cast `HMAction` to an unknown specialization. Read the
    /// two public properties through KVC — the one uniform way to render
    /// every specialization (`<NSNumber>`, `<NSString>`, ...) without
    /// enumerating them. Only characteristic-write actions exist today;
    /// unknown future action types are omitted rather than misrendered.
    /// Internal so the device executor (same module) can reuse the read
    /// side's action identity for matching scene-action removals. The result
    /// type is spelled fully qualified — the file's private alias can't
    /// appear in an internal signature.
    static func sceneAction(from action: HMAction) -> HomeGraph.SceneAction? {
        guard let characteristic = action.value(forKey: "characteristic") as? HMCharacteristic else {
            return nil
        }
        let value = action.value(forKey: "targetValue")
        return HomeGraph.SceneAction(
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

    // MARK: - Read-depth rendering (pure, unit-tested)

    /// `HMHomeHubState` rendered as its JSON-friendly name. Unknown future
    /// cases render as their debug name rather than a lie.
    static func hubStateDescription(_ state: HMHomeHubState) -> String {
        switch state {
        case .notAvailable: return "notAvailable"
        case .connected: return "connected"
        case .disconnected: return "disconnected"
        @unknown default: return String(describing: state)
        }
    }

    /// `HMHomeManager.authorizationStatus` is an options mask, not an enum —
    /// render every set bit; none set means "notDetermined".
    static func authorizationStatusDescription(_ status: HMHomeManagerAuthorizationStatus) -> String {
        var parts: [String] = []
        if status.contains(.determined) { parts.append("determined") }
        if status.contains(.restricted) { parts.append("restricted") }
        if status.contains(.authorized) { parts.append("authorized") }
        return parts.isEmpty ? "notDetermined" : parts.joined(separator: ",")
    }

    /// `HMEventTriggerActivationState` rendered as its JSON-friendly name.
    static func activationStateDescription(_ state: HMEventTriggerActivationState) -> String {
        switch state {
        case .disabled: return "disabled"
        case .disabledNoHomeHub: return "disabledNoHomeHub"
        case .disabledNoCompatibleHomeHub: return "disabledNoCompatibleHomeHub"
        case .disabledNoLocationServicesAuthorization: return "disabledNoLocationServicesAuthorization"
        case .enabled: return "enabled"
        // The imported Obj-C enum's rawValue init is non-failable, so any
        // integer lands here for values the compiler doesn't know — render
        // the number itself, matching the rawValue-based overload.
        @unknown default: return String(state.rawValue)
        }
    }

    /// Activation-state name by raw value (the graph stores the raw Int —
    /// it may gain cases). Unknown raw values render as the number itself.
    static func activationStateDescription(rawValue: Int) -> String {
        guard let state = HMEventTriggerActivationState(rawValue: UInt(rawValue)) else {
            return String(rawValue)
        }
        return activationStateDescription(state)
    }

    /// Pure metadata-mapping core. `HMCharacteristicMetadata`'s properties
    /// are readonly with no populated public initializer, so unit tests
    /// exercise this core with fixture values and the adapter below stays a
    /// one-liner. Returns nil when the metadata carries nothing.
    static func characteristicMetadata(
        format: String?, units: String?, minimum: NSNumber?, maximum: NSNumber?,
        step: NSNumber?, validValues: [NSNumber]?
    ) -> HomeGraph.CharacteristicMetadata? {
        let mapped = HomeGraph.CharacteristicMetadata(
            format: format,
            units: units,
            minValue: minimum?.doubleValue,
            maxValue: maximum?.doubleValue,
            step: step?.doubleValue,
            validValues: validValues?.map { $0.intValue }
        )
        let isEmpty = mapped.format == nil && mapped.units == nil
            && mapped.minValue == nil && mapped.maxValue == nil
            && mapped.step == nil && mapped.validValues == nil
        return isEmpty ? nil : mapped
    }

    static func characteristicMetadata(from metadata: HMCharacteristicMetadata?) -> CharacteristicMetadata? {
        guard let metadata else { return nil }
        return characteristicMetadata(
            format: metadata.format,
            units: metadata.units,
            minimum: metadata.minimumValue,
            maximum: metadata.maximumValue,
            step: metadata.stepValue,
            validValues: metadata.validValues
        )
    }

    /// The one value-rendering rule for reads, shared with scene actions:
    /// `String(describing:)` — NSNumber(30) renders "30", NSNumber(true)
    /// "1", NSString its text. Nil means unknown, never a literal "nil".
    static func valueDescription(from value: Any?) -> String? {
        value.map(String.init(describing:))
    }

    // MARK: - On-demand characteristic reads

    /// `HMCharacteristic` is not `Sendable`; reads are independent of every
    /// other and only their rendered value leaves the group, so the
    /// reference crosses the task boundary inside this box and nowhere else.
    private struct CharacteristicReadTarget: @unchecked Sendable {
        let characteristic: HMCharacteristic
    }

    /// One on-demand characteristic read. Nil on failure (unreachable
    /// accessory, read not permitted) — the value is unknown, not an error.
    private static func readCharacteristicValue(of target: CharacteristicReadTarget) async -> Any? {
        await withCheckedContinuation { continuation in
            target.characteristic.readValue { error in
                continuation.resume(returning: error == nil ? target.characteristic.value : nil)
            }
        }
    }

    /// Reads every characteristic in the live homes concurrently and returns
    /// the successfully-read values, rendered, keyed by characteristic id.
    static func readCharacteristicValues(in homes: [HMHome]) async -> [String: String] {
        let targets = homes
            .flatMap(\.accessories)
            .flatMap(\.services)
            .flatMap(\.characteristics)
            .map(CharacteristicReadTarget.init)
        let read = await withTaskGroup(of: (String, String?).self) { group in
            for target in targets {
                group.addTask {
                    let value = await Self.readCharacteristicValue(of: target)
                    return (
                        target.characteristic.uniqueIdentifier.uuidString,
                        Self.valueDescription(from: value)
                    )
                }
            }
            return await group.reduce(into: [:] as [String: String?]) { $0[$1.0] = $1.1 }
        }
        var rendered: [String: String] = [:]
        for (id, description) in read {
            if let description { rendered[id] = description }
        }
        return rendered
    }

    /// Fills `valueDescription` into every characteristic the read covered.
    /// Pure over the graph — unit-testable without HomeKit.
    static func applyingValues(_ rendered: [String: String], to graph: inout HomeGraph) {
        for h in graph.homes.indices {
            for r in graph.homes[h].rooms.indices {
                for a in graph.homes[h].rooms[r].accessories.indices {
                    for s in graph.homes[h].rooms[r].accessories[a].services.indices {
                        for c in graph.homes[h].rooms[r].accessories[a].services[s].characteristics.indices {
                            let id = graph.homes[h].rooms[r].accessories[a].services[s].characteristics[c].id
                            if let value = rendered[id] {
                                graph.homes[h].rooms[r].accessories[a].services[s].characteristics[c].valueDescription = value
                            }
                        }
                    }
                }
            }
        }
    }
}
