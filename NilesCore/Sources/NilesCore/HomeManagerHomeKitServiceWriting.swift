import Foundation
import HomeKit

// MARK: - HomeKitWriting (device executor)

/// The write half of the real service: approved `HomeKitOperation`s applied
/// to the shared home database.
///
/// Two layers, per the write-execution spec:
/// - **Resolver** (`DeviceWriteResolver`) — pure, CI-tested. Translates each
///   operation into ordered `DeviceWriteStep`s against a `DeviceHomeView`
///   snapshot, throwing typed `HomeKitWriteError`s for drift, duplicate
///   names, and constraint violations.
/// - **Executor** (this extension) — thin and actor-confined. Re-resolves
///   every id against the live manager immediately before each call (another
///   Home app may mutate the database concurrently), and wraps each
///   completion-style API in a continuation that carries no logic.
///
/// `HMHome` and friends are not `Sendable`, so nothing here crosses an actor
/// boundary: resolution and every call stay inside this actor.
extension HomeManagerHomeKitService: HomeKitWriting {
    public func perform(_ operation: HomeKitOperation) async throws -> String? {
        try await waitForInitialLoad()
        let view = Self.homeView(from: manager.homes)
        let steps = try DeviceWriteResolver.resolve(operation, in: view)
        var createdId: String?
        for step in steps {
            let id = try await run(step, in: manager.homes)
            if let id { createdId = id }
        }
        return createdId
    }

    // MARK: Step execution

