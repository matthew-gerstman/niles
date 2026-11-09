import Foundation

/// In-memory `HomeKitService` for unit tests and SwiftUI previews.
///
/// Tests must never touch `HMHomeManager` — the fake is the only home data
/// source they see. Seed it with a `HomeGraph`; when a test needs the world
/// to change mid-test, swap the graph with `setGraph(_:)`.
///
/// As `HomeKitWriting`, the fake also executes the proposal pipeline's
/// operation vocabulary against its graph with HomeKit's observable
/// semantics: deleted rooms hand their accessories to a "Default Room",
/// duplicate names are rejected, and created objects get generated ids.
public actor FakeHomeKitService: HomeKitWriting {
    public private(set) var graph: HomeGraph

    public init(graph: HomeGraph = HomeGraph()) {
        self.graph = graph
    }

    public func snapshot() async throws -> HomeGraph {
        graph
    }

    public func setGraph(_ newGraph: HomeGraph) {
        graph = newGraph
    }

    // MARK: - HomeKitWriting

    public func perform(_ operation: HomeKitOperation) async throws -> String? {
        switch operation {
        case .addRoom(let homeId, let name):
            let h = try indexOfHome(id: homeId)
            guard !graph.homes[h].rooms.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw HomeKitWriteError.duplicateName("Home already has a room named “\(name)”.")
            }
            let id = nextId(prefix: "room", existing: graph.homes[h].rooms.map(\.id))
            graph.homes[h].rooms.append(HomeGraph.Room(id: id, name: name))
            return id

        case .renameRoom(_, let roomId, let to):
            let (h, r) = try indexOfRoom(id: roomId)
            graph.homes[h].rooms[r].name = to
            return nil

        case .removeRoom(_, let roomId):
            let (h, r) = try indexOfRoom(id: roomId)
            // HomeKit's observable behavior: the deleted room's accessories
            // are reassigned to the default room.
            let displaced = graph.homes[h].rooms[r].accessories
            graph.homes[h].rooms.remove(at: r)
            guard !displaced.isEmpty else { return nil }
            if let d = graph.homes[h].rooms.firstIndex(where: { $0.name == "Default Room" }) {
                graph.homes[h].rooms[d].accessories.append(contentsOf: displaced)
            } else {
                let id = nextId(prefix: "room", existing: graph.homes[h].rooms.map(\.id))
                graph.homes[h].rooms.append(HomeGraph.Room(id: id, name: "Default Room", accessories: displaced))
            }
            return nil

        case .setZoneRooms(_, let zoneId, let addRoomIds, let removeRoomIds):
            let (h, z) = try indexOfZone(id: zoneId)
            for roomId in removeRoomIds {
                guard let index = graph.homes[h].zones[z].roomIds.firstIndex(of: roomId) else {
                    throw HomeKitWriteError.objectMissing("Zone “\(graph.homes[h].zones[z].name)” does not contain room \(roomId).")
                }
                graph.homes[h].zones[z].roomIds.remove(at: index)
            }
            for roomId in addRoomIds {
                guard room(id: roomId, inGraph: graph) != nil else {
                    throw HomeKitWriteError.objectMissing("No room \(roomId) to add to zone “\(graph.homes[h].zones[z].name)”.")
                }
                guard !graph.homes[h].zones[z].roomIds.contains(roomId) else { continue }
                graph.homes[h].zones[z].roomIds.append(roomId)
            }
            return nil

        case .createZone(let homeId, let name):
            let h = try indexOfHome(id: homeId)
            guard !graph.homes[h].zones.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw HomeKitWriteError.duplicateName("Home already has a zone named “\(name)”.")
            }
            let id = nextId(prefix: "zone", existing: graph.homes[h].zones.map(\.id))
            graph.homes[h].zones.append(HomeGraph.Zone(id: id, name: name))
            return id

        case .renameZone(_, let zoneId, let to):
            let (h, z) = try indexOfZone(id: zoneId)
            // Zone names are unique within a home; the new name cannot
            // collide with another zone — this one included.
            if graph.homes[h].zones.contains(where: { $0.id != zoneId && $0.name.caseInsensitiveCompare(to) == .orderedSame }) {
                throw HomeKitWriteError.duplicateName("Home already has a zone named “\(to)”.")
            }
            graph.homes[h].zones[z].name = to
            return nil

        case .removeZone(_, let zoneId):
            let (h, z) = try indexOfZone(id: zoneId)
            // HomeKit's observable behavior: rooms survive untouched — a
            // zone is only a grouping over them.
            graph.homes[h].zones.remove(at: z)
            return nil

        case .addActionSet(_, let name, let actions):
            let h = try indexOfHome(havingSceneNamed: name)
            let id = nextId(prefix: "scene", existing: graph.homes[h].scenes.map(\.id))
            let rendered = actions.map { action(from: $0) }
            graph.homes[h].scenes.append(HomeGraph.Scene(id: id, name: name, type: "AppleScene", actions: rendered))
            return id

        case .setSceneActions(_, let sceneId, let add, let remove):
            let (h, s) = try indexOfScene(id: sceneId)
            graph.homes[h].scenes[s].actions.removeAll { action in remove.contains(SceneActionKey(action: action)) }
            let current = graph.homes[h].scenes[s].actions.map(SceneActionKey.init(action:))
            for spec in add where !current.contains(SceneActionKey(spec: spec)) {
                graph.homes[h].scenes[s].actions.append(action(from: spec))
            }
            return nil

        case .renameActionSet(_, let sceneId, let to):
            let (h, s) = try indexOfScene(id: sceneId)
            // Duplicate scene names are rejected the way HomeKit's are,
            // across all homes — the renamed scene cannot collide with another.
            if graph.homes.contains(where: {
                $0.scenes.contains { $0.id != sceneId && $0.name.caseInsensitiveCompare(to) == .orderedSame }
            }) {
                throw HomeKitWriteError.duplicateName("Home already has a scene named “\(to)”.")
            }
            graph.homes[h].scenes[s].name = to
            return nil

        case .removeActionSet(_, let sceneId):
            let (h, s) = try indexOfScene(id: sceneId)
            graph.homes[h].scenes.remove(at: s)
            // HomeKit detaches a removed action set from every trigger;
            // the fake mirrors that observable behavior.
            for t in graph.homes[h].triggers.indices {
                graph.homes[h].triggers[t].linkedSceneIds.removeAll { $0 == sceneId }
            }
            return nil

        case .executeActionSet(_, let sceneId):
            let (h, s) = try indexOfScene(id: sceneId)
            guard !graph.homes[h].scenes[s].actions.isEmpty else {
                throw HomeKitWriteError.invalidOperation(
                    "Scene “\(graph.homes[h].scenes[s].name)” has no actions — HomeKit refuses to execute an empty scene."
                )
            }
            // HomeKit stamps lastExecutionDate when a scene runs; the fake
            // mirrors that observable effect so read-back can see the run.
            graph.homes[h].scenes[s].lastExecutionDate = Date()
            return nil

        case .addServiceGroup(_, let name):
            let h = try indexOfHome(havingServiceGroupNamed: name)
            let id = nextId(prefix: "group", existing: graph.homes[h].serviceGroups.map(\.id))
            graph.homes[h].serviceGroups.append(HomeGraph.ServiceGroup(id: id, name: name))
            return id

        case .setServiceGroupMembers(_, let groupId, let addServiceIds, let removeServiceIds):
            let (h, g) = try indexOfServiceGroup(id: groupId)
            for serviceId in removeServiceIds {
                guard let index = graph.homes[h].serviceGroups[g].services.firstIndex(where: { $0.id == serviceId }) else {
                    throw HomeKitWriteError.objectMissing(
                        "Group “\(graph.homes[h].serviceGroups[g].name)” does not contain service \(serviceId)."
                    )
                }
                graph.homes[h].serviceGroups[g].services.remove(at: index)
            }
            for serviceId in addServiceIds {
                guard let ref = knownService(id: serviceId) else {
                    throw HomeKitWriteError.invalidOperation("No service \(serviceId) in any group of this home.")
                }
                guard !graph.homes[h].serviceGroups[g].services.contains(where: { $0.id == serviceId }) else { continue }
                graph.homes[h].serviceGroups[g].services.append(ref)
            }
            return nil

        case .renameServiceGroup(_, let groupId, let to):
            let (h, g) = try indexOfServiceGroup(id: groupId)
            // Group names are unique within a home; the new name cannot
            // collide with another group — this one included.
            if graph.homes[h].serviceGroups.contains(where: { $0.id != groupId && $0.name.caseInsensitiveCompare(to) == .orderedSame }) {
                throw HomeKitWriteError.duplicateName("Home already has a service group named “\(to)”.")
            }
            graph.homes[h].serviceGroups[g].name = to
            return nil

        case .removeServiceGroup(_, let groupId):
            let (h, g) = try indexOfServiceGroup(id: groupId)
            graph.homes[h].serviceGroups.remove(at: g)
            return nil

        case .addTimerTrigger(let homeId, let name, let fireDate, let recurrence, let sceneId):
            let h = try indexOfHome(id: homeId)
            let id = nextId(prefix: "trigger", existing: graph.homes[h].triggers.map(\.id))
            // Locked rule: triggers are born disabled, whatever the plan said.
            graph.homes[h].triggers.append(
                HomeGraph.Trigger(
                    id: id, name: name, isEnabled: false,
                    linkedSceneIds: sceneId.map { [$0] } ?? [],
                    detail: .timer(fireDate: fireDate, recurrence: recurrence)
                )
            )
            return id

        case .addEventTrigger(let homeId, let name, let events, let sceneId):
            let h = try indexOfHome(id: homeId)
            let id = nextId(prefix: "trigger", existing: graph.homes[h].triggers.map(\.id))
            graph.homes[h].triggers.append(
                HomeGraph.Trigger(
                    id: id, name: name, isEnabled: false,
                    linkedSceneIds: sceneId.map { [$0] } ?? [],
                    detail: .event(events: events.map(Self.eventRef(from:)), predicate: Self.predicateDescription(events))
                )
            )
            return id

        case .setTriggerEnabled(_, let triggerId, let enabled):
            let (h, t) = try indexOfTrigger(id: triggerId)
            // Device law mirrored: HomeKit refuses to enable a trigger with
            // no registered action sets (HMError "No registered action sets
            // for trigger") — an automation that runs nothing cannot arm.
            // Disabling is always allowed.
            if enabled, graph.homes[h].triggers[t].linkedSceneIds.isEmpty {
                throw HomeKitWriteError.invalidOperation(
                    "Trigger “\(graph.homes[h].triggers[t].name)” has no action sets — HomeKit cannot enable an automation that runs nothing."
                )
            }
            graph.homes[h].triggers[t].isEnabled = enabled
            return nil

        case .updateTimerTrigger(_, let triggerId, let fireDate, let recurrence):
            let (h, t) = try indexOfTrigger(id: triggerId)
            guard case .timer = graph.homes[h].triggers[t].detail else {
                throw HomeKitWriteError.invalidOperation(
                    "Trigger “\(graph.homes[h].triggers[t].name)” is not a timer trigger; it has no fire date."
                )
            }
            graph.homes[h].triggers[t].detail = .timer(fireDate: fireDate, recurrence: recurrence)
            return nil

        case .removeTrigger(_, let triggerId):
            let (h, t) = try indexOfTrigger(id: triggerId)
            graph.homes[h].triggers.remove(at: t)
            return nil

        case .renameAccessory(_, let accessoryId, let to):
            let (h, r, a) = try indexOfAccessory(id: accessoryId)
            graph.homes[h].rooms[r].accessories[a].name = to
            return nil

        case .identifyAccessory(_, let accessoryId):
            let (h, r, a) = try indexOfAccessory(id: accessoryId)
            // Mirror the live adapter: an accessory without an Identify
            // characteristic cannot be identified (HMError).
            if graph.homes[h].rooms[r].accessories[a].supportsIdentify == false {
                throw HomeKitWriteError.invalidOperation(
                    "Accessory “\(graph.homes[h].rooms[r].accessories[a].name)” does not support identify."
                )
            }
            // Identify flashes or beeps the physical device — nothing in the
            // graph changes; the evidence read-back confirms presence.
            return nil

        case .assignAccessoryToRoom(_, let accessoryId, let roomId):
            let (h, r, a) = try indexOfAccessory(id: accessoryId)
            guard graph.homes[h].rooms.contains(where: { $0.id == roomId }), roomId != graph.homes[h].rooms[r].id else {
                throw HomeKitWriteError.objectMissing("No room \(roomId).")
            }
            let accessory = graph.homes[h].rooms[r].accessories.remove(at: a)
            let target = graph.homes[h].rooms.firstIndex(where: { $0.id == roomId })!
            graph.homes[h].rooms[target].accessories.append(accessory)
            return nil

        case .unblockAccessory(_, let accessoryId):
            // Blocked state is not modeled in the graph; existence is the
            // only observable check, matching the resolver.
            _ = try indexOfAccessory(id: accessoryId)
            return nil

        case .removeAccessory(_, let accessoryId):
            let (h, r, a) = try indexOfAccessory(id: accessoryId)
            _ = graph.homes[h].rooms[r].accessories.remove(at: a)
            // HomeKit detaches everything the accessory participated in;
            // the fake mirrors that observable behavior. ServiceRefs carry
            // the accessory id, so detach by attribution like scenes/events.
            for g in graph.homes[h].serviceGroups.indices {
                graph.homes[h].serviceGroups[g].services.removeAll { $0.accessoryId == accessoryId }
            }
            for s in graph.homes[h].scenes.indices {
                graph.homes[h].scenes[s].actions.removeAll { $0.accessoryId == accessoryId }
            }
            for t in graph.homes[h].triggers.indices {
                if case .event(let events, let predicate) = graph.homes[h].triggers[t].detail {
                    let remaining = events.filter { $0.accessoryId != accessoryId }
                    graph.homes[h].triggers[t].detail = .event(events: remaining, predicate: predicate)
                }
            }
            return nil
        }
    }

    // MARK: - Graph mutation internals

    /// The graph is a value type — mutations always go through
    /// `graph.homes[index]` subscripts, never through struct copies.

    /// Services are only reachable through groups (the graph's one service
    /// vocabulary); membership changes look refs up across all of them.
    private func knownService(id: String) -> HomeGraph.ServiceRef? {
        graph.homes.flatMap(\.serviceGroups).flatMap(\.services).first { $0.id == id }
    }

    /// Graph projection of a proposed event, mirroring the real adapter's
    /// read shape (HMCharacteristicEvent / HMPresenceEvent).
    private static func eventRef(from spec: TriggerEventSpec) -> HomeGraph.EventRef {
        switch spec {
        case .characteristic(let accessoryId, let characteristic, let value):
            return HomeGraph.EventRef(
                type: "characteristic",
                characteristicType: characteristic,
                valueDescription: value?.rendered,
                accessoryId: accessoryId
            )
        case .presence(let atHome):
            return HomeGraph.EventRef(
                type: "presence",
                characteristicType: nil,
                valueDescription: atHome ? "atHome" : "away"
            )
        }
    }

    /// The predicate the real adapter derives from the events (presence
    /// events imply `predicateForEvaluatingTrigger(withPresence:)`). The fake
    /// records a human-readable equivalent.
    private static func predicateDescription(_ events: [TriggerEventSpec]) -> String? {
        let descriptions = events.map { (event: TriggerEventSpec) -> String in
            switch event {
            case .characteristic(_, let characteristic, let value):
                value.map { "\(characteristic) == \($0.rendered)" } ?? "\(characteristic) changes"
            case .presence(let atHome):
                "presence == \(atHome ? "atHome" : "away")"
            }
        }
        guard !descriptions.isEmpty else { return nil }
        return descriptions.joined(separator: " AND ")
    }

    private func action(from spec: SceneActionSpec) -> HomeGraph.SceneAction {
        let accessoryName = graph.homes
            .flatMap(\.rooms)
            .flatMap(\.accessories)
            .first { $0.id == spec.accessoryId }?.name
        return HomeGraph.SceneAction(
            accessoryId: spec.accessoryId,
            accessoryName: accessoryName,
            service: spec.service,
            characteristic: spec.characteristic,
            characteristicName: nil,
            valueDescription: spec.value.rendered
        )
    }

    private func nextId(prefix: String, existing: [String]) -> String {
        let used = Set(existing)
        var n = 1
        while used.contains("\(prefix)-\(n)") { n += 1 }
        return "\(prefix)-\(n)"
    }

    private func indexOfHome(id: String) throws -> Int {
        guard let index = graph.homes.firstIndex(where: { $0.id == id }) else {
            throw HomeKitWriteError.objectMissing("No home \(id).")
        }
        return index
    }

    /// Scenes are per-home; a create lands in the first home. Duplicate
    /// names are rejected the way HomeKit's are, across all homes.
    private func indexOfHome(havingSceneNamed name: String) throws -> Int {
        if graph.homes.contains(
            where: { $0.scenes.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
        ) {
            throw HomeKitWriteError.duplicateName("Home already has a scene named “\(name)”.")
        }
        guard let index = graph.homes.indices.first else {
            throw HomeKitWriteError.objectMissing("No home exists to hold scene “\(name)”.")
        }
        return index
    }

    private func indexOfHome(havingServiceGroupNamed name: String) throws -> Int {
        if graph.homes.contains(
            where: { $0.serviceGroups.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
        ) {
            throw HomeKitWriteError.duplicateName("Home already has a service group named “\(name)”.")
        }
        guard let index = graph.homes.indices.first else {
            throw HomeKitWriteError.objectMissing("No home exists to hold service group “\(name)”.")
        }
        return index
    }

    private func indexOfRoom(id: String) throws -> (home: Int, room: Int) {
        for h in graph.homes.indices {
            if let r = graph.homes[h].rooms.firstIndex(where: { $0.id == id }) {
                return (h, r)
            }
        }
        throw HomeKitWriteError.objectMissing("No room \(id).")
    }

    private func indexOfZone(id: String) throws -> (home: Int, zone: Int) {
        for h in graph.homes.indices {
            if let z = graph.homes[h].zones.firstIndex(where: { $0.id == id }) {
                return (h, z)
            }
        }
        throw HomeKitWriteError.objectMissing("No zone \(id).")
    }

    private func indexOfScene(id: String) throws -> (home: Int, scene: Int) {
        for h in graph.homes.indices {
            if let s = graph.homes[h].scenes.firstIndex(where: { $0.id == id }) {
                return (h, s)
            }
        }
        throw HomeKitWriteError.objectMissing("No scene \(id).")
    }

    private func indexOfServiceGroup(id: String) throws -> (home: Int, group: Int) {
        for h in graph.homes.indices {
            if let g = graph.homes[h].serviceGroups.firstIndex(where: { $0.id == id }) {
                return (h, g)
            }
        }
        throw HomeKitWriteError.objectMissing("No service group \(id).")
    }

    private func indexOfTrigger(id: String) throws -> (home: Int, trigger: Int) {
        for h in graph.homes.indices {
            if let t = graph.homes[h].triggers.firstIndex(where: { $0.id == id }) {
                return (h, t)
            }
        }
        throw HomeKitWriteError.objectMissing("No trigger \(id).")
    }

    private func indexOfAccessory(id: String) throws -> (home: Int, room: Int, accessory: Int) {
        for h in graph.homes.indices {
            for r in graph.homes[h].rooms.indices {
                if let a = graph.homes[h].rooms[r].accessories.firstIndex(where: { $0.id == id }) {
                    return (h, r, a)
                }
            }
        }
        throw HomeKitWriteError.objectMissing("No accessory \(id).")
    }

    private func room(id: String, inGraph graph: HomeGraph) -> HomeGraph.Room? {
        graph.homes.flatMap(\.rooms).first { $0.id == id }
    }
}