    /// Runs one resolved step, re-resolving ids against the live graph. The
    /// last step that created an object decides `perform`'s return id.
    private func run(_ step: DeviceWriteStep, in homes: [HMHome]) async throws -> String? {
        switch step {
        case .addRoom(let homeId, let name):
            let home = try Self.home(homeId, in: homes)
            return try await home.addRoom(named: name).uniqueIdentifier.uuidString

        case .renameRoom(let homeId, let roomId, let to):
            let room = try Self.room(roomId, in: Self.home(homeId, in: homes))
            try await Self.updateName(room, to: to)
            return nil

        case .removeRoom(let homeId, let roomId):
            let home = try Self.home(homeId, in: homes)
            try await home.removeRoom(try Self.room(roomId, in: home))
            return nil

        case .updateZoneRooms(let homeId, let zoneId, let addRoomIds, let removeRoomIds):
            let home = try Self.home(homeId, in: homes)
            let zone = try Self.zone(zoneId, in: home)
            for roomId in removeRoomIds {
                // The resolver rejects a non-member at staging and again at
                // execution; drift must fail loudly here too — never a
                // silent skip that read-back could false-confirm.
                guard let room = zone.rooms.first(where: { $0.uniqueIdentifier.uuidString == roomId }) else {
                    throw HomeKitWriteError.objectMissing("Zone “\(zone.name)” does not contain room \(roomId).")
                }
                try await Self.remove(room, from: zone)
            }
            for roomId in addRoomIds {
                guard !zone.rooms.contains(where: { $0.uniqueIdentifier.uuidString == roomId }) else { continue }
                try await Self.add(try Self.room(roomId, in: home), to: zone)
            }
            return nil

        case .createZone(let homeId, let name):
            let home = try Self.home(homeId, in: homes)
            return try await home.addZone(named: name).uniqueIdentifier.uuidString

        case .renameZone(let homeId, let zoneId, let to):
            let home = try Self.home(homeId, in: homes)
            try await Self.updateName(try Self.zone(zoneId, in: home), to: to)
            return nil

        case .removeZone(let homeId, let zoneId):
            let home = try Self.home(homeId, in: homes)
            try await home.removeZone(try Self.zone(zoneId, in: home))
            return nil

        case .createActionSet(let homeId, let name, let actions):
            let home = try Self.home(homeId, in: homes)
            let scene = try await home.addActionSet(named: name)
            for resolved in actions {
                try await Self.add(Self.writeAction(for: resolved, in: home), to: scene)
            }
            return scene.uniqueIdentifier.uuidString

        case .updateSceneActions(let homeId, let sceneId, let add, let remove):
            let home = try Self.home(homeId, in: homes)
            let scene = try Self.actionSet(sceneId, in: home)
            for key in remove {
                // Match existing actions by the read side's identity, then
                // remove every match (unmatched keys are no-ops, like the
                // fake's diff application).
                let existing = scene.actions
                for action in existing where Self.key(of: action) == key {
                    try await Self.remove(action, from: scene)
                }
            }
            for resolved in add {
                try await Self.add(Self.writeAction(for: resolved, in: home), to: scene)
            }
            return nil

        case .renameActionSet(let homeId, let sceneId, let to):
            let home = try Self.home(homeId, in: homes)
            try await Self.updateName(try Self.actionSet(sceneId, in: home), to: to)
            return nil

        case .removeActionSet(let homeId, let sceneId):
            let home = try Self.home(homeId, in: homes)
            try await home.removeActionSet(try Self.actionSet(sceneId, in: home))
            return nil

        case .executeActionSet(let homeId, let sceneId):
            let home = try Self.home(homeId, in: homes)
            try await Self.execute(try Self.actionSet(sceneId, in: home), in: home)
            return nil

        case .addServiceGroup(let homeId, let name, let serviceIds):
            let home = try Self.home(homeId, in: homes)
            let group = try await home.addServiceGroup(named: name)
            for serviceId in serviceIds {
                // Named refusal: a bare HMError on this call gave the first
                // blind-grouping batch an unactionable code; evidence must
                // say which service and which group.
                try await Self.add(try Self.service(serviceId, in: home), to: group, groupName: name)
            }
            return try await group.uniqueIdentifier.uuidString

        case .updateServiceGroupMembers(let homeId, let groupId, let addServiceIds, let removeServiceIds):
            let home = try Self.home(homeId, in: homes)
            let group = try Self.serviceGroup(groupId, in: home)
            for serviceId in removeServiceIds {
                guard let service = group.services.first(where: { $0.uniqueIdentifier.uuidString == serviceId }) else { continue }
                try await Self.remove(service, from: group)
            }
            for serviceId in addServiceIds {
                guard !group.services.contains(where: { $0.uniqueIdentifier.uuidString == serviceId }) else { continue }
                try await Self.add(try Self.service(serviceId, in: home), to: group, groupName: group.name)
            }
            return nil

        case .renameServiceGroup(let homeId, let groupId, let to):
            let home = try Self.home(homeId, in: homes)
            try await Self.updateName(try Self.serviceGroup(groupId, in: home), to: to)
            return nil

        case .removeServiceGroup(let homeId, let groupId):
            let home = try Self.home(homeId, in: homes)
            try await home.removeServiceGroup(try Self.serviceGroup(groupId, in: home))
            return nil

        case .createTimerTrigger(let homeId, let name, let fireDate, let recurrence, let sceneId):
            let home = try Self.home(homeId, in: homes)
            let trigger = HMTimerTrigger(name: name, fireDate: fireDate, recurrence: recurrence)
            try await Self.add(trigger, to: home)
            try await Self.linkScene(sceneId, to: trigger, in: home)
            // The create/arm firewall: creation never arms.
            try await Self.enforceBornDisabled(trigger)
            return trigger.uniqueIdentifier.uuidString

        case .createEventTrigger(let homeId, let name, let events, let endEvents, let executeOnce, let sceneId):
            let home = try Self.home(homeId, in: homes)
            // The creation initializer takes end events and recurrences;
            // executeOnce is a post-add update (HomeKit disables the trigger
            // after its first fire when set).
            let (hmEvents, predicate) = try Self.events(events, in: home)
            let (hmEndEvents, _) = try Self.events(endEvents, in: home)
            let trigger = HMEventTrigger(
                name: name, events: hmEvents, end: hmEndEvents.isEmpty ? nil : hmEndEvents,
                recurrences: nil, predicate: predicate
            )
            try await Self.add(trigger, to: home)
            if executeOnce {
                try await Self.updateExecuteOnce(trigger, to: true)
            }
            try await Self.linkScene(sceneId, to: trigger, in: home)
            try await Self.enforceBornDisabled(trigger)
            return trigger.uniqueIdentifier.uuidString
        case .updateEventTrigger(
            let homeId, let triggerId, let events, let endEvents, let recurrences, let executeOnce, let sceneId
        ):
            let home = try Self.home(homeId, in: homes)
            let trigger = try Self.trigger(triggerId, in: home)
            guard let eventTrigger = trigger as? HMEventTrigger else {
                throw HomeKitWriteError.invalidOperation(
                    "Trigger \(trigger.name) is not an event trigger; it has no events to edit."
                )
            }
            // The event list is declarative: replace everything, and
            // re-derive the predicate the same way creation does (presence
            // events imply the presence predicate; characteristic events run
            // unpredicated).
            let (hmEvents, predicate) = try Self.events(events, in: home)
            try await Self.updateEvents(eventTrigger, to: hmEvents)
            try await Self.updatePredicate(eventTrigger, to: predicate)
            if let endEvents {
                let (hmEndEvents, _) = try Self.events(endEvents, in: home)
                try await Self.updateEndEvents(eventTrigger, to: hmEndEvents)
            }
            if let recurrences {
                try await Self.updateRecurrences(eventTrigger, to: recurrences)
            }
            if let executeOnce {
                try await Self.updateExecuteOnce(eventTrigger, to: executeOnce)
            }
            if let sceneId {
                // Relinking is explicit: replace the registered action sets
                // with the named scene. An omitted sceneId leaves the links
                // untouched.
                for actionSet in eventTrigger.actionSets {
                    try await Self.remove(actionSet, from: eventTrigger)
                }
                try await Self.linkScene(sceneId, to: eventTrigger, in: home)
            }
            // The create/arm firewall: nothing above touches isEnabled — an
            // edited trigger keeps its current armed state.
            return nil

        case .setTriggerEnabled(let homeId, let triggerId, let enabled):
            let home = try Self.home(homeId, in: homes)
            try await Self.setEnabled(try Self.trigger(triggerId, in: home), to: enabled)
            return nil

        case .replaceTimerTrigger(let homeId, let triggerId, let fireDate, let recurrence, let wasEnabled, _):
            let home = try Self.home(homeId, in: homes)
            // Preserve the linked scenes the old trigger ran — a schedule
            // change must not silently unlink them.
            let old = try Self.trigger(triggerId, in: home)
            guard let oldTimer = old as? HMTimerTrigger else {
                throw HomeKitWriteError.invalidOperation(
                    "Trigger “\(old.name)” is not a timer trigger; it has no fire date."
                )
            }
            let linkedSets = oldTimer.actionSets
            let newTrigger = HMTimerTrigger(name: old.name, fireDate: fireDate, recurrence: recurrence)
            // Remove first: adding a same-named trigger before the old one
            // is gone could collide. A failure here leaves the old schedule
            // intact only if it happened before the remove; after it, the
            // proposal records .failed with partial evidence (forward-only).
            try await home.removeTrigger(oldTimer)
            try await Self.add(newTrigger, to: home)
            for actionSet in linkedSets {
                try await Self.add(actionSet, to: newTrigger)
            }
            // Restoring a state the human already approved is the one place
            // a device write arms a trigger; it is not arming on create.
            try await Self.setEnabled(newTrigger, to: wasEnabled)
            return newTrigger.uniqueIdentifier.uuidString

        case .removeTrigger(let homeId, let triggerId):
            let home = try Self.home(homeId, in: homes)
            try await home.removeTrigger(try Self.trigger(triggerId, in: home))
            return nil

        case .renameAccessory(let homeId, let accessoryId, let to):
            let home = try Self.home(homeId, in: homes)
            try await Self.updateName(try Self.accessory(accessoryId, in: home), to: to)
            return nil

        case .identifyAccessory(let homeId, let accessoryId):
            let home = try Self.home(homeId, in: homes)
            try await Self.identify(try Self.accessory(accessoryId, in: home))
            return nil

        case .assignAccessoryToRoom(let homeId, let accessoryId, let roomId):
            let home = try Self.home(homeId, in: homes)
            try await Self.assign(
                try Self.accessory(accessoryId, in: home),
                to: try Self.room(roomId, in: home),
                in: home
            )
            return nil

        case .unblockAccessory(let homeId, let accessoryId):
            let home = try Self.home(homeId, in: homes)
            try await Self.unblock(try Self.accessory(accessoryId, in: home), in: home)
            return nil

        case .removeAccessory(let homeId, let accessoryId):
            let home = try Self.home(homeId, in: homes)
            try await Self.remove(try Self.accessory(accessoryId, in: home), from: home)
            return nil

        case .writeCharacteristic(let homeId, let resolved):
            let home = try Self.home(homeId, in: homes)
            let characteristic = try Self.characteristic(resolved.characteristicId, in: home)
            try await Self.write(
                resolved.value, kind: resolved.kind, to: characteristic, named: resolved.characteristicType
            )
            return nil
        }
    }

    /// A newly added trigger must end up disabled. Whether HomeKit adds
    /// triggers enabled is not contractual, so read the live state and turn
    /// it off rather than assuming.
    private static func enforceBornDisabled(_ trigger: HMTrigger) async throws {
        guard trigger.isEnabled else { return }
        try await setEnabled(trigger, to: false)
    }

    private static func linkScene(_ sceneId: String?, to trigger: HMTrigger, in home: HMHome) async throws {
        guard let sceneId else { return }
        let scene = try actionSet(sceneId, in: home)
        try await add(scene, to: trigger)
    }

    // MARK: Value and event construction

    /// The action to add, specialized by the characteristic's metadata the
    /// way the read side enumerates specializations back out.
    private static func writeAction(for resolved: ResolvedAction, in home: HMHome) throws -> HMAction {
        let characteristic = try Self.characteristic(resolved.characteristicId, in: home)
        switch try Self.cocoaValue(resolved.value, kind: resolved.kind, characteristicType: resolved.characteristicType) {
        case .number(let number):
            return HMCharacteristicWriteAction<NSNumber>(characteristic: characteristic, targetValue: number)
        case .string(let string):
            return HMCharacteristicWriteAction<NSString>(characteristic: characteristic, targetValue: string)
        }
    }

    /// The concrete Cocoa value a characteristic write hands HomeKit —
    /// NSNumber for the number family, NSString for strings. One rendering
    /// rule for scene-action targets and direct writes alike.
    private enum CocoaWriteValue {
        case number(NSNumber)
        case string(NSString)
    }

    private static func cocoaValue(
        _ value: HomeKitValue, kind: DeviceHomeView.ValueKind, characteristicType: String
    ) throws -> CocoaWriteValue {
        switch (kind, value) {
        case (.string, .string(let string)): return .string(string as NSString)
        case (.number, .bool(let value)): return .number(NSNumber(value: value))
        case (.number, .int(let value)): return .number(NSNumber(value: value))
        case (.number, .double(let value)): return .number(NSNumber(value: value))
        case (.number, .string(let string)):
            // The widened numeric string the shared check accepted at
            // staging ('30' for a brightness int) writes as its converted
            // number — the same conversion `DeviceWriteResolver` ran.
            guard let converted = DeviceWriteResolver.numericValue(in: string) else {
                throw HomeKitWriteError.invalidOperation(
                    "Characteristic \(characteristicType) cannot take the value \(string)."
                )
            }
            return .number(NSNumber(value: converted))
        case (.unknown, .string(let string)): return .string(string as NSString)
        case (.unknown, .bool(let value)): return .number(NSNumber(value: value))
        case (.unknown, .int(let value)): return .number(NSNumber(value: value))
        case (.unknown, .double(let value)): return .number(NSNumber(value: value))
        case (_, let wrong):
            // The resolver pre-checks this; a drift between resolve and run
            // must not send a wrong-typed value into HomeKit.
            throw HomeKitWriteError.invalidOperation(
                "Characteristic \(characteristicType) cannot take the value \(wrong.rendered)."
            )
        }
    }

    /// Builds the trigger's events and, for presence triggers, the predicate
    /// HomeKit requires to evaluate them. Presence events evaluate every home
    /// user (`presenceUserType: .homeUsers`) — "someone is at home" vs.
    /// "everyone is away" is the event type alone, never a location request.
    private static func events(_ resolved: [ResolvedEvent], in home: HMHome) throws -> ([HMEvent], NSPredicate?) {
        var events: [HMEvent] = []
        var predicate: NSPredicate?
        for event in resolved {
            switch event {
            case .characteristic(let id, _, let value):
                let characteristic = try Self.characteristic(id, in: home)
                switch value {
                case .number(let numeric):
                    events.append(
                        HMCharacteristicEvent<NSNumber>(
                            characteristic: characteristic, triggerValue: try Self.numberValue(numeric)
                        )
                    )
                case .string(let string):
                    events.append(
                        HMCharacteristicEvent<NSString>(
                            characteristic: characteristic, triggerValue: string as NSString
                        )
                    )
                case .anyChange:
                    // Nil trigger value: fires on any change of the
                    // characteristic — the NSNull specialization the read
                    // side enumerates.
                    events.append(
                        HMCharacteristicEvent<NSNull>(characteristic: characteristic, triggerValue: nil)
                    )
                }
            case .presence(let atHome):
                let presence = HMPresenceEvent(
                    presenceEventType: atHome ? .atHome : .notAtHome,
                    presenceUserType: .homeUsers
                )
                predicate = HMEventTrigger.predicateForEvaluatingTrigger(withPresence: presence)
                events.append(presence)
            }
        }
        return (events, predicate)
    }

    private static func numberValue(_ value: HomeKitValue) throws -> NSNumber {
        switch value {
        case .bool(let value): NSNumber(value: value)
        case .int(let value): NSNumber(value: value)
        case .double(let value): NSNumber(value: value)
        case .string(let value):
            throw HomeKitWriteError.invalidOperation(
                "Expected a numeric value for a number characteristic, got the string “\(value)”."
            )
        }
    }

    /// The read side's identity for an existing action, for removal matching.
    private static func key(of action: HMAction) -> SceneActionKey? {
        sceneAction(from: action).map(SceneActionKey.init(action:))
    }

    // MARK: Live-object lookups (re-resolved per call)

    private static func home(_ id: String, in homes: [HMHome]) throws -> HMHome {
        guard let home = homes.first(where: { $0.uniqueIdentifier.uuidString == id }) else {
            throw HomeKitWriteError.objectMissing("No home \(id).")
        }
        return home
    }

    private static func room(_ id: String, in home: HMHome) throws -> HMRoom {
        guard let room = home.rooms.first(where: { $0.uniqueIdentifier.uuidString == id }) else {
            throw HomeKitWriteError.objectMissing("No room \(id).")
        }
        return room
    }

    private static func zone(_ id: String, in home: HMHome) throws -> HMZone {
        guard let zone = home.zones.first(where: { $0.uniqueIdentifier.uuidString == id }) else {
            throw HomeKitWriteError.objectMissing("No zone \(id).")
        }
        return zone
    }

    private static func actionSet(_ id: String, in home: HMHome) throws -> HMActionSet {
        guard let scene = home.actionSets.first(where: { $0.uniqueIdentifier.uuidString == id }) else {
            throw HomeKitWriteError.objectMissing("No scene \(id).")
        }
        return scene
    }

    private static func serviceGroup(_ id: String, in home: HMHome) throws -> HMServiceGroup {
        guard let group = home.serviceGroups.first(where: { $0.uniqueIdentifier.uuidString == id }) else {
            throw HomeKitWriteError.objectMissing("No service group \(id).")
        }
        return group
    }

    private static func trigger(_ id: String, in home: HMHome) throws -> HMTrigger {
        guard let trigger = home.triggers.first(where: { $0.uniqueIdentifier.uuidString == id }) else {
            throw HomeKitWriteError.objectMissing("No trigger \(id).")
        }
        return trigger
    }

    private static func accessory(_ id: String, in home: HMHome) throws -> HMAccessory {
        guard let accessory = home.accessories.first(where: { $0.uniqueIdentifier.uuidString == id }) else {
            throw HomeKitWriteError.objectMissing("No accessory \(id).")
        }
        return accessory
    }

    private static func service(_ id: String, in home: HMHome) throws -> HMService {
        for accessory in home.accessories {
            if let service = accessory.services.first(where: { $0.uniqueIdentifier.uuidString == id }) {
                return service
            }
        }
        throw HomeKitWriteError.objectMissing("No service \(id).")
    }

    private static func characteristic(_ id: String, in home: HMHome) throws -> HMCharacteristic {
        for service in home.accessories.flatMap(\.services) {
            if let characteristic = service.characteristics.first(where: { $0.uniqueIdentifier.uuidString == id }) {
                return characteristic
            }
        }
        throw HomeKitWriteError.objectMissing("No characteristic \(id).")
    }

    // MARK: Live-view extraction

    /// Projects the live manager into the resolver's pure view. Synchronous
    /// and actor-confined — never a cache across the run, rebuilt per call.
    static func homeView(from homes: [HMHome]) -> DeviceHomeView {
        DeviceHomeView(homes: homes.map { home in
            DeviceHomeView.Home(
                id: home.uniqueIdentifier.uuidString,
                name: home.name,
                rooms: home.rooms.map { room in
                    DeviceHomeView.Room(
                        id: room.uniqueIdentifier.uuidString,
                        name: room.name,
                        accessoryIds: room.accessories.map { $0.uniqueIdentifier.uuidString }
                    )
                },
                zones: home.zones.map { zone in
                    DeviceHomeView.Zone(
                        id: zone.uniqueIdentifier.uuidString,
                        name: zone.name,
                        roomIds: zone.rooms.map { $0.uniqueIdentifier.uuidString }
                    )
                },
                scenes: home.actionSets.map { scene in
                    DeviceHomeView.Scene(
                        id: scene.uniqueIdentifier.uuidString,
                        name: scene.name,
                        actionKeys: scene.actions.compactMap { Self.key(of: $0) }
                    )
                },
                serviceGroups: home.serviceGroups.map { group in
                    DeviceHomeView.ServiceGroup(
                        id: group.uniqueIdentifier.uuidString,
                        name: group.name,
                        serviceIds: group.services.map { $0.uniqueIdentifier.uuidString }
                    )
                },
                triggers: home.triggers.map { trigger in
                    let timer = trigger as? HMTimerTrigger
                    return DeviceHomeView.Trigger(
                        id: trigger.uniqueIdentifier.uuidString,
                        name: trigger.name,
                        isEnabled: trigger.isEnabled,
                        timerFireDate: timer?.fireDate,
                        timerRecurrence: recurrenceValues(from: timer?.recurrence),
                        linkedSceneIds: trigger.actionSets.map { $0.uniqueIdentifier.uuidString }
                    )
                },
                accessories: home.accessories.map { accessory in
                    DeviceHomeView.Accessory(
                        id: accessory.uniqueIdentifier.uuidString,
                        name: accessory.name,
                        services: accessory.services.map { service in
                            DeviceHomeView.Service(
                                id: service.uniqueIdentifier.uuidString,
                                name: service.name,
                                serviceType: service.serviceType,
                                characteristics: service.characteristics.map { characteristic in
                                    DeviceHomeView.Characteristic(
                                        id: characteristic.uniqueIdentifier.uuidString,
                                        type: characteristic.characteristicType,
                                        name: characteristic.localizedDescription,
                                        kind: DeviceHomeView.ValueKind(format: characteristic.metadata?.format),
                                        metadata: Self.characteristicMetadata(from: characteristic.metadata)
                                    )
                                }
                            )
                        }
                    )
                }
            )
        })
    }

    // MARK: - Continuation shell (no logic)

    private static func updateName(_ room: HMRoom, to name: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            room.updateName(name) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func updateName(_ actionSet: HMActionSet, to name: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            actionSet.updateName(name) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func updateName(_ zone: HMZone, to name: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            zone.updateName(name) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func updateName(_ accessory: HMAccessory, to name: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            accessory.updateName(name) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func updateName(_ group: HMServiceGroup, to name: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            group.updateName(name) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func identify(_ accessory: HMAccessory) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            accessory.identify { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    // Unblocking is a home-level operation — HMAccessory has no unblock API.
    private static func unblock(_ accessory: HMAccessory, in home: HMHome) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            home.unblockAccessory(accessory) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func assign(_ accessory: HMAccessory, to room: HMRoom, in home: HMHome) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            home.assignAccessory(accessory, to: room) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func remove(_ accessory: HMAccessory, from home: HMHome) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            home.removeAccessory(accessory) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func execute(_ actionSet: HMActionSet, in home: HMHome) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            home.executeActionSet(actionSet) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    /// A direct characteristic write — `HMCharacteristic.writeValue` with the
    /// value rendered the way the metadata declares (the same rule
    /// scene-action targets go through).
    private static func write(
        _ value: HomeKitValue, kind: DeviceHomeView.ValueKind, to characteristic: HMCharacteristic, named type: String
    ) async throws {
        switch try cocoaValue(value, kind: kind, characteristicType: type) {
        case .number(let number):
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                characteristic.writeValue(number) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        case .string(let string):
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                characteristic.writeValue(string) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        }
    }

    private static func remove(_ room: HMRoom, from home: HMHome) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            home.removeRoom(room) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func add(_ room: HMRoom, to zone: HMZone) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            zone.addRoom(room) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func remove(_ room: HMRoom, from zone: HMZone) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            zone.removeRoom(room) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func add(_ action: HMAction, to scene: HMActionSet) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            scene.addAction(action) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func remove(_ action: HMAction, from scene: HMActionSet) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            scene.removeAction(action) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func add(_ service: HMService, to group: HMServiceGroup) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            group.addService(service) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    /// The group-member add with failure context: HomeKit returns a bare
    /// `HMError`, so this rethrows through the narrative naming the service
    /// and the group. The shim above stays logic-free.
    private static func add(_ service: HMService, to group: HMServiceGroup, groupName: String) async throws {
        do {
            try await Self.add(service, to: group)
        } catch {
            let label = service.name.map { "“\($0)”" } ?? service.uniqueIdentifier.uuidString
            throw HomeKitWriteError.invalidOperation(
                HomeKitErrorNarrative.groupRefusal(service: label, group: groupName, error: error)
            )
        }
    }

    private static func remove(_ service: HMService, from group: HMServiceGroup) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            group.removeService(service) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func add(_ trigger: HMTrigger, to home: HMHome) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            home.addTrigger(trigger) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func remove(_ trigger: HMTrigger, from home: HMHome) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            home.removeTrigger(trigger) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func updateEvents(_ trigger: HMEventTrigger, to events: [HMEvent]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            trigger.updateEvents(events) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func updateEndEvents(_ trigger: HMEventTrigger, to endEvents: [HMEvent]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            trigger.updateEndEvents(endEvents) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func updatePredicate(_ trigger: HMEventTrigger, to predicate: NSPredicate?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            trigger.updatePredicate(predicate) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func updateRecurrences(_ trigger: HMEventTrigger, to recurrences: [DateComponents]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            trigger.updateRecurrences(recurrences) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func updateExecuteOnce(_ trigger: HMEventTrigger, to executeOnce: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            trigger.updateExecuteOnce(executeOnce) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func remove(_ actionSet: HMActionSet, from trigger: HMTrigger) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            trigger.removeActionSet(actionSet) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func add(_ actionSet: HMActionSet, to trigger: HMTrigger) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            trigger.addActionSet(actionSet) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func setEnabled(_ trigger: HMTrigger, to enabled: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            trigger.enable(enabled) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}
